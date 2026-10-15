import AppKit
import PDFKit
import Quartz
import SwiftUI

/// Files shown in one viewer window, and which one is open.
struct ViewerSession {
    var urls: [URL]
    var index: Int
}

/// Zoom and page commands sent from the toolbar to the current PDF or image view.
@MainActor
final class ViewerController: ObservableObject {
    weak var pdfView: PDFView?
    weak var imageScroll: NSScrollView?
    @Published var zoom: CGFloat = 1
    @Published var pageLabel = ""
    @Published var showThumbnails = false

    func zoomIn() {
        if let pdfView { pdfView.autoScales = false; pdfView.scaleFactor = min(pdfView.scaleFactor * 1.25, 8) }
        if let imageScroll { imageScroll.magnification = min(imageScroll.magnification * 1.25, imageScroll.maxMagnification) }
        update()
    }

    func zoomOut() {
        if let pdfView { pdfView.autoScales = false; pdfView.scaleFactor = max(pdfView.scaleFactor / 1.25, 0.1) }
        if let imageScroll { imageScroll.magnification = max(imageScroll.magnification / 1.25, imageScroll.minMagnification) }
        update()
    }

    func actualSize() {
        if let pdfView { pdfView.autoScales = false; pdfView.scaleFactor = 1 }
        if let imageScroll { imageScroll.magnification = 1 }
        update()
    }

    func fit() {
        if let pdfView { pdfView.autoScales = true }
        if let imageScroll, let document = imageScroll.documentView {
            imageScroll.magnify(toFit: document.bounds)
        }
        update()
    }

    func update() {
        if let pdfView {
            zoom = pdfView.scaleFactor
            if let page = pdfView.currentPage, let document = pdfView.document {
                pageLabel = "\(document.index(for: page) + 1) / \(document.pageCount)"
            }
        } else if let imageScroll {
            zoom = imageScroll.magnification
            pageLabel = ""
        }
    }

    func find(_ text: String) {
        guard let pdfView, let document = pdfView.document, !text.isEmpty else { return }
        let start = pdfView.currentSelection
        let match = document.findString(text, fromSelection: start, withOptions: [.caseInsensitive, .diacriticInsensitive])
            ?? document.findString(text, fromSelection: nil, withOptions: [.caseInsensitive, .diacriticInsensitive])
        if let match {
            pdfView.setCurrentSelection(match, animate: true)
            pdfView.go(to: match)
        }
        update()
    }
}

