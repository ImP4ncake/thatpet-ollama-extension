// Draws the app's artwork: a cat peeking over an edge with a "+" at the top right, in the style
// of ThatPet's own icon (where the "+" is its sparkle). Everything is drawn here: ThatPet's and
// Ollama's icons belong to those apps and are only read from them at runtime for the menu bar
// icon, never shipped.
//
//   swift scripts/artwork.swift icon                  writes Resources/AppIcon.icns and docs/icon.png
//   swift scripts/artwork.swift dmg-background DIR    writes the installer background (1x, @2x)

import AppKit

let cream = NSColor(red: 0.96, green: 0.95, blue: 0.93, alpha: 1)  // the cat and the "+"

/// A smooth closed path through `points` (Catmull-Rom curves).
func smoothPath(_ points: [NSPoint]) -> NSBezierPath {
    let path = NSBezierPath()
    let n = points.count
    path.move(to: points[0])
    for i in 0..<n {
        let p0 = points[(i - 1 + n) % n], p1 = points[i], p2 = points[(i + 1) % n], p3 = points[(i + 2) % n]
        path.curve(to: p2, controlPoint1: NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                   controlPoint2: NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
    }
    path.close()
    return path
}

/// The cat on a 455-wide grid, in the shape of ThatPet's (measured from its icon at 1024 px): a
/// head with two rounded ears on a body that widens toward the edge. The edge's top is y = 0 and
/// the ear tips reach y = 248. `eyes` colors the eyes (nil: plain silhouette); `edge` draws the
/// edge it peeks over; `shaded` adds the soft light and shadow of an app icon.
func drawCat(at origin: NSPoint, scale: CGFloat, ink: NSColor, eyes: NSColor?, edge: Bool, shaded: Bool = false) {
    NSGraphicsContext.saveGraphicsState()
    let place = NSAffineTransform()
    place.translateX(by: origin.x, yBy: origin.y)
    place.scale(by: scale)
    place.concat()
    // The left half, from the edge up to the middle of the head; the right half mirrors it.
    let half: [(CGFloat, CGFloat)] = [
        (-10, 0), (0, 11), (1, 31), (5, 51), (12, 71), (23, 91), (31, 111), (29, 131), (28, 161), (28, 191),
        (32, 211), (37, 231), (45, 241), (56, 246), (66, 248), (78, 246), (89, 242), (101, 235), (116, 224),
        (131, 214), (146, 200), (160, 189), (176, 192), (191, 196), (206, 199), (227.5, 200),
    ]
    var outline = half.map { NSPoint(x: $0.0, y: $0.1) }
    outline += half.dropLast().reversed().map { NSPoint(x: 455 - $0.0, y: $0.1) }
    outline += [NSPoint(x: 470, y: -20), NSPoint(x: -15, y: -20)]
    var shapes = [smoothPath(outline)]
    if edge {
        shapes.append(NSBezierPath(roundedRect: NSRect(x: -79, y: -39, width: 614, height: 39), xRadius: 19.5, yRadius: 19.5))
    }
    // Translucent ink: draw opaque in a layer faded as a whole, so overlapping shapes don't show.
    let context = NSGraphicsContext.current!.cgContext
    context.setAlpha(ink.alphaComponent)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    let solid = ink.withAlphaComponent(1)
    if shaded {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.set()
        context.beginTransparencyLayer(auxiliaryInfo: nil)  // one shadow for the cat and its edge
        solid.setFill()
        shapes.forEach { $0.fill() }
        context.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
        let light = NSGradient(colors: [solid, solid.blended(withFraction: 0.1, of: .black)!])!
        shapes.forEach { light.draw(in: $0, angle: -90) }
    } else {
        solid.setFill()
        shapes.forEach { $0.fill() }
    }
    if let eyes = eyes {
        for x in [134.0, 321] {
            if shaded {  // a soft ring around each eye, like a small bevel
                solid.blended(withFraction: 0.16, of: .black)!.setFill()
                NSBezierPath(ovalIn: NSRect(x: x - 31, y: 45.5 - 31, width: 62, height: 62)).fill()
            }
            eyes.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 25.5, y: 45.5 - 25.5, width: 51, height: 51)).fill()
        }
    }
    context.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()
}

/// A rounded "+", where ThatPet's icon has its sparkle, with a soft glow like it.
func drawPlus(center: NSPoint, arm: CGFloat, bar: CGFloat, color: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowBlurRadius = arm * 0.22
    glow.shadowOffset = .zero
    glow.shadowColor = color.withAlphaComponent(0.45)
    glow.set()
    color.setFill()
    let plus = NSBezierPath(roundedRect: NSRect(x: center.x - arm / 2, y: center.y - bar / 2, width: arm, height: bar),
                            xRadius: bar / 2, yRadius: bar / 2)
    plus.append(NSBezierPath(roundedRect: NSRect(x: center.x - bar / 2, y: center.y - arm / 2, width: bar, height: arm),
                             xRadius: bar / 2, yRadius: bar / 2))
    plus.windingRule = .nonZero
    plus.fill()
    NSGraphicsContext.restoreGraphicsState()
}

