// Menu bar icon of the ThatPet Ollama Extension.
// Icon (two styles, chosen from the menu under Icon Style):
//   ThatPet | Ollama  ThatPet's cat and Ollama's llama peeking over the same edge, then "+"
//   ThatPet +         ThatPet's cat with a "+" beside it
// The cat is identical to ThatPet's own and at the same height. Full icon = on; dimmed = off.
// It sits right to the left of ThatPet's icon and follows it if you move it with Cmd+drag.
// Uses the copy of autostart.py installed in ~/Library/Application Support/OllamaThatPetBridge.
// Build with ./build_menu_app.sh; `BridgeMenu --preview file.png` draws an enlarged preview.

import AppKit

let appName = "ThatPet Ollama Extension"
let bridgeLabel = "local.ollama-thatpet-bridge"
let thatPetID = "com.thatlev.ThatPet"
let ollamaID = "com.electron.ollama"
let home = FileManager.default.homeDirectoryForCurrentUser
let autostart = home.appendingPathComponent("Library/Application Support/OllamaThatPetBridge/autostart.py").path
let logFile = home.appendingPathComponent("Library/Logs/ollama-thatpet-bridge.log")
let projectDir = home.appendingPathComponent("Documents/Ollama ThatPet Bridge")
// Key where macOS saves an icon's position: higher number = further left.
let positionKey = "NSStatusItem Preferred Position Item-0"

@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus,
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

func bridgeRunning() -> Bool {
    run("/bin/launchctl", ["print", "gui/\(getuid())/\(bridgeLabel)"]).status == 0
}

func thatPet() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: thatPetID).first
}

/// Position macOS saved for ThatPet's icon (read-only; it exists after a Cmd+drag).
func thatPetSavedPosition() -> Double? {
    let app = thatPetID as CFString
    CFPreferencesAppSynchronize(app)
    let keys = CFPreferencesCopyKeyList(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
    guard let key = keys.sorted().first(where: { $0.hasPrefix("NSStatusItem Preferred Position") })
    else { return nil }
    return (CFPreferencesCopyAppValue(key as CFString, app) as? NSNumber)?.doubleValue
}

/// A problem the bridge reported in health.json, if any.
func healthWarning() -> String? {
    let file = home.appendingPathComponent("Library/Application Support/OllamaThatPetBridge/health.json")
    guard let data = try? Data(contentsOf: file),
          let health = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if health["read_problem"] is String {
        return "Can't read Ollama's data — see the log"
    }
    if (health["stalled_turns"] as? Int ?? 0) > 0 {
        return "Reply end not detected — Ollama may have changed"
    }
    if health["end_detection"] as? String == "timeout" {
        return "Ollama's app.log not found — using a timeout"
    }
    return nil
}

/// Last reaction the bridge sent to the pet, from its log: ("Done", "23:10").
func lastReaction() -> (name: String, time: String)? {
    guard let handle = try? FileHandle(forReadingFrom: logFile) else { return nil }
    defer { try? handle.close() }
    let size = handle.seekToEndOfFile()
    handle.seek(toFileOffset: size > 16_384 ? size - 16_384 : 0)
    let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    let names = ["UserPromptSubmit": "Thinking", "Stop": "Done", "StopFailure": "Error", "SessionStart": "Idle",
                 "PreToolUse": "Working", "PostToolUse": "Thinking"]
    // "inviato" also matches log lines written by the earlier Italian version
    let pattern = try! NSRegularExpression(pattern: #"^\[(\d\d:\d\d):\d\d\] Hook (?:sent|inviato): (\w+)"#,
                                           options: .anchorsMatchLines)
    guard let match = pattern.matches(in: tail, range: NSRange(tail.startIndex..., in: tail)).last,
          let time = Range(match.range(at: 1), in: tail), let event = Range(match.range(at: 2), in: tail)
    else { return nil }
    return (names[String(tail[event])] ?? String(tail[event]), String(tail[time]))
}

/// A menu bar icon (1x and @2x) read from another app's bundle, without modifying it.
func bundleIcon(_ resources: String, _ name: String, size: CGFloat) -> NSImage? {
    guard let image = NSImage(contentsOfFile: resources + name + ".png") else { return nil }
    image.size = NSSize(width: size, height: size)
    if let retina = NSImageRep(contentsOfFile: resources + name + "@2x.png") {
        retina.size = image.size
        image.addRepresentation(retina)
    }
    return image
}

let thatPetIcon = bundleIcon("/Applications/ThatPet.app/Contents/Resources/", "MenuBarIcon", size: 18)
let ollamaIcon = bundleIcon("/Applications/Ollama.app/Contents/Resources/", "ollama", size: 16)

func symbol(_ name: String, size: CGFloat = 8, weight: NSFont.Weight = .black) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
}

