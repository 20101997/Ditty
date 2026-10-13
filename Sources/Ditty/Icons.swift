import AppKit

enum Icons {
    /// Two slanted strokes: the ditto mark (〃).
    private static func dittoMark(in rect: NSRect, lineWidth: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        for fraction in [0.34, 0.66] as [CGFloat] {
            let x = rect.minX + rect.width * fraction
            path.move(to: NSPoint(x: x + rect.width * 0.07, y: rect.maxY - rect.height * 0.22))
            path.line(to: NSPoint(x: x - rect.width * 0.07, y: rect.minY + rect.height * 0.22))
        }
        return path
    }

    static func statusIcon(connected: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.withAlphaComponent(connected ? 1 : 0.4).setStroke()
            dittoMark(in: rect.insetBy(dx: 1, dy: 1), lineWidth: 2.6).stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    static func writeAppIcon(to path: String) {
        let size = 1024
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let tile = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 100, dy: 100)
        let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
        NSGradient(starting: Theme.rgb(84, 160, 240), ending: Theme.rgb(24, 92, 190))?.draw(in: shape, angle: -90)
        NSColor.white.setStroke()
        dittoMark(in: tile.insetBy(dx: 110, dy: 110), lineWidth: 96).stroke()
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
