// Renders AppIcon.iconset/*.png for Machogs: the pig mascot on a warm
// gradient squircle, drawn in code so the repo needs no binary assets and
// the icon always matches the in-app mascot. Run via build.sh (or:
// swift make-icon.swift), then iconutil turns the set into AppIcon.icns.

import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]

func drawIcon(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(px)
    // Apple's icon grid: the squircle is inset ~10% per side, radius ~22.5%.
    let inset = s * 0.10
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.62, alpha: 1),   // pink
        NSColor(calibratedRed: 1.00, green: 0.58, blue: 0.25, alpha: 1),   // orange
    ])!
    gradient.draw(in: path, angle: -60)

    // A soft inner highlight so the slab reads as glass, not flat paint.
    let glow = NSGradient(colors: [
        NSColor(calibratedWhite: 1, alpha: 0.35),
        NSColor(calibratedWhite: 1, alpha: 0.0),
    ])!
    let glowPath = NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.02, dy: rect.width * 0.02),
                                xRadius: rect.width * 0.21, yRadius: rect.width * 0.21)
    glow.draw(in: glowPath, angle: -90)

    // The mascot. An emoji IS the brand — same pig as the menu bar.
    let pig = "🐷" as NSString
    let fontSize = s * 0.56
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize)]
    let glyph = pig.size(withAttributes: attrs)
    pig.draw(at: NSPoint(x: (s - glyph.width) / 2, y: (s - glyph.height) / 2 - s * 0.01),
             withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let out = "AppIcon.iconset"
try? fm.removeItem(atPath: out)
try! fm.createDirectory(atPath: out, withIntermediateDirectories: true)

for px in sizes {
    let rep = drawIcon(px)
    let png = rep.representation(using: .png, properties: [:])!
    if px <= 512 {
        try! png.write(to: URL(fileURLWithPath: "\(out)/icon_\(px)x\(px).png"))
    }
    if px >= 32 {
        try! png.write(to: URL(fileURLWithPath: "\(out)/icon_\(px / 2)x\(px / 2)@2x.png"))
    }
}
print("wrote \(out)")