/// The two icon designs; the choice is saved in the app's preferences.
enum IconStyle: String, CaseIterable {
    case petAndOllama = "pet-ollama"  // ThatPet's cat and Ollama's llama peeking over the same edge, then "+"
    case petPlus = "pet-plus"         // ThatPet's cat with a "+" beside it

    var title: String { self == .petAndOllama ? "ThatPet | Ollama" : "ThatPet +" }

    static var current: IconStyle {
        get { IconStyle(rawValue: UserDefaults.standard.string(forKey: "IconStyle") ?? "") ?? .petAndOllama }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "IconStyle") }
    }
}

/// ThatPet's cat, identical and at the same height as its own, optionally with Ollama's
/// llama peeking over the same edge, and a "+" at the end.
func extensionIcon(_ style: IconStyle = .current) -> NSImage {
    let withLlama = style == .petAndOllama && ollamaIcon != nil
    let image = NSImage(size: NSSize(width: withLlama ? 37 : 24, height: 18), flipped: false) { _ in
        if let cat = thatPetIcon {
            cat.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        } else {
            symbol("cat.fill")?.draw(in: NSRect(x: 2, y: 3, width: 13, height: 13))
        }
        if withLlama, let llama = ollamaIcon {
            // only the part above the edge, so the llama peeks out like the cat
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: 17, y: 6, width: 13, height: 12)).addClip()
            llama.draw(in: NSRect(x: 17, y: 2.5, width: 13, height: 13))
            NSGraphicsContext.restoreGraphicsState()
            // ThatPet's edge (1 pt, y 5...6), extended under the llama with a rounded end
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 16, y: 5, width: 14.5, height: 1), xRadius: 0.5, yRadius: 0.5).fill()
        }
        symbol("plus")?.draw(in: NSRect(x: withLlama ? 30.5 : 17.5, y: 10, width: 6.5, height: 6.5))
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = appName
    return image
}

/// Top of the menu: icon, name, status with a colored dot, and an on/off switch.
final class HeaderView: NSView {
    let icon = NSImageView(image: extensionIcon())
    let title = NSTextField(labelWithString: appName)
    let status = NSTextField(labelWithString: "")
    let toggle = NSSwitch()
    lazy var iconWidth = icon.widthAnchor.constraint(equalToConstant: icon.image?.size.width ?? 24)

    init(target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 54))
        autoresizingMask = [.width]
        icon.contentTintColor = .labelColor
        title.font = .boldSystemFont(ofSize: 13)
        status.font = .systemFont(ofSize: 11)
        toggle.target = target
        toggle.action = action
        for view in [icon, title, status, toggle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth,
            icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(running: Bool, busy: String? = nil) {
        icon.image = extensionIcon()
        iconWidth.constant = icon.image?.size.width ?? 24
        toggle.state = running ? .on : .off
        toggle.isEnabled = busy == nil
        icon.alphaValue = running ? 1 : 0.4
        let dot = NSAttributedString(string: "● ", attributes: [
            .foregroundColor: busy != nil ? NSColor.systemOrange : running ? NSColor.systemGreen : NSColor.tertiaryLabelColor,
            .font: NSFont.systemFont(ofSize: 9)])
        let text = NSAttributedString(
            string: busy ?? (running ? "On — ThatPet reacts to Ollama" : "Off — ThatPet ignores Ollama"),
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)])
        let line = NSMutableAttributedString(attributedString: dot)
        line.append(text)
        status.attributedStringValue = line
    }
}

