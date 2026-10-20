// The menu bar icon and its menu. The bridge runs inside this app, on its own thread.

import AppKit
import UserNotifications

/// Key where macOS saves an icon's position: higher number = further left.
let positionKey = "NSStatusItem Preferred Position Item-0"

func thatPet() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: thatPetID).first
}

/// Position macOS saved for ThatPet's icon (read-only; it exists after a Cmd+drag).
func thatPetSavedPosition() -> Double? {
    let app = thatPetID as CFString
    CFPreferencesAppSynchronize(app)
    let keys = CFPreferencesCopyKeyList(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
    guard let key = keys.sorted().first(where: { $0.hasPrefix("NSStatusItem Preferred Position") }) else { return nil }
    return (CFPreferencesCopyAppValue(key as CFString, app) as? NSNumber)?.doubleValue
}

/// The bridge's health.json: problems, current phase of a reply, last reply, update checks.
func readHealth() -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: healthFilePath) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

/// A problem the bridge reported, if any: (what, hint).
func healthWarning(_ health: [String: Any]?) -> (title: String, hint: String)? {
    guard let health = health else { return nil }
    if let problem = ((health["update_check"] as? [String: Any])?["problems"] as? [String])?.first {
        return (problem, "after the update")
    }
    if health["read_problem"] is String { return ("Can't read Ollama", "see the log") }
    if (health["stalled_turns"] as? Int ?? 0) > 0 { return ("Reply end not detected", "Ollama changed?") }
    if health["end_detection"] as? String == "timeout" { return ("app.log not found", "using a timeout") }
    return nil
}

