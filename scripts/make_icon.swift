// Draws the app icon (an original design: a paw with a "+" on a warm gradient) and writes
// Resources/AppIcon.icns.   swift scripts/make_icon.swift
// ThatPet's cat and Ollama's llama are not used here: they belong to those apps and are only
// read from them at runtime for the menu bar icon, never shipped.

import AppKit

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // Rounded square with the standard macOS icon margin.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 1.00, green: 0.62, blue: 0.27, alpha: 1),
                        NSColor(red: 0.96, green: 0.36, blue: 0.42, alpha: 1)])!.draw(in: shape, angle: -60)
    // The paw: a big pad and four toes.
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 330 * s, y: 230 * s, width: 330 * s, height: 280 * s)).fill()
    for (x, y, w, h) in [(250.0, 470.0, 120.0, 150.0), (370, 575, 125, 160), (520, 575, 125, 160), (640, 470, 120, 150)] {
        NSBezierPath(ovalIn: NSRect(x: x * s, y: y * s, width: w * s, height: h * s)).fill()
    }
    // The "+": an add-on for the pet.
    let badge = NSRect(x: 650 * s, y: 650 * s, width: 210 * s, height: 210 * s)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: badge).fill()
    NSColor(red: 0.96, green: 0.36, blue: 0.42, alpha: 1).setFill()
    let bar: CGFloat = 36 * s, arm: CGFloat = 120 * s
    NSBezierPath(roundedRect: NSRect(x: badge.midX - arm / 2, y: badge.midY - bar / 2, width: arm, height: bar),
                 xRadius: bar / 2, yRadius: bar / 2).fill()
    NSBezierPath(roundedRect: NSRect(x: badge.midX - bar / 2, y: badge.midY - arm / 2, width: bar, height: arm),
                 xRadius: bar / 2, yRadius: bar / 2).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try drawIcon(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 1024).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