struct AttachmentViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    let sessionID: String
    @StateObject private var controller = ViewerController()
    @State private var search = ""

    private var session: ViewerSession? { model.viewerSessions[sessionID] }
    private var url: URL? { session.flatMap { $0.urls.indices.contains($0.index) ? $0.urls[$0.index] : nil } }

    private var kind: AttachmentItem.Kind {
        AttachmentItem.kind(of: url?.lastPathComponent ?? "")
    }

    var body: some View {
        Group {
            if let url {
                switch kind {
                case .pdf: PDFKitView(url: url, controller: controller)
                case .image: ZoomableImageView(url: url, controller: controller)
                default: QuickLookView(url: url)
                }
            } else {
                ContentUnavailableView("Príloha sa nenašla", systemImage: "doc.questionmark")
            }
        }
        .id(url)
        .navigationTitle(url?.lastPathComponent ?? "Náhľad")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { move(-1) } label: { Label("Predchádzajúca", systemImage: "chevron.left") }
                    .disabled((session?.index ?? 0) == 0)
                    .help("Predchádzajúca príloha (←)")
                Button { move(1) } label: { Label("Ďalšia", systemImage: "chevron.right") }
                    .disabled((session?.index ?? 0) >= (session?.urls.count ?? 1) - 1)
                    .help("Ďalšia príloha (→)")
                if let session, session.urls.count > 1 {
                    Text("\(session.index + 1) / \(session.urls.count)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if kind == .pdf || kind == .image {
                ToolbarItemGroup {
                    Button { controller.zoomOut() } label: { Label("Oddialiť", systemImage: "minus.magnifyingglass") }
                        .help("Oddialiť (⌘−)")
                        .keyboardShortcut("-", modifiers: .command)
                    Button { controller.actualSize() } label: {
                        Text("\(Int((controller.zoom * 100).rounded())) %").monospacedDigit().frame(minWidth: 44)
                    }
                    .help("Skutočná veľkosť (100 %)")
                    Button { controller.zoomIn() } label: { Label("Priblížiť", systemImage: "plus.magnifyingglass") }
                        .help("Priblížiť (⌘+)")
                        .keyboardShortcut("+", modifiers: .command)
                    Button { controller.fit() } label: { Label("Prispôsobiť oknu", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                        .help("Prispôsobiť oknu (⌘0)")
                        .keyboardShortcut("0", modifiers: .command)
                }
            }
            if kind == .pdf {
                ToolbarItemGroup {
                    if !controller.pageLabel.isEmpty {
                        Text("Strana \(controller.pageLabel)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Toggle(isOn: $controller.showThumbnails) { Label("Strany", systemImage: "sidebar.left") }
                        .help("Náhľady strán")
                    TextField("Hľadať v PDF", text: $search)
                        .frame(width: 150)
                        .onSubmit { controller.find(search) }
                }
            }
            ToolbarItemGroup {
                Button { save() } label: { Label("Uložiť", systemImage: "square.and.arrow.down") }
                    .help("Uložiť ako…")
                Button { if let url { NSWorkspace.shared.open(url) } } label: { Label("Otvoriť v aplikácii", systemImage: "arrow.up.forward.app") }
                    .help("Otvoriť v predvolenej aplikácii")
            }
        }
        .background(KeyCatcher(onLeft: { move(-1) }, onRight: { move(1) }, onClose: { dismissWindow() }))
        .frame(minWidth: 640, minHeight: 520)
        .onDisappear { model.viewerSessions[sessionID] = nil }
    }

    private func move(_ step: Int) {
        guard var session, session.urls.indices.contains(session.index + step) else { return }
        session.index += step
        model.viewerSessions[sessionID] = session
    }

    private func save() {
        guard let url else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        guard panel.runModal() == .OK, let target = panel.url else { return }
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.copyItem(at: url, to: target)
            model.showToast("Uložené: \(target.lastPathComponent)")
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Views

private struct PDFKitView: NSViewRepresentable {
    let url: URL
    let controller: ViewerController

    func makeNSView(context: Context) -> NSSplitView {
        let pdfView = PDFView()
        pdfView.document = PDFDocument(url: url)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = .underPageBackgroundColor
        let thumbnails = PDFThumbnailView()
        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = NSSize(width: 90, height: 120)
        thumbnails.backgroundColor = .windowBackgroundColor
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(thumbnails)
        split.addArrangedSubview(pdfView)
        controller.pdfView = pdfView
        controller.imageScroll = nil
        NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { _ in
            Task { @MainActor in controller.update() }
        }
        NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { _ in
            Task { @MainActor in controller.update() }
        }
        // Page thumbnails only help with more than one page.
        let multiPage = (pdfView.document?.pageCount ?? 1) > 1
        DispatchQueue.main.async {
            controller.showThumbnails = multiPage
            Self.apply(multiPage, to: split)
            controller.update()
        }
        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        Self.apply(controller.showThumbnails, to: split)
    }

    private static func apply(_ show: Bool, to split: NSSplitView) {
        guard let thumbnails = split.arrangedSubviews.first else { return }
        let width = thumbnails.frame.width
        if show && width < 10 {
            thumbnails.isHidden = false
            split.setPosition(130, ofDividerAt: 0)
        } else if !show && (width > 0 || !thumbnails.isHidden) {
            split.setPosition(0, ofDividerAt: 0)
            thumbnails.isHidden = true
            split.adjustSubviews()
        }
    }
}

private struct ZoomableImageView: NSViewRepresentable {
    let url: URL
    let controller: ViewerController

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 16
        scroll.backgroundColor = .underPageBackgroundColor
        let imageView = NSImageView()
        if let image = NSImage(contentsOf: url) {
            imageView.image = image
            let size = image.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
            imageView.frame = NSRect(origin: .zero, size: size)
            image.size = size
        }
        imageView.imageScaling = .scaleProportionallyUpOrDown
        scroll.documentView = imageView
        controller.imageScroll = scroll
        controller.pdfView = nil
        NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scroll, queue: .main) { _ in
            Task { @MainActor in controller.update() }
        }
        // Large photos start fitted to the window, small images at their size.
        DispatchQueue.main.async {
            if imageView.frame.width > scroll.contentSize.width || imageView.frame.height > scroll.contentSize.height {
                scroll.magnify(toFit: imageView.frame)
            }
            controller.update()
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}
}

/// Word, Excel, Pages and anything else Quick Look can show.
private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL }
    }
}

/// ← → between attachments and Esc / space to close, unless a text field has the focus.
private struct KeyCatcher: NSViewRepresentable {
    let onLeft: () -> Void
    let onRight: () -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.handlers = (onLeft, onRight, onClose)
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, coordinator = context.coordinator] event in
            guard let window = view?.window, event.window === window, !(window.firstResponder is NSText),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            switch event.keyCode {
            case 123: coordinator.handlers?.0(); return nil
            case 124: coordinator.handlers?.1(); return nil
            case 53, 49: coordinator.handlers?.2(); return nil
            default: return event
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.handlers = (onLeft, onRight, onClose)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    final class Coordinator {
        var handlers: (() -> Void, () -> Void, () -> Void)?
        var monitor: Any?
    }
}
