// First-run and every-launch setup: open at login, the link with ThatPet, and the move away
// from the earlier version (Python bridge and icon started by two LaunchAgents).

import AppKit
import ServiceManagement

enum Setup {
    private static let oldLabels = ["local.ollama-thatpet-bridge", "local.ollama-thatpet-bridge.menu"]
    private static let oldInstall = home + "/Library/Application Support/OllamaThatPetBridge"

    static func onLaunch() {
        migrateFromLaunchAgents()
        if !UserDefaults.standard.bool(forKey: "LoginItemConfigured") {
            // First launch: open at login. macOS lists it once, under the app's own name.
            setOpenAtLogin(true)
            UserDefaults.standard.set(true, forKey: "LoginItemConfigured")
        }
        DispatchQueue.global().async { _ = linkThatPet() }
    }

    /// The earlier version ran as two LaunchAgents (each reinstall made macOS announce
    /// "background items" again). Stop and remove them; the app replaces both.
    static func migrateFromLaunchAgents() {
        var found = false
        for label in oldLabels {
            let plist = home + "/Library/LaunchAgents/\(label).plist"
            guard FileManager.default.fileExists(atPath: plist) else { continue }
            found = true
            run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeout: 15)
            try? FileManager.default.removeItem(atPath: plist)
        }
        if FileManager.default.fileExists(atPath: oldInstall) {
            found = true
            try? FileManager.default.removeItem(atPath: oldInstall)
        }
        if found { log("Moved from the earlier LaunchAgent setup: its bridge, icon and copies were removed") }
    }

    static var openAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    static func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log("Open at login could not be \(on ? "enabled" : "disabled"): \(error.localizedDescription)")
        }
    }

    /// ThatPet 0.4+ ignores agents that are not connected; the extension reports to it as the
    /// Hermes agent. Links it with ThatPet's own command (an inert plugin in ~/.hermes/plugins).
    /// Returns false if ThatPet still lists Hermes as not installed or disconnected.
    @discardableResult
    static func linkThatPet() -> Bool {
        guard FileManager.default.fileExists(atPath: thatPetHelper) else { return false }
        let pet = Pet(helper: thatPetHelper)
        guard let status = pet.linkStatus() else { return true }
        if !["notInstalled", "disconnected"].contains(status) { return true }
        run(thatPetHelper, ["connect", "hermes"], timeout: 30)
        let linked = !["notInstalled", "disconnected"].contains(pet.linkStatus() ?? "")
        log(linked ? "Linked with ThatPet (Hermes agent)" : "WARNING: could not link with ThatPet")
        return linked
    }

    static var thatPetLinked: Bool {
        guard FileManager.default.fileExists(atPath: thatPetHelper),
              let status = Pet(helper: thatPetHelper).linkStatus() else { return true }
        return !["notInstalled", "disconnected"].contains(status)
    }
}
