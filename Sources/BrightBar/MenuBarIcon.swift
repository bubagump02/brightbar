// Menu bar icon: a sun whose disk fills with the brightness level.
// Sub-zero: dashed empty disk, faded rays. XDR: full disk, longer rays.
// Template image, so macOS tints it for light and dark menu bars.

import AppKit

@MainActor
enum MenuBarIcon {
    private static var cache: [Int: NSImage] = [:]

    /// `level` is BrightnessModel.level (-100...200).
    static func image(level: Double) -> NSImage {
        // 5 % buckets: enough to see the gauge move, few redraws.
        let key: Int = level < 0 ? -1 : level > 100 ? 101 : Int((level / 5).rounded()) * 5
        if let cached = cache[key] { return cached }
        let image = draw(key)
        cache[key] = image
        return image
    }

    private static func draw(_ key: Int) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            // Drawn on a 24-unit grid, scaled to 18 pt.
            let t = NSAffineTransform()
            t.scale(by: size.width / 24)
            t.concat()

            let center = NSPoint(x: 12, y: 12)
            let radius: CGFloat = 5
            let xdr = key > 100
            let subzero = key < 0

            // Eight rays between `inner` and `outer` from the center.
            let rays = NSBezierPath()
            let inner: CGFloat = 7.5
            let outer: CGFloat = xdr ? 11 : 9.5
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4
                rays.move(to: NSPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
                rays.line(to: NSPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer))
            }
            rays.lineWidth = xdr ? 1.8 : 1.6
            rays.lineCapStyle = .round
            NSColor.black.withAlphaComponent(subzero ? 0.35 : 1).setStroke()
            rays.stroke()

            let disk = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            disk.lineWidth = 1.6
            NSColor.black.setStroke()
            NSColor.black.setFill()
            if subzero {
                disk.setLineDash([2, 2], count: 2, phase: 0)
                disk.stroke()
            } else if xdr {
                disk.fill()
            } else {
                disk.stroke()
                // Fill from the bottom of the disk up to the level.
                let fraction = CGFloat(key) / 100
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: NSRect(x: 0, y: center.y - radius, width: 24, height: radius * 2 * fraction)).addClip()
                disk.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Luminosité"
        return image
    }
}
