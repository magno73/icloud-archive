import AppKit

// A native SF Symbol keeps the utility recognizable without embedding third-
// party artwork. The icon is generated at build time for every display scale.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        let inset = CGFloat(pixels) * 0.065
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                                 xRadius: CGFloat(pixels) * 0.21, yRadius: CGFloat(pixels) * 0.21)
        NSGradient(starting: NSColor(calibratedRed: 0.05, green: 0.53, blue: 0.56, alpha: 1),
                   ending: NSColor(calibratedRed: 0.02, green: 0.22, blue: 0.31, alpha: 1))!.draw(in: shape, angle: -70)
        if let symbol = NSImage(systemSymbolName: "externaldrive.badge.icloud", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: CGFloat(pixels) * 0.48, weight: .regular)) {
            symbol.isTemplate = false
            let target = NSRect(x: CGFloat(pixels) * 0.19, y: CGFloat(pixels) * 0.25,
                                width: CGFloat(pixels) * 0.62, height: CGFloat(pixels) * 0.49)
            NSColor.white.set()
            let tinted = NSImage(size: symbol.size)
            tinted.lockFocus()
            symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.white.setFill()
            NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: target)
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
