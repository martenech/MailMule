import AppKit
import SwiftUI
import WebKit

/// Renders email HTML with JavaScript off and remote content (tracking pixels) blocked.
/// Reports the content height so several messages can be stacked in one scroll view.
struct HTMLView: NSViewRepresentable {
    let html: String
    /// Load images from the internet (off by default: they can tell the sender the mail was opened).
    var allowRemote = false
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> PassthroughWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = PassthroughWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(html, allowRemote: allowRemote, into: webView)
        return webView
    }

    func updateNSView(_ webView: PassthroughWebView, context: Context) {
        if context.coordinator.loadedHTML != html || context.coordinator.loadedAllowRemote != allowRemote {
            context.coordinator.load(html, allowRemote: allowRemote, into: webView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var height: Binding<CGFloat>
        var loadedHTML: String?
        var loadedAllowRemote = false

        init(height: Binding<CGFloat>) {
            self.height = height
        }

        func load(_ html: String, allowRemote: Bool, into webView: WKWebView) {
            loadedHTML = html
            loadedAllowRemote = allowRemote
            Task {
                webView.configuration.userContentController.removeAllContentRuleLists()
                if !allowRemote, let rules = await RemoteContentBlocker.shared.rules() {
                    webView.configuration.userContentController.add(rules)
                }
                webView.loadHTMLString(Self.wrap(html), baseURL: nil)
            }
        }

        /// Emails assume a white page; keep it that way even in dark mode.
        static func wrap(_ html: String) -> String {
            """
            <meta name="color-scheme" content="light">
            <style>html,body{margin:0;padding:12px;background:#fff;color:#1d1d1f;font:14px -apple-system,Helvetica,sans-serif;overflow-wrap:anywhere}img{max-width:100%;height:auto}</style>
            \(html)
            """
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Calls from the app still work with page JavaScript disabled.
            webView.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)") { result, _ in
                if let value = result as? CGFloat {
                    Task { @MainActor in self.height.wrappedValue = max(40, value) }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

/// Forwards scroll events to the enclosing SwiftUI scroll view instead of scrolling itself.
final class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

@MainActor
final class RemoteContentBlocker {
    static let shared = RemoteContentBlocker()
    private var compiled: WKContentRuleList?

    func rules() async -> WKContentRuleList? {
        if let compiled { return compiled }
        let json = """
        [
          {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^cid:"}, "action": {"type": "ignore-previous-rules"}}
        ]
        """
        // WebKit's url-filter has no alternation ("a|b"); one rule per scheme.
        do {
            compiled = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "mailmule-block-remote-v2", encodedContentRuleList: json)
        } catch {
            AppModel.logger.error("blokovanie obrázkov: \(error.localizedDescription, privacy: .public)")
        }
        return compiled
    }
}
