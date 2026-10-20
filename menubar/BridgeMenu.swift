// Menu bar icon of the ThatPet Ollama Extension.
// Icon (two styles, chosen from the menu under Icon Style):
//   ThatPet | Ollama  ThatPet's cat and Ollama's llama peeking over the same edge, then "+"
//   ThatPet +         ThatPet's cat with a "+" beside it
// The cat is identical to ThatPet's own and at the same height. Full icon = on; dimmed = off.
// It sits right to the left of ThatPet's icon and follows it if you move it with Cmd+drag.
// Uses the copy of autostart.py installed in ~/Library/Application Support/OllamaThatPetBridge.
// Build with ./build_menu_app.sh; `BridgeMenu --preview file.png` draws an enlarged preview.

import AppKit
import UserNotifications

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

let thatPetHelper = "/Applications/ThatPet.app/Contents/MacOS/ThatPet"

/// ThatPet 0.4+ ignores agents that are not connected, and the bridge reports to it as the
/// Hermes agent. False only when ThatPet says Hermes is not installed or disconnected.
func thatPetLinked() -> Bool {
    let out = run(thatPetHelper, ["agents"]).output
    guard let line = out.split(separator: "\n").first(where: { $0.hasPrefix("Hermes Agent:") }) else { return true }
    return !["notInstalled", "disconnected"].contains(line.dropFirst("Hermes Agent:".count)
        .trimmingCharacters(in: .whitespaces))
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

/// The bridge's health.json: problems, current phase of a reply, last reply.
func readHealth() -> [String: Any]? {
    let file = home.appendingPathComponent("Library/Application Support/OllamaThatPetBridge/health.json")
    guard let data = try? Data(contentsOf: file) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

/// 75 -> "1:15"
func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

/// A problem the bridge reported in health.json, if any: (what, hint).
func healthWarning(_ health: [String: Any]?) -> (title: String, hint: String)? {
    guard let health = health else { return nil }
    if health["read_problem"] is String {
        return ("Can't read Ollama", "see the log")
    }
    if (health["stalled_turns"] as? Int ?? 0) > 0 {
        return ("Reply end not detected", "Ollama changed?")
    }
    if health["end_detection"] as? String == "timeout" {
        return ("app.log not found", "using a timeout")
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

/// Width of the menu's custom rows.
let menuWidth: CGFloat = 320

/// "● text" with a small colored dot.
func dotted(_ text: String, dot: NSColor?, size: CGFloat) -> NSAttributedString {
    let line = NSMutableAttributedString()
    if let dot = dot {
        line.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: dot,
                                                                   .font: NSFont.systemFont(ofSize: size - 3)]))
    }
    line.append(NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                                                               .font: NSFont.systemFont(ofSize: size)]))
    return line
}

/// Soft rounded tile behind the icon, like the modules in Control Center.
final class TileView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 9
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }
}

/// On/off switch: green when on, red when off, orange while it is switching.
final class ColorSwitch: NSControl {
    private(set) var isOn = false
    private var knob: CGFloat = 0  // 0 = left (off), 1 = right (on)
    private var animation: Timer?

    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 42, height: 24) }

    func set(on: Bool, animated: Bool) {
        guard on != isOn || animation == nil && knob != (on ? 1 : 0) else { return }
        isOn = on
        let target: CGFloat = on ? 1 : 0
        animation?.invalidate()
        guard animated else {
            knob = target
            needsDisplay = true
            return
        }
        let start = knob, began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self = self else { return timer.invalidate() }
            let t = min(1, (CACurrentMediaTime() - began) / 0.18)
            self.knob = start + (target - start) * CGFloat(t * (2 - t))  // ease out
            self.needsDisplay = true
            if t >= 1 {
                timer.invalidate()
                self.animation = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)  // keeps running while the menu is open
        animation = timer
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 1, y: (bounds.height - 22) / 2, width: bounds.width - 2, height: 22)
        (!isEnabled ? NSColor.systemOrange : isOn ? NSColor.systemGreen : NSColor.systemRed).setFill()
        NSBezierPath(roundedRect: track, xRadius: 11, yRadius: 11).fill()
        let size: CGFloat = 18
        let knobRect = NSRect(x: track.minX + 2 + (track.width - 4 - size) * knob, y: track.minY + 2,
                              width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Menus deliver mouse-up to custom views reliably, so the switch flips on mouse-up.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        flip()
    }

    private func flip() {
        set(on: !isOn, animated: true)
        sendAction(action, to: target)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityLabel() -> String? { "Extension on or off" }
    override func accessibilityValue() -> Any? { isOn }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        flip()
        return true
    }
}

/// Top of the menu: icon on a tile, name, status with a colored dot, and an on/off switch.
final class HeaderView: NSView {
    let tile = TileView()
    let icon = NSImageView(image: extensionIcon())
    let title = NSTextField(labelWithString: appName)
    let status = NSTextField(labelWithString: "")
    let toggle = ColorSwitch()
    lazy var iconWidth = icon.widthAnchor.constraint(equalToConstant: icon.image?.size.width ?? 24)

