import AppKit
import SwiftUI

struct WindowDragExclusions: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Preserve the actual layout bounds of controls, including when resized.
    func keepsMouseInteraction() -> some View {
        anchorPreference(key: WindowDragExclusions.self, value: .bounds) { [$0] }
    }
}

/// Covers the card but passes all control regions through to SwiftUI/AppKit.
struct WindowDragHandle: NSViewRepresentable {
    let exclusions: [CGRect]

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.exclusions = exclusions
    }

    final class DragView: NSView {
        var exclusions: [CGRect] = []
        override var isFlipped: Bool { true } // Same coordinates as SwiftUI anchors.
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard bounds.contains(local), !exclusions.contains(where: { $0.contains(local) }) else { return nil }
            return self
        }

        override func mouseDown(with event: NSEvent) {
            guard let window, window.isMovable else { return }
            // Keep the standard arrow both on hover and throughout dragging.
            window.performDrag(with: event)
        }
    }
}
