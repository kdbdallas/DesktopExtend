import AppKit

/// The status-bar glyph: a simplified version of the app icon. An outlined
/// main screen beside a smaller, solid second desktop with a document on it.
///
/// Drawn in code rather than shipped as a bitmap so it stays sharp at every
/// backing scale, and returned as a template image so the menu bar tints it
/// for light, dark and highlighted states.
enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 16), flipped: false) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "DesktopExtend"
        return image
    }

    private static func draw() {
        guard let ctx = NSGraphicsContext.current else { return }
        NSColor.black.setStroke()
        NSColor.black.setFill()

        // Main screen, outlined.
        let main = NSBezierPath(roundedRect: NSRect(x: 1.25, y: 3.25, width: 13, height: 9.5),
                                xRadius: 2, yRadius: 2)
        main.lineWidth = 1.5
        main.stroke()

        // Second desktop, solid, so it stands out the way the lit panel does
        // in the app icon.
        NSBezierPath(roundedRect: NSRect(x: 16.25, y: 4.75, width: 6.5, height: 6.5),
                     xRadius: 1.5, yRadius: 1.5).fill()

        // The document on it is cut out of the panel rather than drawn on top,
        // which keeps it legible at menu-bar size.
        ctx.saveGraphicsState()
        ctx.compositingOperation = .clear
        documentPath(in: NSRect(x: 18, y: 6, width: 3, height: 4), fold: 1.1).fill()
        ctx.restoreGraphicsState()
    }

    /// A page with its top-right corner folded down.
    private static func documentPath(in r: NSRect, fold: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX, y: r.minY))
        p.line(to: NSPoint(x: r.maxX, y: r.minY))
        p.line(to: NSPoint(x: r.maxX, y: r.maxY - fold))
        p.line(to: NSPoint(x: r.maxX - fold, y: r.maxY))
        p.line(to: NSPoint(x: r.minX, y: r.maxY))
        p.close()
        return p
    }
}