    init(target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 60))
        autoresizingMask = [.width]
        icon.contentTintColor = .labelColor
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        status.font = .systemFont(ofSize: 11)
        toggle.target = target
        toggle.action = action
        for view in [tile, icon, title, status, toggle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.heightAnchor.constraint(equalToConstant: 34),
            tile.widthAnchor.constraint(equalTo: icon.widthAnchor, constant: 16),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            iconWidth,
            icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 11),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.topAnchor.constraint(equalTo: centerYAnchor, constant: 3),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.widthAnchor.constraint(equalToConstant: 42),
            toggle.heightAnchor.constraint(equalToConstant: 24),
            title.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(running: Bool, busy: String? = nil) {
        icon.image = extensionIcon()
        iconWidth.constant = icon.image?.size.width ?? 24
        toggle.set(on: running, animated: window != nil)
        toggle.isEnabled = busy == nil
        icon.alphaValue = running ? 1 : 0.4
        status.attributedStringValue = dotted(
            busy ?? (running ? "On · ThatPet reacts to Ollama" : "Off · ThatPet ignores Ollama"),
            dot: busy != nil ? .systemOrange : running ? .systemGreen : .systemRed, size: 11)
    }
}

/// A status line in the menu: symbol and label on the left, value on the right.
final class InfoRow: NSView {
    let symbolView = NSImageView()
    let label = NSTextField(labelWithString: "")
    let value = NSTextField(labelWithString: "")

    init(symbol name: String, label text: String, tint: NSColor = .secondaryLabelColor) {
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 24))
        autoresizingMask = [.width]
        symbolView.image = symbol(name, size: 12, weight: .medium)
        symbolView.contentTintColor = tint
        label.stringValue = text
        label.font = .menuFont(ofSize: 13)
        value.alignment = .right
        value.lineBreakMode = .byTruncatingTail
        for view in [symbolView, label, value] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func setSymbol(_ name: String) {
        symbolView.image = symbol(name, size: 12, weight: .medium)
    }

    func set(_ text: String, dot: NSColor? = nil) {
        value.attributedStringValue = dotted(text, dot: dot, size: 13)
    }
}