/// Last reaction sent to the pet, from the log: ("Done", "23:10").
func lastReaction() -> (name: String, time: String)? {
    guard let handle = FileHandle(forReadingAtPath: logFilePath) else { return nil }
    defer { try? handle.close() }
    let size = handle.seekToEndOfFile()
    handle.seek(toFileOffset: size > 16_384 ? size - 16_384 : 0)
    let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    let names = ["UserPromptSubmit": "Thinking", "Stop": "Done", "StopFailure": "Error", "SessionStart": "Idle",
                 "PreToolUse": "Working", "PostToolUse": "Thinking"]
    let pattern = try! NSRegularExpression(pattern: #"^\[(\d\d:\d\d):\d\d\] Hook sent: (\w+)"#, options: .anchorsMatchLines)
    guard let match = pattern.matches(in: tail, range: NSRange(tail.startIndex..., in: tail)).last,
          let time = Range(match.range(at: 1), in: tail), let event = Range(match.range(at: 2), in: tail) else { return nil }
    return (names[String(tail[event])] ?? String(tail[event]), String(tail[time]))
}

/// True when Ollama is the app in front and one of its windows is on the current screen.
/// Window owners and sizes need no screen-recording permission.
func ollamaVisible() -> Bool {
    guard let ollama = NSRunningApplication.runningApplications(withBundleIdentifier: ollamaID).first,
          !ollama.isHidden, NSWorkspace.shared.frontmostApplication?.processIdentifier == ollama.processIdentifier
    else { return false }
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return windows.contains { window in
        (window[kCGWindowOwnerPID as String] as? Int32) == ollama.processIdentifier
            && (window[kCGWindowLayer as String] as? Int) == 0
            && ((window[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0) > 200
    }
}

final class Controller: NSObject, NSMenuDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem?
    var placedAt: Double?  // ThatPet position used when the icon was created
    var petPID: pid_t?
    let menu = NSMenu()
    lazy var header = HeaderView(target: self, action: #selector(switchToggled(_:)))
    let strip = StatusStrip()
    let warningRow = InfoRow(symbol: "exclamationmark.triangle.fill", label: "", tint: .systemOrange)
    let warningItem = NSMenuItem()
    let reconnectItem = NSMenuItem(title: "Reconnect to ThatPet", action: #selector(reconnect), keyEquivalent: "")
    let updateItem = NSMenuItem(title: "", action: #selector(installUpdate), keyEquivalent: "")
    let notifyItem = NSMenuItem(title: "Notifications", action: #selector(toggleNotify), keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
    let autoUpdateItem = NSMenuItem(title: "Automatic Updates", action: #selector(toggleAutoUpdate), keyEquivalent: "")
    let styleMenu = NSMenu()
    var liveTimer: Timer?
    var linked = true
    var busy: String?             // "Turning on…" while the switch acts
    var lastSeenEnd: Double = 0   // end time of the last reply already handled
    var lastUpdateState = ""      // ThatPet/Ollama update check already notified
    var systemNotificationsAllowed = false

    // The bridge, on its own thread. Off (switch) is remembered across launches.
    private var bridge: Bridge?
    private var quitting = false
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "BridgeEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "BridgeEnabled") }
    }
    var running: Bool { enabled && bridge != nil }

    var notifyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "NotifyWhenReady") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "NotifyWhenReady") }
    }

    override init() {
        super.init()
        menu.delegate = self
        for view in [header, strip] as [NSView] {
            let item = NSMenuItem()
            item.view = view
            menu.addItem(item)
        }
        warningItem.view = warningRow
        warningItem.isHidden = true
        menu.addItem(warningItem)
        for (item, image) in [(reconnectItem, "link"), (updateItem, "arrow.down.circle")] {
            item.target = self
            item.image = symbol(image, size: 13, weight: .regular)
            item.isHidden = true
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: ollamaID) != nil {
            menu.addItem(item("Open Ollama", "bubble.left.and.bubble.right", #selector(openOllama)))
        }
        let settings = NSMenu()
        for (option, image) in [(notifyItem, "bell"), (loginItem, "power.circle"), (autoUpdateItem, "arrow.clockwise")] {
            option.target = self
            option.image = symbol(image, size: 13, weight: .regular)
            settings.addItem(option)
        }
        for style in IconStyle.allCases {
            let styleItem = NSMenuItem(title: style.title, action: #selector(chooseStyle(_:)), keyEquivalent: "")
            styleItem.target = self
            styleItem.representedObject = style.rawValue
            styleItem.image = extensionIcon(style)
            styleMenu.addItem(styleItem)
        }
        let styleItem = NSMenuItem(title: "Icon Style", action: nil, keyEquivalent: "")
        styleItem.image = symbol("paintbrush", size: 13, weight: .regular)
        styleItem.submenu = styleMenu
        settings.addItem(styleItem)
        settings.addItem(.separator())
        settings.addItem(item("Check for Updates…", "arrow.down.app", #selector(checkForUpdates)))
        settings.addItem(item("Show Log", "doc.text", #selector(showLog)))
        settings.addItem(item("About & Help", "info.circle", #selector(openProject)))
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.image = symbol("gearshape", size: 13, weight: .regular)
        settingsItem.submenu = settings
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(item("Quit Extension", "power", #selector(quit), key: "q"))

        lastSeenEnd = (readHealth()?["last_turn"] as? [String: Any])?["ended"] as? Double ?? 0
        UNUserNotificationCenter.current().delegate = self
        askNotificationPermission()
        Updater.shared.onChange = { [weak self] in self?.refresh() }
        if enabled { startBridge() }
        createItemAfterThatPet(giveUpAt: Date().addingTimeInterval(90))
        Timer.scheduledTimer(timeInterval: 10, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        Timer.scheduledTimer(timeInterval: 3, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        // Look for an update a minute after launch, then every 6 hours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self.automaticUpdateCheck() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.automaticUpdateCheck() }
        announceUpdateIfJustUpdated()
    }

    func item(_ title: String, _ image: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = symbol(image, size: 13, weight: .regular)
        return item
    }

    // MARK: Bridge

    func startBridge() {
        guard bridge == nil else { return }
        var config = BridgeConfig()
        config.waitForLock = true
        let started = Bridge(config: config)
        bridge = started
        Thread.detachNewThread { [weak self] in
            started.serve()
            DispatchQueue.main.async {
                guard let self = self, self.bridge === started else { return }
                self.bridge = nil
                self.refresh()
                // It stopped by itself (e.g. Ollama not installed yet): try again in 30 s.
                if self.enabled && !self.quitting {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if self.enabled { self.startBridge() } }
                }
            }
        }
    }

    /// Stops the bridge and waits for it (it ends an open turn, so the pet goes back to idle).
    func stopBridge() {
        guard let current = bridge else { return }
        bridge = nil
        current.stop()
        let deadline = Date().addingTimeInterval(5)
        while lockHeld(), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    }

    private func lockHeld() -> Bool {
        let fd = open(stateDirectory + "/bridge.lock", O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    // MARK: Icon placement (right next to ThatPet's)

    /// Create the icon after ThatPet's: when ThatPet has no saved position, macOS puts a
    /// new icon right to the left of the most recently created one, i.e. ThatPet's.
    func createItemAfterThatPet(giveUpAt deadline: Date) {
        if let pet = thatPet() {
            let wait = max(0, (pet.launchDate ?? .distantPast).addingTimeInterval(3).timeIntervalSinceNow)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.createItem() }
        } else if Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.createItemAfterThatPet(giveUpAt: deadline) }
        } else {
            createItem()  // ThatPet is not open: show the icon anyway
        }
    }

    /// (Re)create the icon right to the left of ThatPet's.
    func createItem() {
        if let old = statusItem { NSStatusBar.system.removeStatusItem(old) }
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

    @objc func poll() {
        let health = readHealth()
        notifyIfReplyFinished(health)
        notifyIfUpdateChecked(health)
        // If you move ThatPet with Cmd+drag (or reopen it), the icon follows.
        guard statusItem != nil, let pet = thatPet() else { return }
        let position = thatPetSavedPosition()
        if let position = position, position != placedAt {
            createItem()
        } else if position == nil, pet.processIdentifier != petPID {
            petPID = pet.processIdentifier
            createItemAfterThatPet(giveUpAt: Date().addingTimeInterval(30))
        }
    }

    // MARK: Menu contents

    @objc func refresh() {
        let health = readHealth()
        showStatus(health)
        let warning = running && !linked ? ("ThatPet ignores the extension", "not linked")
                    : running ? healthWarning(health) : nil
        warningRow.label.stringValue = warning?.title ?? ""
        warningRow.set(warning?.hint ?? "")
        warningItem.isHidden = warning == nil
        reconnectItem.isHidden = linked
        let petOpen = thatPet() != nil
        strip.show(pet: !petOpen ? "ThatPet closed" : linked ? "ThatPet" : "Not linked",
                   petColor: !petOpen ? .tertiaryLabelColor : linked ? .systemGreen : .systemOrange,
                   reaction: lastReaction().map { "\($0.name) · \($0.time)" } ?? "No reactions yet")
        notifyItem.state = notifyEnabled ? .on : .off
        loginItem.state = Setup.openAtLogin ? .on : .off
        autoUpdateItem.state = Updater.shared.automatic ? .on : .off
        for item in styleMenu.items {
            item.state = item.representedObject as? String == IconStyle.current.rawValue ? .on : .off
        }
        switch Updater.shared.state {
        case .available(let version):
            updateItem.title = "Install Update \(version)"
            updateItem.isHidden = false
        case .installing:
            updateItem.title = "Installing the update…"
            updateItem.isHidden = false
        default:
            updateItem.isHidden = true
        }
        guard let button = statusItem?.button else { return }
        button.image = extensionIcon()
        button.appearsDisabled = !running
        button.toolTip = "\(appName): " + (running ? "on" : "off")
    }

    /// The header's status line: "Ready", "Off", or what Ollama is doing, with a timer.
    func showStatus(_ health: [String: Any]?) {
        if let busy = busy {
            header.show(running: enabled, status: busy, color: .systemOrange, busy: true)
        } else if !running {
            header.show(running: false, status: "Off", color: .systemRed)
        } else if let phase = health?["phase"] as? String, let since = health?["phase_since"] as? Double {
            header.show(running: true, status: "\(phase) · \(clock(Date().timeIntervalSince1970 - since))",
                        color: .controlAccentColor, pulsing: true)
        } else {
            header.show(running: true, status: "Ready", color: .systemGreen)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        linked = Setup.thatPetLinked
        refresh()
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)  // menus track events in their own run loop mode
        liveTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    @objc func tick() { showStatus(readHealth()) }

    // MARK: Notifications

    // macOS refuses system notifications to apps without a developer certificate when the user
    // hasn't allowed them; then AppleScript notifications are used (shown as Script Editor).
    func askNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { self.systemNotificationsAllowed = granted }
        }
    }

    /// A notification when a reply took 10 s or more and Ollama is not on screen.
    func notifyIfReplyFinished(_ health: [String: Any]?) {
        guard let last = health?["last_turn"] as? [String: Any], let ended = last["ended"] as? Double,
              ended > lastSeenEnd else { return }
        lastSeenEnd = ended
        let seconds = last["seconds"] as? Double ?? 0
        let outcome = last["outcome"] as? String ?? ""
        guard notifyEnabled, seconds >= 10, outcome == "completed" || outcome == "failed",
              Date().timeIntervalSince1970 - ended < 60, !ollamaVisible() else { return }
        post(outcome == "completed" ? "Ollama replied" : "Ollama stopped with an error",
             (outcome == "completed" ? "Ready after " : "After ") + clock(seconds), opensOllama: true)
    }

    /// A notification after ThatPet or Ollama were updated: whether the extension still works.
    func notifyIfUpdateChecked(_ health: [String: Any]?) {
        guard let check = health?["update_check"] as? [String: Any], let at = check["at"] as? Double else { return }
        let problems = check["problems"] as? [String] ?? []
        let waiting = check["waiting_reply"] as? Bool ?? false
        let state = "\(at)|\(problems.count)|\(waiting)"
        guard state != lastUpdateState else { return }
        let firstLook = lastUpdateState.isEmpty
        lastUpdateState = state
        guard !firstLook || Date().timeIntervalSince1970 - at < 120 else { return }  // not old checks at launch
        let apps = check["apps"] as? String ?? "An app"
        if !problems.isEmpty {
            post("\(apps): the extension needs attention", problems.joined(separator: " · "))
        } else if waiting {
            post("\(apps) updated", "Checks passed · confirming at the next Ollama reply")
        } else {
            post("\(apps) updated", "The extension still works with it")
        }
    }

    /// A system notification if macOS allows it, otherwise an AppleScript one.
    func post(_ title: String, _ body: String, opensOllama: Bool = false) {
        guard systemNotificationsAllowed else {
            // Text passed as arguments, never pasted into the script.
            run("/usr/bin/osascript", ["-e", "on run argv",
                                       "-e", "display notification (item 2 of argv) with title (item 1 of argv) sound name \"Glass\"",
                                       "-e", "end run", title, body + (opensOllama ? " · open Ollama to read it" : "")])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body + (opensOllama ? " · click to open Ollama" : "")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content,
                                                                     trigger: nil))
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

    // MARK: Updates of this app

    func automaticUpdateCheck() {
        Updater.shared.check { [weak self] release in
            guard let self = self, let release = release else { return }
            // Install by itself only when no reply is in progress (it restarts the app).
            if Updater.shared.automatic, readHealth()?["phase"] as? String == nil {
                self.install(release)
            } else {
                self.post("\(appName) \(release.version) is available", "Install it from the menu")
            }
        }
    }

    @objc func checkForUpdates() {
        Updater.shared.check { [weak self] release in
            guard let self = self else { return }
            if let release = release {
                self.post("Update \(release.version) available", "Install it from the extension's menu")
            } else if case .failed(let text) = Updater.shared.state {
                self.post("Couldn't check for updates", text)
            } else {
                self.post("\(appName) is up to date", "Version \(appVersion)")
            }
            self.refresh()
        }
    }

    @objc func installUpdate() {
        guard let release = Updater.shared.release else { return }
        install(release)
    }

    func install(_ release: Updater.Release) {
        DispatchQueue.global().async {
            let result = Updater.shared.install(release)
            DispatchQueue.main.async {
                switch result {
                case .success(let app):
                    self.quitting = true
                    self.stopBridge()
                    Updater.shared.relaunch(app)
                case .failure(let error):
                    self.post("The update to \(release.version) failed", error.text)
                }
            }
        }
    }

    func announceUpdateIfJustUpdated() {
        guard let previous = UserDefaults.standard.string(forKey: "UpdatedFromVersion") else { return }
        UserDefaults.standard.removeObject(forKey: "UpdatedFromVersion")
        if previous != appVersion { post("\(appName) updated to \(appVersion)", "It was \(previous)") }
    }

    // MARK: Actions

    @objc func switchToggled(_ sender: ColorSwitch) {
        let turnOn = sender.isOn
        enabled = turnOn
        busy = turnOn ? "Turning on…" : "Turning off…"
        refresh()
        DispatchQueue.main.async {
            if turnOn { self.startBridge() } else { self.stopBridge() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.busy = nil
                self.refresh()
            }
        }
    }

    /// Links the extension again with ThatPet's own command (an inert Hermes plugin).
    @objc func reconnect() {
        linked = Setup.linkThatPet()
        refresh()
    }

    @objc func toggleNotify() {
        notifyEnabled.toggle()
        if notifyEnabled { askNotificationPermission() }
        refresh()
    }

    @objc func toggleOpenAtLogin() {
        Setup.setOpenAtLogin(!Setup.openAtLogin)
        refresh()
    }

    @objc func toggleAutoUpdate() {
        Updater.shared.automatic.toggle()
        refresh()
    }

    @objc func chooseStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let style = IconStyle(rawValue: raw) {
            IconStyle.current = style
            refresh()
        }
    }

    @objc func openOllama() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ollamaID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc func showLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logFilePath)) }
    @objc func openProject() { NSWorkspace.shared.open(Updater.shared.projectPage) }

    /// Stops the extension until it is opened again (or the next login).
    @objc func quit() {
        quitting = true
        stopBridge()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate() {
        quitting = true
        stopBridge()
    }
}
