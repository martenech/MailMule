import AppKit
import SwiftUI

/// Delivers single-key presses (without modifiers) to a handler, unless the user is typing in a text field.
struct KeyMonitor: NSViewRepresentable {
    let handler: (String) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.handler = handler
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.handler = handler
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        var handler: ((String) -> Bool)?
        private var monitor: Any?

        func install(for view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
                guard let self, let window = view?.window, event.window === window,
                      window.attachedSheet == nil,
                      !(window.firstResponder is NSText),
                      let characters = event.charactersIgnoringModifiers?.lowercased() else { return event }
                let modifiers = event.modifierFlags.intersection([.command, .control, .option])
                // ⌘Z outside text fields undoes the last mail action; text fields keep their own undo.
                let key = modifiers == .command && characters == "z" ? "⌘z" : characters
                guard modifiers.isEmpty || key == "⌘z", self.handler?(key) == true else { return event }
                return nil
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