final class Controller: NSObject, NSMenuDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem?
    var placedAt: Double?  // ThatPet position used when the icon was created
    var petPID: pid_t?
    var running = false
    let menu = NSMenu()
    lazy var header = HeaderView(target: self, action: #selector(switchToggled(_:)))
    let petRow = InfoRow(symbol: "pawprint.fill", label: "ThatPet")
    let reactionRow = InfoRow(symbol: "clock", label: "Last reaction")
    let warningRow = InfoRow(symbol: "exclamationmark.triangle.fill", label: "", tint: .systemOrange)
    let warningItem = NSMenuItem()
    let nowRow = InfoRow(symbol: "ellipsis.bubble", label: "", tint: .controlAccentColor)
    let nowItem = NSMenuItem()
    let notifyItem = NSMenuItem(title: "Notify When a Reply Is Ready", action: #selector(toggleNotify),
                                keyEquivalent: "")
    let styleMenu = NSMenu()
    let reconnectItem = NSMenuItem(title: "Reconnect to ThatPet", action: #selector(reconnect), keyEquivalent: "")
    var linked = true
    var liveTimer: Timer?
    var lastSeenEnd: Double = 0  // end time of the last reply already handled
    // macOS refuses system notifications to apps without a developer certificate (this one is
    // signed ad hoc); then AppleScript notifications are used, which macOS shows as Script Editor.
    var systemNotificationsAllowed = false

    func askNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { self.systemNotificationsAllowed = granted }
        }
    }

    var notifyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "NotifyWhenReady") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "NotifyWhenReady") }
    }

    override init() {
        super.init()
        menu.delegate = self
        let headerItem = NSMenuItem()
        headerItem.view = header
        menu.addItem(headerItem)
        menu.addItem(.separator())
        nowItem.view = nowRow
        nowItem.isHidden = true
        menu.addItem(nowItem)
        for row in [petRow, reactionRow] {
            let item = NSMenuItem()
            item.view = row
            menu.addItem(item)
        }
        warningItem.view = warningRow
        warningItem.isHidden = true
        menu.addItem(warningItem)
        reconnectItem.target = self
        reconnectItem.image = symbol("link", size: 13, weight: .regular)
        reconnectItem.isHidden = true
        menu.addItem(reconnectItem)
        menu.addItem(.separator())
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: ollamaID) != nil {
            addItem("Open Ollama", "bubble.left.and.bubble.right", #selector(openOllama))
        }
        addItem("Show Log", "doc.text", #selector(showLog))
        addItem("Open Project Folder", "folder", #selector(openProject))
        menu.addItem(.separator())
        notifyItem.target = self
        notifyItem.image = symbol("bell", size: 13, weight: .regular)
        menu.addItem(notifyItem)
        for style in IconStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(chooseStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.image = extensionIcon(style)  // preview of the style
            styleMenu.addItem(item)
        }
        let styleItem = NSMenuItem(title: "Icon Style", action: nil, keyEquivalent: "")
        styleItem.image = symbol("paintbrush", size: 13, weight: .regular)
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)
        menu.addItem(.separator())
        addItem("Quit Extension", "power", #selector(quit), key: "q")
        // Replies that ended before this launch must not trigger a notification.
        lastSeenEnd = (readHealth()?["last_turn"] as? [String: Any])?["ended"] as? Double ?? 0
        UNUserNotificationCenter.current().delegate = self
        if notifyEnabled {
            askNotificationPermission()
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
        notifyIfReplyFinished(readHealth())
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
        let health = readHealth()
        let warning = running && !linked ? ("ThatPet ignores the extension", "not linked")
                                         : running ? healthWarning(health) : nil
        reconnectItem.isHidden = linked
        warningRow.label.stringValue = warning?.title ?? ""
        warningRow.set(warning?.hint ?? "")
        warningItem.isHidden = warning == nil
        showPhase(health)
        notifyItem.state = notifyEnabled ? .on : .off
        for item in styleMenu.items {
            item.state = item.representedObject as? String == IconStyle.current.rawValue ? .on : .off
        }
        let petOpen = thatPet() != nil
        petRow.set(!petOpen ? "Not open" : linked ? "Open" : "Open · not linked",
                   dot: !petOpen ? .tertiaryLabelColor : linked ? .systemGreen : .systemOrange)
        reactionRow.set(lastReaction().map { "\($0.name) · \($0.time)" } ?? "None yet")
        guard let button = statusItem?.button else { return }
        button.image = extensionIcon()
        button.appearsDisabled = !running
        button.toolTip = "\(appName): " + (running ? "on" : "off")
    }

    /// "Browsing the web · 2:31 (6:02 total)" while Ollama is replying; hidden otherwise.
    func showPhase(_ health: [String: Any]?) {
        guard running, let phase = health?["phase"] as? String,
              let since = health?["phase_since"] as? Double else {
            nowItem.isHidden = true
            return
        }
        let now = Date().timeIntervalSince1970
        var elapsed = clock(now - since)
        if let start = health?["turn_since"] as? Double, since - start >= 2 {
            elapsed += " (\(clock(now - start)) total)"
        }
        nowRow.label.stringValue = phase
        nowRow.set(elapsed)
        nowRow.setSymbol(["Thinking": "ellipsis.bubble", "Browsing the web": "globe",
                          "Writing the answer": "text.cursor"][phase] ?? "wrench.and.screwdriver")
        nowItem.isHidden = false
    }

    func menuWillOpen(_ menu: NSMenu) {
        linked = thatPetLinked()
        refresh()
        // Tick every second while the menu is open (common modes: menus track events).
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    @objc func tick() { showPhase(readHealth()) }

    /// Notification when a long reply is ready and Ollama is not in front.
    func notifyIfReplyFinished(_ health: [String: Any]?) {
        guard let last = health?["last_turn"] as? [String: Any], let ended = last["ended"] as? Double,
              ended > lastSeenEnd else { return }
        lastSeenEnd = ended
        let seconds = last["seconds"] as? Double ?? 0
        let outcome = last["outcome"] as? String ?? ""
        guard notifyEnabled, seconds >= 30, outcome == "completed" || outcome == "failed",
              Date().timeIntervalSince1970 - ended < 60,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier != ollamaID else { return }
        let title = outcome == "completed" ? "Ollama replied" : "Ollama stopped with an error"
        let body = (outcome == "completed" ? "Ready after " : "After ") + clock(seconds)
        guard systemNotificationsAllowed else {
            // Text passed as arguments, never pasted into the script.
            run("/usr/bin/osascript", ["-e", "on run argv",
                                       "-e", "display notification (item 2 of argv) with title (item 1 of argv) sound name \"Glass\"",
                                       "-e", "end run", title, body + " · open Ollama to read it"])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body + " · click to open Ollama"
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.openOllama() }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Links the extension again with ThatPet's own command (an inert Hermes plugin).
    @objc func reconnect() {
        run(thatPetHelper, ["connect", "hermes"])
        linked = thatPetLinked()
        refresh()
    }

    @objc func toggleNotify() {
        notifyEnabled.toggle()
        if notifyEnabled {
            askNotificationPermission()
        }
        refresh()
    }

    @objc func switchToggled(_ sender: ColorSwitch) {
        let turnOn = sender.isOn
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

// `BridgeMenu --notification-check`: print the notification permission and, if allowed,
// send a test notification.
if CommandLine.arguments.dropFirst().first == "--notification-check" {
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
    exit(0)
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
