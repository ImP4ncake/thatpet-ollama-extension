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
