// ThatPet Ollama Extension: makes ThatPet react to Ollama Desktop replies.
//
// Without arguments it runs as a menu bar app (the bridge runs inside it). Command line:
//   --bridge [options]      run only the bridge, logging to stdout (used by tests/simulate.py)
//   --update-now            check GitHub for a newer release and install it (no relaunch)
//   --preview FILE.png      draw an enlarged preview of the menu bar icon
//   --notification-check    print the notification permission and send a test notification
//   --unregister-login-item remove this copy from Open at Login
//   --version               print the version

import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())

/// Value after the last occurrence of a flag (a later flag overrides an earlier one).
func value(after flag: String) -> String? {
    guard let i = arguments.lastIndex(of: flag), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

switch arguments.first {
case "--version":
    print(appVersion)
    exit(0)

case "--preview":
    guard let path = value(after: "--preview") else { exit(1) }
    renderPreview(to: path)
    exit(0)

case "--notification-check":
    notificationCheck()
    exit(0)

case "--unregister-login-item":
    // Removes this copy from Open at Login (used when the app's bundle id changes).
    Setup.setOpenAtLogin(false)
    print("Open at login: \(Setup.openAtLogin ? "still on" : "off")")
    exit(0)

case "--update-now":
    let done = DispatchSemaphore(value: 0)
    var found: Updater.Release?
    DispatchQueue.global().async {
        Updater.shared.check { release in found = release; done.signal() }
    }
    // check() calls back on the main queue: keep it running while we wait.
    while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    guard let release = found else {
        print("No update: \(Updater.shared.state)")
        exit(Updater.shared.state == .upToDate ? 0 : 1)
    }
    switch Updater.shared.install(release) {
    case .success(let app): print("Installed \(release.version) at \(app.path)"); exit(0)
    case .failure(let error): print("Update refused: \(error.text)"); exit(3)
    }

case "--bridge":
    var config = BridgeConfig()
    config.database = value(after: "--db") ?? config.database
    config.appLog = value(after: "--log") ?? config.appLog
    config.pet = value(after: "--pet") ?? config.pet
    config.stateDir = value(after: "--state-dir") ?? config.stateDir
    config.thatPetApp = value(after: "--thatpet-app") ?? config.thatPetApp
    config.ollamaApp = value(after: "--ollama-app") ?? config.ollamaApp
    config.poll = value(after: "--poll").flatMap(Double.init) ?? config.poll
    config.idle = value(after: "--idle").flatMap(Double.init) ?? config.idle
    config.stall = value(after: "--stall").flatMap(Double.init) ?? config.stall
    config.heartbeat = value(after: "--heartbeat").flatMap(Double.init) ?? config.heartbeat
    config.updateCheck = value(after: "--update-check").flatMap(Double.init) ?? config.updateCheck
    config.waitForLock = arguments.contains("--wait-for-lock")
    let bridge = Bridge(config: config)
    // Ctrl+C / SIGTERM: stop cleanly (an open turn goes back to idle).
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { bridge.stop() }
        source.resume()
        sources.append(source)
    }
    exit(bridge.serve() ? 0 : 1)

default:
    break
}

// A single copy: if another one is already running, exit right away.
if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: Controller?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.shared.useFile(logFilePath)
        log("\(appName) \(appVersion) started")
        Setup.onLaunch()
        controller = Controller()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.applicationWillTerminate()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // no Dock icon
app.run()