final class Controller: NSObject, NSMenuDelegate {
    var statusItem: NSStatusItem?
    var placedAt: Double?  // ThatPet position used when the icon was created
    var petPID: pid_t?
    var running = false
    let menu = NSMenu()
    lazy var header = HeaderView(target: self, action: #selector(switchToggled(_:)))
    let petItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let reactionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let warningItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let styleMenu = NSMenu()

    override init() {
        super.init()
        menu.delegate = self
        let headerItem = NSMenuItem()
        headerItem.view = header
        menu.addItem(headerItem)
        menu.addItem(.separator())
        petItem.image = symbol("pawprint", size: 13, weight: .regular)
        reactionItem.image = symbol("clock", size: 13, weight: .regular)
        menu.addItem(petItem)
        menu.addItem(reactionItem)
        warningItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange])))
        warningItem.isHidden = true
        menu.addItem(warningItem)
        menu.addItem(.separator())
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: ollamaID) != nil {
            addItem("Open Ollama", "bubble.left.and.bubble.right", #selector(openOllama))
        }
        addItem("Show Log", "doc.text", #selector(showLog))
        addItem("Open Project Folder", "folder", #selector(openProject))
        for style in IconStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(chooseStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            styleMenu.addItem(item)
        }
        let styleItem = NSMenuItem(title: "Icon Style", action: nil, keyEquivalent: "")
        styleItem.image = symbol("paintbrush", size: 13, weight: .regular)
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)
        menu.addItem(.separator())
        let quitItem = addItem("Quit", "power", #selector(quit), key: "q")
        if #available(macOS 14.4, *) {
            quitItem.subtitle = "Stops the extension until the next login"
        }
        createItemAfterThatPet(giveUpAt: Date().addingTimeInterval(90))
        Timer.scheduledTimer(timeInterval: 10, target: self, selector: #selector(refresh),
                             userInfo: nil, repeats: true)
        Timer.scheduledTimer(timeInterval: 3, target: self, selector: #selector(followThatPet),
                             userInfo: nil, repeats: true)
    }

    @discardableResult
    func addItem(_ title: String, _ image: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = symbol(image, size: 13, weight: .regular)
        menu.addItem(item)
        return item
    }

    /// Create the icon after ThatPet's: when ThatPet has no saved position, macOS puts a
    /// new icon right to the left of the most recently created one, i.e. ThatPet's.
    func createItemAfterThatPet(giveUpAt deadline: Date) {
        if let pet = thatPet() {
            // ~3 s after ThatPet starts, to let it create its icon
            let wait = max(0, (pet.launchDate ?? .distantPast).addingTimeInterval(3).timeIntervalSinceNow)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.createItem() }
        } else if Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.createItemAfterThatPet(giveUpAt: deadline)
            }
        } else {
            createItem()  // ThatPet is not open: show the icon anyway
        }
    }

    /// (Re)create the icon right to the left of ThatPet's.
    func createItem() {
        if let old = statusItem {
            NSStatusBar.system.removeStatusItem(old)
        }
        let position = thatPetSavedPosition()
        if let position = position {
            UserDefaults.standard.set(position + 1, forKey: positionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: positionKey)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        statusItem = item
        placedAt = position
        petPID = thatPet()?.processIdentifier
        refresh()
    }

    /// If you move ThatPet with Cmd+drag (or reopen it), the icon follows.
    @objc func followThatPet() {
        guard statusItem != nil, let pet = thatPet() else { return }
        let position = thatPetSavedPosition()
        if let position = position, position != placedAt {
            createItem()
        } else if position == nil, pet.processIdentifier != petPID {
            // ThatPet reopened without a saved position: its icon went to the far left
            petPID = pet.processIdentifier
            createItemAfterThatPet(giveUpAt: Date().addingTimeInterval(30))
        }
    }

    @objc func refresh() {
        running = bridgeRunning()
        header.show(running: running)
        let warning = running ? healthWarning() : nil
        warningItem.title = warning ?? ""
        warningItem.isHidden = warning == nil
        for item in styleMenu.items {
            item.state = item.representedObject as? String == IconStyle.current.rawValue ? .on : .off
        }
        petItem.title = thatPet() != nil ? "ThatPet is open" : "ThatPet is not open"
        if let last = lastReaction() {
            reactionItem.title = "Last reaction: \(last.name) at \(last.time)"
        } else {
            reactionItem.title = "No reactions yet"
        }
        guard let button = statusItem?.button else { return }
        button.image = extensionIcon()
        button.appearsDisabled = !running
        button.toolTip = "\(appName): " + (running ? "on" : "off")
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    @objc func switchToggled(_ sender: NSSwitch) {
        let turnOn = sender.state == .on
        header.show(running: turnOn, busy: turnOn ? "Turning on…" : "Turning off…")
        DispatchQueue.global().async {
            let result = run("/usr/bin/python3", ["-I", autostart, turnOn ? "start" : "stop"])
            DispatchQueue.main.async {
                self.refresh()
                if result.status != 0 {
                    self.menu.cancelTracking()
                    let alert = NSAlert()
                    alert.messageText = appName
                    alert.informativeText = result.output.isEmpty ? "The operation failed." : result.output
                    alert.alertStyle = .warning
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }
    }

    @objc func openOllama() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ollamaID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc func chooseStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let style = IconStyle(rawValue: raw) {
            IconStyle.current = style
            refresh()
        }
    }

    @objc func showLog() { NSWorkspace.shared.open(logFile) }
    @objc func openProject() { NSWorkspace.shared.open(projectDir) }

    /// Stops the bridge and the icon until the next login (an "Off" switch stays off).
    @objc func quit() {
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(bridgeLabel)"])
        NSApp.terminate(nil)
    }
}

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

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--preview" {
    renderPreview(to: CommandLine.arguments[2])
    exit(0)
}

// A single icon: if another copy is already open, exit right away.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon
let controller = Controller()
app.run()
