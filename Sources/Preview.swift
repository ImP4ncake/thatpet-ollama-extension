// Command-line helpers: icon preview and notification check.

import AppKit
import UserNotifications

/// Enlarged preview of how it looks in the menu bar: each icon style (on, then off) with
/// ThatPet's icon right next to it, on a light and a dark bar.
func renderPreview(to path: String) {
    let scale: CGFloat = 6, barHeight: CGFloat = 24, gap: CGFloat = 16, margin: CGFloat = 12
    let widest = IconStyle.allCases.map { extensionIcon($0).size.width }.max() ?? 24
    let barWidth = margin * 2 + widest + gap + (thatPetIcon?.size.width ?? 18)
    let light = NSColor(white: 0.92, alpha: 1), dark = NSColor(white: 0.16, alpha: 1)
    var strips: [(NSImage, NSColor, NSColor, CGFloat)] = []
    for style in IconStyle.allCases.reversed() {
        for (background, ink) in [(dark, NSColor.white), (light, NSColor.black)] {
            strips += [(extensionIcon(style), background, ink, 0.4), (extensionIcon(style), background, ink, 1)]
        }
    }
    let stripHeight = (barHeight + 4) * scale
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(barWidth * scale),
                                     pixelsHigh: Int(stripHeight) * strips.count,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
    for (index, (ours, background, ink, alpha)) in strips.enumerated() {
        let bottom = CGFloat(index) * stripHeight
        background.setFill()
        NSRect(x: 0, y: bottom, width: barWidth * scale, height: barHeight * scale).fill()
        func draw(_ icon: NSImage, at x: CGFloat, fraction: CGFloat) {
            let tinted = NSImage(size: icon.size, flipped: false) { bounds in
                icon.draw(in: bounds)
                ink.set()
                bounds.fill(using: .sourceAtop)
                return true
            }
            let rect = NSRect(x: x * scale, y: bottom + (barHeight - icon.size.height) / 2 * scale,
                              width: icon.size.width * scale, height: icon.size.height * scale)
            tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fraction)
        }
        draw(ours, at: margin, fraction: alpha)
        if let cat = thatPetIcon {
            draw(cat, at: margin + widest + gap, fraction: 1)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

/// Prints the notification permission and, if allowed, sends a test notification.
func notificationCheck() {
    let center = UNUserNotificationCenter.current()
    let done = DispatchSemaphore(value: 0)
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
        print("permission granted: \(granted)" + (error.map { " (error: \($0.localizedDescription))" } ?? ""))
        done.signal()
    }
    if done.wait(timeout: .now() + 60) == .timedOut {
        print("no answer yet: macOS is probably still showing the permission request")
        exit(2)
    }
    center.getNotificationSettings { settings in
        let names = [0: "not determined", 1: "denied", 2: "authorized", 3: "provisional", 4: "ephemeral"]
        print("status: \(names[settings.authorizationStatus.rawValue] ?? "unknown"), alerts: \(settings.alertSetting.rawValue == 2 ? "on" : "off")")
        done.signal()
    }
    done.wait()
    let content = UNMutableNotificationContent()
    content.title = appName
    content.body = "Test notification: notifications work."
    center.add(UNNotificationRequest(identifier: "test", content: content, trigger: nil)) { error in
        print(error.map { "test notification failed: \($0.localizedDescription)" } ?? "test notification sent")
        done.signal()
    }
    done.wait()
}

/// Offscreen preview of the menu's top (header and status strip) in a few states, light and dark,
/// with the native items sketched below for proportions.
func renderMenuPreview(to path: String) {
    final class Target: NSObject { @objc func noop(_ sender: Any?) {} }
    let target = Target()
    let appIcon = Bundle.main.path(forResource: "AppIcon", ofType: "icns").flatMap(NSImage.init(contentsOfFile:))
    let states: [(Bool, String, NSColor, Bool, Bool)] = [
        (true, "Ready", .systemGreen, false, false),
        (true, "Browsing the web · 2:31", .controlAccentColor, true, false),
        (false, "Off", .systemRed, false, false),
        (true, "Turning on…", .systemOrange, false, true),
    ]
    let items = ["Open Ollama", "Settings", "Quit Extension"]
    let rowHeight: CGFloat = 22
    let panelHeight = 6 + 50 + 20 + 11 + CGFloat(items.count) * rowHeight + 11 + 6
    let gap: CGFloat = 16
    let size = NSSize(width: (menuWidth + gap) * 2 + gap, height: (panelHeight + gap) * CGFloat(states.count) + gap)
    let root = NSView(frame: NSRect(origin: .zero, size: size))
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor(white: 0.5, alpha: 1).cgColor
    for (column, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
        for (row, state) in states.enumerated() {
            let panel = NSView(frame: NSRect(x: gap + CGFloat(column) * (menuWidth + gap),
                                             y: size.height - CGFloat(row + 1) * (panelHeight + gap),
                                             width: menuWidth, height: panelHeight))
            panel.appearance = NSAppearance(named: appearance)
            panel.wantsLayer = true
            panel.layer?.cornerRadius = 10
            panel.layer?.backgroundColor = (appearance == .aqua ? NSColor(white: 0.95, alpha: 1)
                                                               : NSColor(white: 0.19, alpha: 1)).cgColor
            let header = HeaderView(target: target, action: #selector(Target.noop(_:)), icon: appIcon)
            header.show(running: state.0, status: state.1, color: state.2, pulsing: state.3, busy: state.4)
            let strip = StatusStrip()
            strip.show(pet: "ThatPet", petColor: .systemGreen, reaction: "Done · 23:10")
            var y = panelHeight - 6 - 50
            header.setFrameOrigin(NSPoint(x: 0, y: y)); panel.addSubview(header)
            y -= 20
            strip.setFrameOrigin(NSPoint(x: 0, y: y)); panel.addSubview(strip)
            let ink = appearance == .aqua ? NSColor.black : NSColor.white
            func separator(_ at: CGFloat) {
                let line = NSBox(frame: NSRect(x: 14, y: at, width: menuWidth - 28, height: 1))
                line.boxType = .custom; line.borderWidth = 0
                line.fillColor = ink.withAlphaComponent(0.1)
                panel.addSubview(line)
            }
            y -= 6; separator(y); y -= 5
            for (index, title) in items.enumerated() {
                y -= rowHeight
                let image = NSImageView(frame: NSRect(x: 12, y: y + 3, width: 16, height: 16))
                image.image = symbol(["bubble.left.and.bubble.right", "gearshape", "power"][index], size: 13, weight: .regular)
                image.contentTintColor = ink.withAlphaComponent(0.85)
                let label = NSTextField(labelWithString: title)
                label.font = .menuFont(ofSize: 13)
                label.frame = NSRect(x: 34, y: y + 3, width: 160, height: 17)
                let trailing = NSTextField(labelWithString: ["", "›", "⌘Q"][index])
                trailing.font = .menuFont(ofSize: 13)
                trailing.textColor = .tertiaryLabelColor
                trailing.alignment = .right
                trailing.frame = NSRect(x: menuWidth - 80, y: y + 3, width: 66, height: 17)
                [image, label, trailing].forEach(panel.addSubview)
                if index == 1 { y -= 6; separator(y); y -= 5 }
            }
            root.addSubview(panel)
        }
    }
    let window = NSWindow(contentRect: root.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = root
    root.layoutSubtreeIfNeeded()
    guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
    root.cacheDisplay(in: root.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}
