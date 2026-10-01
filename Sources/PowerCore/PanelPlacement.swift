import Foundation
import CoreGraphics

public enum PanelPlacement {
    /// Handles removed displays, negative screen origins and short displays.
    public static func constrained(_ frame: CGRect, to screens: [CGRect]) -> CGRect {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0,
              let fallback = screens.first else { return frame }
        let screen = screens.max {
            let a = $0.intersection(frame), b = $1.intersection(frame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }.flatMap { $0.intersects(frame) ? $0 : nil } ?? fallback
        var result = frame
        result.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
        // Keep the header reachable even if a diagnostic makes the card taller.
        result.origin.y = frame.height > screen.height ? screen.maxY - frame.height
            : max(screen.minY, min(frame.minY, screen.maxY - frame.height))
        return result
    }
}
