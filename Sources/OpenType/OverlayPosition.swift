import CoreGraphics

/// A screen-relative bottom-center anchor survives resizing and display changes.
enum OverlayPosition {
    static func anchor(for frame: CGRect, in screen: CGRect) -> CGPoint {
        CGPoint(x: (frame.midX - screen.minX) / max(screen.width, 1),
                y: (frame.minY - screen.minY) / max(screen.height, 1))
    }

    static func frame(size: CGSize, screen: CGRect, anchor: CGPoint) -> CGRect {
        let x = screen.minX + anchor.x * screen.width - size.width / 2
        let y = screen.minY + anchor.y * screen.height
        return CGRect(
            x: min(max(x, screen.minX), max(screen.minX, screen.maxX - size.width)),
            y: min(max(y, screen.minY), max(screen.minY, screen.maxY - size.height)),
            width: size.width, height: size.height
        )
    }
}