func bitmap(pixels: NSSize, points: NSSize, draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = points  // so a @2x file is marked 144 dpi
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// The app icon on a 1024 grid, at any pixel size: ThatPet's look (a white cat peeking over
/// an edge on a dark tile) with a "+" for the extension.
func drawIcon() {
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    let dark = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    NSGradient(colors: [NSColor(red: 0.25, green: 0.25, blue: 0.27, alpha: 1), dark])!.draw(in: shape, angle: -90)
    // A thin light rim, like a glass edge.
    NSColor.white.withAlphaComponent(0.08).setStroke()
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182)
    rim.lineWidth = 6
    rim.stroke()
    drawCat(at: NSPoint(x: 284, y: 393), scale: 1, ink: cream, eyes: dark, edge: true, shaded: true)
    drawPlus(center: NSPoint(x: 752, y: 664), arm: 84, bar: 25, color: cream)
}

func writeIcon() throws {
    let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    func icon(_ pixels: Int) -> Data {
        bitmap(pixels: NSSize(width: pixels, height: pixels), points: NSSize(width: 1024, height: 1024), draw: drawIcon)
            .representation(using: .png, properties: [:])!
    }
    for base in [16, 32, 128, 256, 512] {
        try icon(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
        try icon(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    try icon(1024).write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))
    try FileManager.default.createDirectory(atPath: "docs", withIntermediateDirectories: true)
    try icon(256).write(to: URL(fileURLWithPath: "docs/icon.png"))  // for the README
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
    try iconutil.run()
    iconutil.waitUntilExit()
    print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
}

/// The installer window (640 x 420 shown, drawn 460 tall). The app icon sits at (165, 185) and
/// Applications at (475, 185) from the top-left, as set in make_dmg.sh. The graphite is lighter
/// than the icon's on purpose: Finder writes the icon names in black in light mode and in white
/// in dark mode, and both stay readable on it.
func writeDMGBackground(to folder: URL) throws {
    let size = NSSize(width: 640, height: 460)
    func top(_ y: CGFloat) -> CGFloat { size.height - y }  // y measured from the top
    func text(_ string: String, size points: CGFloat, weight: NSFont.Weight, alpha: CGFloat, centerY: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let line = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: points, weight: weight),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha), .paragraphStyle: style,
        ])
        let height = line.size().height
        line.draw(in: NSRect(x: 20, y: top(centerY) - height / 2, width: 600, height: height))
    }
    func draw() {
        let bounds = NSRect(origin: .zero, size: size)
        NSGradient(colors: [NSColor(red: 0.50, green: 0.50, blue: 0.53, alpha: 1),
                            NSColor(red: 0.40, green: 0.40, blue: 0.43, alpha: 1)])!.draw(in: bounds, angle: -90)
        // A soft light behind the two icons.
        let center = NSPoint(x: 320, y: top(185))
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: 330, options: [])
        // The cat, faint, peeking over the bottom edge of the window.
        drawCat(at: NSPoint(x: 30, y: top(420)), scale: 0.26, ink: NSColor.white.withAlphaComponent(0.12),
                eyes: nil, edge: false)
        // The arrow from the app to Applications: a gentle arc with a rounded head.
        NSColor.white.withAlphaComponent(0.92).setStroke()
        let start = NSPoint(x: 252, y: top(190)), control = NSPoint(x: 320, y: top(158)), end = NSPoint(x: 388, y: top(190))
        let arrow = NSBezierPath()
        arrow.move(to: start)
        arrow.curve(to: end, controlPoint1: control, controlPoint2: control)
        let direction = atan2(end.y - control.y, end.x - control.x)
        for side in [-1.0, 1.0] {
            let wing = direction + .pi - side * 0.62
            arrow.move(to: end)
            arrow.line(to: NSPoint(x: end.x + 13 * cos(wing), y: end.y + 13 * sin(wing)))
        }
        arrow.lineWidth = 3.5
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.stroke()
        text("Drag the app into Applications, then open it from there.", size: 14, weight: .medium,
             alpha: 0.95, centerY: 318)
        text("Blocked on first launch? Privacy & Security › Open Anyway", size: 11, weight: .regular,
             alpha: 0.7, centerY: 372)
    }
    for scale in [1, 2] {
        let pixels = NSSize(width: size.width * CGFloat(scale), height: size.height * CGFloat(scale))
        let name = scale == 1 ? "background.png" : "background@2x.png"
        try bitmap(pixels: pixels, points: size, draw: draw).representation(using: .png, properties: [:])!
            .write(to: folder.appendingPathComponent(name))
    }
    print("Wrote background.png and background@2x.png")
}

let command = CommandLine.arguments.dropFirst().first
switch command {
case "icon": try writeIcon()
case "dmg-background": try writeDMGBackground(to: URL(fileURLWithPath: CommandLine.arguments.dropFirst(2).first ?? "."))
default: print("usage: swift scripts/artwork.swift icon | dmg-background DIR"); exit(1)
}
