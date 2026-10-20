// The bridge: watches Ollama Desktop (read-only) and drives ThatPet through its official
// hook helper. Same behavior as the original Python bridge, checked by tests/simulate.py.
//
// - Turn start: a new row with a recent created_at in Ollama's `messages` table. Ollama
//   rewrites whole chats with new ids but the original dates: those rows are ignored.
// - Turn end: the `POST /api/v1/chat/{id}` line Ollama writes to ~/.ollama/logs/app.log when
//   a reply stream finishes; a `chat stream error` line right before it means stopped/failed.
// - Tools: a `tool_calls` row, then a `tool` message with the result; the pet works
//   ("Browsing the web…" for web tools) until the model writes again.
// - ThatPet drops a state after 60 s without events, so the current one is repeated (heartbeat).
// - Events: SessionStart -> idle, UserPromptSubmit -> thinking, PreToolUse -> working,
//   Stop -> celebrating, StopFailure -> error. SessionEnd is NEVER sent: it makes ThatPet quit.
// Conversation text is never read, stored or printed.

import Foundation
import SQLite3

struct BridgeConfig {
    var database = home + "/Library/Application Support/Ollama/db.sqlite"
    var appLog = home + "/.ollama/logs/app.log"
    var pet = thatPetHelper
    var thatPetApp = "/Applications/ThatPet.app"
    var ollamaApp = "/Applications/Ollama.app"
    var stateDir = stateDirectory
    var poll = 0.5
    var idle = 6.0          // only without app.log: seconds without new text before Stop
    var stall = 900.0       // seconds without any signal before going back to idle
    var heartbeat = 20.0
    var updateCheck = 60.0
    var waitForLock = false
}

/// ThatPet session id: fixed, so ThatPet doesn't pile up one session file per start.
private let sessionID = "ollama-desktop"
/// A row is a new message only if created less than this many seconds ago.
private let recent = 120.0
/// Outcome -> (ThatPet event, description for the log)
private let outcomes: [String: (event: String, text: String)] = [
    "completed": ("Stop", "reply completed"),
    "canceled": ("SessionStart", "stopped by the user"),  // like ThatPet's Hermes plugin: back to idle
    "failed": ("StopFailure", "Ollama error"),
    "presumed": ("Stop", "no new text"),                   // only without app.log
    "stalled": ("SessionStart", "no end signal"),
    "stopped": ("SessionStart", "bridge stopped"),
]

/// created_at ("2026-10-19 22:55:06.657+02:00", or UTC without offset) -> epoch seconds.
func parseTime(_ text: String?) -> Double? {
    guard let text = text else { return nil }
    let pattern = #"^(\d{4})-(\d\d)-(\d\d)[ T](\d\d):(\d\d):(\d\d)(?:\.(\d+))?\s*(Z|[+-]\d\d:?\d\d)?"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    func group(_ i: Int) -> String? { Range(m.range(at: i), in: text).map { String(text[$0]) } }
    var parts = DateComponents()
    parts.calendar = Calendar(identifier: .gregorian)
    parts.timeZone = TimeZone(secondsFromGMT: 0)
    parts.year = Int(group(1)!); parts.month = Int(group(2)!); parts.day = Int(group(3)!)
    parts.hour = Int(group(4)!); parts.minute = Int(group(5)!); parts.second = Int(group(6)!)
    guard var seconds = parts.date?.timeIntervalSince1970 else { return nil }
    if let fraction = group(7) {
        seconds += Double("0." + fraction.prefix(6)) ?? 0
    }
    if let zone = group(8), zone != "Z" {
        let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
        let offset = Double(Int(digits.prefix(2))! * 3600 + Int(digits.suffix(2))! * 60)
        seconds -= zone.hasPrefix("+") ? offset : -offset
    }
    return seconds
}

/// What the menu shows while a tool runs (ThatPet maps the same web tool names to its bubble).
func toolLabel(_ name: String?) -> String {
    let lower = (name ?? "").lowercased()
    let web = ["websearch", "webfetch", "web_search", "web_fetch", "web_extract", "search_web", "read_url_content"]
    if lower.hasPrefix("browser_") || web.contains(lower) { return "Browsing the web" }
    return "Using \(name ?? "a tool")"
}

/// Version of an installed app (CFBundleShortVersionString), or nil.
func installedVersion(_ app: String) -> String? {
    guard let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist") else { return nil }
    return (info["CFBundleShortVersionString"] ?? info["CFBundleVersion"]) as? String
}

// MARK: - ThatPet

final class Pet {
    let helper: String
    private(set) var pid: Int32?
    var sessionPID: Int32?
    private var nextCheck = 0.0

    init(helper: String) {
        self.helper = helper
        pid = Pet.runningPID()
    }

    /// PID of the ThatPet app from its run/pet.pid, or nil (diagnostics only).
    static func runningPID() -> Int32? {
        guard let text = try? String(contentsOfFile: home + "/Library/Application Support/ThatPet/run/pet.pid"),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0
        else { return nil }
        return pid
    }

    func watch(_ now: Double) {
        guard now >= nextCheck else { return }
        nextCheck = now + 2
        let current = Pet.runningPID()
        if current != pid {
            log(current == nil ? "WARNING: ThatPet disappeared/quit!" : "ThatPet running (pid \(current!))")
            pid = current
        }
    }

    @discardableResult
    func emit(_ event: String, tool: String? = nil, quiet: Bool = false) -> Bool {
        var payload: [String: String] = ["hook_event_name": event, "session_id": sessionID]
        if let tool = tool { payload["tool_name"] = String(tool.prefix(64)) }
        let data = try? JSONSerialization.data(withJSONObject: payload)
        let result = run(helper, ["hook", "--provider", "hermes"], input: data ?? Data(), timeout: 5)
        if result.status != 0 {
            log("ERROR hook \(event): exit code \(result.status); \(result.error.prefix(200))")
            return false
        }
        if !quiet {
            log("Hook sent: \(event)" + (pid == nil ? " (ThatPet does not seem to be open)" : ""))
        }
        return true
    }

    /// ThatPet 0.4+ ignores agents that are not connected; the bridge reports as Hermes.
    func linkStatus() -> String? {
        let out = run(helper, ["agents"], timeout: 10).output
        guard let line = out.split(separator: "\n").first(where: { $0.hasPrefix("Hermes Agent:") }) else { return nil }
        return line.dropFirst("Hermes Agent:".count).trimmingCharacters(in: .whitespaces)
    }

    func prompt() {
        // One session per ThatPet process: a reopened ThatPet gets SessionStart again.
        let current = Pet.runningPID()
        if current == nil || current != sessionPID {
            emit("SessionStart")
            sessionPID = current
        }
        emit("UserPromptSubmit")
    }
}

// MARK: - Ollama's database (read-only)

struct SQLiteError: Error, CustomStringConvertible {
    let description: String
}

final class OllamaDB {
    let path: String
    private var conn: OpaquePointer?
    private var stamp: [String] = []

    init(path: String) { self.path = path }

    deinit { close() }

    /// True when the database or its WAL changed since the last call (stat is cheap).
    func changed() -> Bool {
        let now = [path, path + "-wal"].map { file -> String in
            guard let a = try? FileManager.default.attributesOfItem(atPath: file) else { return "-" }
            let date = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(date)/\(a[.size] ?? 0)"
        }
        if now == stamp { return false }
        stamp = now
        return true
    }

    func close() {
        if conn != nil { sqlite3_close(conn) }
        conn = nil
    }

    func query(_ sql: String, _ params: [Any] = []) throws -> [[Any?]] {
        if conn == nil {
            // Read-only, but not immutable: it must see Ollama's WAL updates.
            let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
            if sqlite3_open_v2(uri, &conn, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) != SQLITE_OK {
                let message = conn.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
                close()
                stamp = []
                throw SQLiteError(description: message)
            }
            sqlite3_busy_timeout(conn, 1000)
            sqlite3_exec(conn, "PRAGMA query_only = ON", nil, nil, nil)
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(conn))
            close()
            stamp = []  // try again on the next round
            throw SQLiteError(description: message)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in params.enumerated() {
            if let number = value as? Int64 { sqlite3_bind_int64(statement, Int32(i + 1), number) }
            else if let number = value as? Int { sqlite3_bind_int64(statement, Int32(i + 1), Int64(number)) }
            else { sqlite3_bind_text(statement, Int32(i + 1), "\(value)", -1, transient) }
        }
        var rows: [[Any?]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                let message = String(cString: sqlite3_errmsg(conn))
                close()
                stamp = []
                throw SQLiteError(description: message)
            }
            rows.append((0..<sqlite3_column_count(statement)).map { column -> Any? in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: return sqlite3_column_int64(statement, column)
                case SQLITE_FLOAT: return sqlite3_column_double(statement, column)
                case SQLITE_TEXT: return String(cString: sqlite3_column_text(statement, column))
                default: return nil
                }
            })
        }
        return rows
    }

    func maxID() throws -> Int64 {
        try query("SELECT coalesce(max(id), 0) FROM messages").first?.first as? Int64 ?? 0
    }

    /// (id, chat_id, role, created_at) of the rows after `lastID`.
    func rows(after lastID: Int64) throws -> [(id: Int64, chat: String, role: String, created: String?)] {
        try query("SELECT id, chat_id, role, created_at FROM messages WHERE id > ? ORDER BY id", [lastID]).map {
            ($0[0] as? Int64 ?? 0, $0[1] as? String ?? "", $0[2] as? String ?? "", $0[3] as? String)
        }
    }

    /// Highest tool_calls id, or nil if this Ollama has no such table.
    func maxToolCallID() -> Int64? {
        (try? query("SELECT coalesce(max(id), 0) FROM tool_calls"))?.first?.first as? Int64
    }

    /// (id, function name, chat_id, message created_at) of the tool calls after `lastID`.
    func toolCalls(after lastID: Int64) throws -> [(id: Int64, name: String?, chat: String, created: String?)] {
        try query("SELECT tc.id, tc.function_name, m.chat_id, m.created_at FROM tool_calls tc "
                  + "JOIN messages m ON m.id = tc.message_id WHERE tc.id > ? ORDER BY tc.id", [lastID]).map {
            ($0[0] as? Int64 ?? 0, $0[1] as? String, $0[2] as? String ?? "", $0[3] as? String)
        }
    }

    /// (created_at, text length) of the chat's latest assistant message.
    func latestReply(chat: String) throws -> (created: Double, size: Int64)? {
        let rows = try query("SELECT created_at, length(coalesce(content,'')) + length(coalesce(thinking,'')) "
                             + "FROM messages WHERE role = 'assistant' AND chat_id = ? ORDER BY id DESC LIMIT 1", [chat])
        guard let row = rows.first, let created = parseTime(row[0] as? String) else { return nil }
        return (created, row[1] as? Int64 ?? 0)
    }

    /// Columns the bridge reads that are missing (after an Ollama update).
    func schemaProblems() throws -> [String] {
        let needed: [(String, [String])] = [("messages", ["chat_id", "content", "created_at", "id", "role", "thinking"]),
                                            ("tool_calls", ["function_name", "id", "message_id"])]
        var missing: [String] = []
        for (table, columns) in needed {
            let have = Set(try query("PRAGMA table_info(\(table))").compactMap { $0[1] as? String })
            missing += columns.filter { !have.contains($0) }.map { "\(table).\($0)" }
        }
        return missing
    }
}

// MARK: - app.log

/// Reads only the new lines of app.log; handles rotation and truncation.
final class LogFollower {
    let path: String
    private var inode: UInt64?
    private var position: UInt64 = 0
    private var partial = Data()

    init(path: String) {
        self.path = path
        if let a = try? FileManager.default.attributesOfItem(atPath: path) {
            inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value
            position = (a[.size] as? NSNumber)?.uint64Value ?? 0  // skip the history
        }
    }

    var available: Bool { inode != nil }

    func newLines() -> [String] {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else {
            inode = nil
            return []
        }
        let currentInode = (a[.systemFileNumber] as? NSNumber)?.uint64Value
        let size = (a[.size] as? NSNumber)?.uint64Value ?? 0
        if currentInode != inode || size < position {
            // Ollama restarted (log rotated) or the file was truncated: read from the start.
            inode = currentInode
            position = 0
            partial = Data()
        }
        guard size > position, let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        handle.seek(toFileOffset: position)
        let data = handle.readData(ofLength: Int(size - position))
        position += UInt64(data.count)
        var lines = (partial + data).split(separator: 0x0A, omittingEmptySubsequences: false)
        partial = Data(lines.removeLast())
        return lines.map { String(decoding: $0, as: UTF8.self) }
    }
}

// MARK: - health.json (read by the menu)

final class Health {
    let path: String
    private(set) var data: [String: Any] = [:]

    init(path: String) { self.path = path }

    func update(_ changes: [String: Any?]) {
        var next = data
        for (key, value) in changes { next[key] = value ?? NSNull() }
        guard !(next as NSDictionary).isEqual(to: data) else { return }
        data = next
        guard let json = try? JSONSerialization.data(withJSONObject: next) else { return }
        try? json.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func int(_ key: String) -> Int { (data[key] as? Int) ?? 0 }
}

// MARK: - The bridge

final class Turn {
    let chat: String
    let since: Double       // created_at of the prompt (epoch)
    let started: Double     // monotonic
    var activity: Double
    var reply: Int64 = 0
    var replyAt: Double
    var tool: String?
    var toolResultAt: Double?
    var seen = Set<String>()
    var phase: (event: String, tool: String?) = ("UserPromptSubmit", nil)
    var lastEmit: Double
    var label: String?

    init(chat: String, since: Double, now: Double) {
        self.chat = chat
        self.since = since
        started = now
        activity = now
        replyAt = now
        lastEmit = now
    }
}

func monotonic() -> Double { ProcessInfo.processInfo.systemUptime }

final class Bridge {
    let config: BridgeConfig
    private let stopLock = NSLock()
    private var stopRequested = false

    init(config: BridgeConfig = BridgeConfig()) { self.config = config }

    func stop() {
        stopLock.lock()
        stopRequested = true
        stopLock.unlock()
    }

    private var shouldStop: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopRequested
    }

    private static func isFresh(_ created: String?, since: Double) -> Bool {
        guard let ts = parseTime(created) else { return false }
        return ts >= since - 1
    }

    /// Only one bridge at a time. Returns the lock's file descriptor, or nil if another one holds it.
    private func acquireLock() -> Int32? {
        try? FileManager.default.createDirectory(atPath: config.stateDir, withIntermediateDirectories: true)
        let path = config.stateDir + "/bridge.lock"
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if !config.waitForLock {
                let other = (try? String(contentsOfFile: path))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
                log("Another bridge is already running (pid \(other.isEmpty ? "?" : other)): turn it off first, "
                    + "otherwise ThatPet gets every event twice.")
                Darwin.close(fd)
                return nil
            }
            log("Another bridge is running: waiting until it stops")
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                if shouldStop { Darwin.close(fd); return nil }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        ftruncate(fd, 0)
        let pid = "\(getpid())"
        pid.utf8CString.withUnsafeBufferPointer { _ = pwrite(fd, $0.baseAddress, $0.count - 1, 0) }
        return fd
    }

    /// Runs until stop(). Returns false if it could not start.
    @discardableResult
    func serve() -> Bool {
        let pet = Pet(helper: config.pet)
        guard FileManager.default.fileExists(atPath: config.pet) else {
            log("ThatPet app not found: \(config.pet)")
            return false
        }
        guard FileManager.default.fileExists(atPath: config.database) else {
            log("Ollama database not found: \(config.database)")
            return false
        }
        Log.shared.trim()
        guard let lockFD = acquireLock() else { return false }
        defer { Darwin.close(lockFD) }

        let db = OllamaDB(path: config.database)
        let appLog = LogFollower(path: config.appLog)
        var lastID: Int64
        var lastCallID: Int64?
        do {
            lastID = try db.maxID()
            lastCallID = db.maxToolCallID()
        } catch {
            log("Cannot open the database: \(error)")
            return false
        }
        _ = db.changed()  // remember the current state of the files
        let health = Health(path: config.stateDir + "/health.json")
        health.update(["pid": Int(getpid()), "stalled_turns": 0, "read_problem": nil,
                       "phase": nil, "phase_since": nil, "turn_since": nil])
        let versionsFile = config.stateDir + "/versions.json"

        var turn: Turn?
        var streamError: (outcome: String, at: Double)?
        var previousProblem: String?
        var nextTrim = monotonic() + 600
        var nextUpdateCheck = monotonic()  // right away: updates made while it was off

        func setPhase(_ label: String) {
            guard let t = turn, t.label != label else { return }
            t.label = label
            health.update(["phase": label, "phase_since": Date().timeIntervalSince1970])
        }

        func endTurn(_ outcome: String) {
            guard let t = turn else { return }
            let entry = outcomes[outcome]!
            let seconds = monotonic() - t.started
            log("Turn ended: \(entry.text) after \(String(format: "%.1f", seconds)) s")
            pet.emit(entry.event)
            turn = nil
            health.update(["phase": nil, "phase_since": nil, "turn_since": nil,
                           "last_turn": ["outcome": outcome, "seconds": Int(seconds.rounded()),
                                         "ended": Date().timeIntervalSince1970]])
            if outcome == "stalled" && appLog.available {
                // app.log is there but its end line never came: Ollama may have changed.
                health.update(["stalled_turns": health.int("stalled_turns") + 1])
            } else if ["completed", "canceled", "failed"].contains(outcome) {
                health.update(["stalled_turns": 0])
            }
            // After an Ollama update, the first reply tells whether its end is still detected.
            if var check = health.data["update_check"] as? [String: Any], check["waiting_reply"] as? Bool == true,
               ["completed", "canceled", "failed", "stalled"].contains(outcome) {
                let missed = outcome == "stalled" && appLog.available
                check["waiting_reply"] = false
                if missed { check["problems"] = (check["problems"] as? [String] ?? []) + ["Reply end not detected"] }
                health.update(["update_check": check])
                log("Update check: " + (missed ? "reply end NOT detected" : "reply end detected, all good"))
            }
        }

        func followTools(rows: [(id: Int64, chat: String, role: String, created: String?)],
                         calls: [(id: Int64, name: String?, chat: String, created: String?)],
                         latest: (created: Double, size: Int64)?) {
            guard let t = turn else { return }
            for call in calls {
                let key = "call|\(call.created ?? "")|\(call.name ?? "")"  // Ollama rewrites tool_calls with new ids
                guard call.chat == t.chat, Bridge.isFresh(call.created, since: t.since), !t.seen.contains(key)
                else { continue }
                t.seen.insert(key)
                if t.tool == nil {
                    t.tool = call.name ?? "tool"
                    log("Tool call: \(t.tool!)")
                    pet.emit("PreToolUse", tool: t.tool)
                    t.phase = ("PreToolUse", t.tool)
                    t.lastEmit = monotonic()
                    setPhase(toolLabel(t.tool))
                }
            }
            for row in rows {
                let key = "result|\(row.created ?? "")"
                guard row.role == "tool", row.chat == t.chat, Bridge.isFresh(row.created, since: t.since),
                      !t.seen.contains(key) else { continue }
                t.seen.insert(key)
                if t.tool != nil {
                    t.toolResultAt = parseTime(row.created)
                    log("Tool finished: \(t.tool!) (the model is reading the result)")
                }
            }
            // A reply created after the result, with text in it: the model is writing again.
            if t.tool != nil, let resultAt = t.toolResultAt, let latest = latest, latest.created > resultAt,
               latest.size > 0 {
                log("Model is writing the answer")
                pet.emit("PostToolUse")
                pet.emit("UserPromptSubmit")
                t.tool = nil
                t.toolResultAt = nil
                t.phase = ("UserPromptSubmit", nil)
                t.lastEmit = monotonic()
                setPhase("Writing the answer")
            }
        }

        func checkUpdates() throws {
            let current = ["ThatPet": installedVersion(config.thatPetApp), "Ollama": installedVersion(config.ollamaApp)]
            let currentJSON = current.mapValues { $0 ?? "" }
            let seen = (try? Data(contentsOf: URL(fileURLWithPath: versionsFile)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            if seen == currentJSON { return }
            if let json = try? JSONSerialization.data(withJSONObject: currentJSON) {
                try? json.write(to: URL(fileURLWithPath: versionsFile), options: .atomic)
            }
            guard let seen = seen else { return }  // first run: only remember the versions
            let changed = ["ThatPet", "Ollama"].filter { (seen[$0] ?? "") != currentJSON[$0] }
            var problems: [String] = [], notes: [String] = [], waiting = false
            for app in changed {
                log("\(app) updated: \(seen[app] ?? "?") -> \(current[app]! ?? "removed"); checking the extension")
                if current[app]! == nil { problems.append("\(app) not found") }
            }
            if changed.contains("ThatPet"), current["ThatPet"]! != nil {
                var link = pet.linkStatus()
                if link == nil {
                    problems.append("ThatPet's helper does not answer")
                } else {
                    if ["notInstalled", "disconnected"].contains(link!) {
                        // The update dropped the link: restore it with ThatPet's own command.
                        run(config.pet, ["connect", "hermes"], timeout: 30)
                        link = pet.linkStatus()
                        if link == nil || ["notInstalled", "disconnected"].contains(link!) {
                            problems.append("ThatPet ignores the extension")
                        } else {
                            notes.append("link to ThatPet restored")
                        }
                    }
                    if turn == nil && !pet.emit("SessionStart", quiet: true) {
                        problems.append("ThatPet's helper rejected an event")
                    }
                }
            }
            if changed.contains("Ollama"), current["Ollama"]! != nil {
                let missing = try db.schemaProblems()
                if missing.contains(where: { $0.hasPrefix("messages.") }) {
                    problems.append("Ollama's database changed")
                } else if !missing.isEmpty {
                    notes.append("tool animations unavailable")
                }
                if !appLog.available { problems.append("Ollama's app.log is missing") }
                waiting = problems.isEmpty  // confirmed when the next reply ends
            }
            problems.forEach { log("WARNING after the update: \($0)") }
            notes.forEach { log("After the update: \($0)") }
            log("Update check: " + (!problems.isEmpty ? "problems found" : waiting ? "waiting for the next Ollama reply" : "all good"))
            let apps = changed.compactMap { app in current[app]!.map { "\(app) \($0)" } }.joined(separator: ", ")
            health.update(["update_check": ["at": Date().timeIntervalSince1970, "apps": apps, "problems": problems,
                                            "notes": notes, "waiting_reply": waiting]])
        }

        log("Bridge started (\(appName) \(appVersion)).")
        log("Reply end detected from " + (appLog.available ? config.appLog
                                           : "a \(Int(config.idle)) s timeout (app.log not found)"))
        log("SessionEnd is never sent.")
        log(pet.pid.map { "ThatPet running (pid \($0))" } ?? "WARNING: ThatPet does not seem to be open. Open it before chatting.")
        if let link = pet.linkStatus() {
            if ["notInstalled", "disconnected"].contains(link) {
                log("WARNING: ThatPet lists the Hermes agent as \(link): ThatPet 0.4+ ignores the extension until it is linked (Reconnect in the menu)")
            } else {
                log("ThatPet link: Hermes agent \(link) (events accepted)")
            }
        }

        while !shouldStop {
            let now = monotonic()
            pet.watch(now)
            health.update(["end_detection": appLog.available ? "app.log" : "timeout"])
            if now >= nextTrim {
                Log.shared.trim()
                nextTrim = now + 600
            }
            if now >= nextUpdateCheck {
                nextUpdateCheck = now + config.updateCheck
                do { try checkUpdates() } catch { log("Update check failed: \(error)") }
            }

            do {
                // 1) Database: a freshly created message with no active turn = turn start.
                if db.changed() {
                    let rows = try db.rows(after: lastID)
                    if let last = rows.last { lastID = last.id }
                    var calls: [(id: Int64, name: String?, chat: String, created: String?)] = []
                    if let callID = lastCallID {
                        calls = try db.toolCalls(after: callID)
                        if let last = calls.last { lastCallID = last.id }
                    }
                    if let t = turn {
                        t.activity = now
                    } else {
                        let wall = Date().timeIntervalSince1970
                        var fresh: [(row: (id: Int64, chat: String, role: String, created: String?), ts: Double)] = []
                        var stale = 0
                        for row in rows {
                            guard let ts = parseTime(row.created), abs(wall - ts) < recent else { stale += 1; continue }
                            if row.role == "user" || row.role == "assistant" { fresh.append((row, ts)) }
                        }
                        if stale > 0 { log("Ignored \(stale) rows with old dates (chat rewritten by Ollama)") }
                        // Prefer the user's prompt; otherwise it is a regeneration.
                        if let pick = fresh.last(where: { $0.row.role == "user" }) ?? fresh.last {
                            turn = Turn(chat: pick.row.chat, since: pick.ts, now: now)
                            let kind = pick.row.role == "user" ? "prompt" : "'assistant' message (regeneration?)"
                            log("New \(kind) in chat \(pick.row.chat.prefix(8))")
                            pet.prompt()
                            health.update(["turn_since": Date().timeIntervalSince1970])
                            setPhase("Thinking")
                        }
                    }
                    if let t = turn {
                        let latest = try db.latestReply(chat: t.chat)
                        followTools(rows: rows, calls: calls, latest: latest)
                        let size = latest.flatMap { $0.created >= t.since - 1 ? $0.size : nil } ?? 0
                        if size > 0 && size != t.reply {
                            if t.reply == 0 {
                                log("Model is generating (first text after \(String(format: "%.1f", now - t.started)) s)")
                                if t.tool == nil { setPhase("Writing the answer") }
                            }
                            t.reply = size
                            t.replyAt = now
                        }
                    }
                }

                // 2) app.log: end of the stream (completed, stopped or failed).
                for line in appLog.newLines() {
                    if line.contains("msg=\"chat stream error\"") {
                        streamError = (line.contains("context canceled") ? "canceled" : "failed", now)
                        continue
                    }
                    guard let status = Bridge.streamEndStatus(line) else { continue }
                    var outcome = status < 400 ? "completed" : "failed"
                    if let error = streamError, now - error.at < 5 { outcome = error.outcome }
                    streamError = nil
                    if turn != nil {
                        endTurn(outcome)
                    } else {
                        log("Stream ended with no active turn (\(outcome)): ignored")
                    }
                }
                previousProblem = nil
                health.update(["read_problem": nil])
            } catch {
                let text = "\(error)"
                if text != previousProblem {
                    log("Read problem: \(text); retrying")
                    previousProblem = text
                    health.update(["read_problem": String(text.prefix(200))])
                }
            }

            // 3) Safety nets.
            if let t = turn {
                if !appLog.available && t.reply > 0 && now - t.replyAt >= config.idle {
                    endTurn("presumed")
                } else if now - t.activity >= config.stall {
                    endTurn("stalled")
                }
            }

            // 4) Heartbeat: keep the pet thinking/working through long phases.
            if let t = turn, now - t.lastEmit >= config.heartbeat {
                pet.emit(t.phase.event, tool: t.phase.tool, quiet: true)
                t.lastEmit = now
            }

            Thread.sleep(forTimeInterval: config.poll)
        }
        if turn != nil { endTurn("stopped") }
        db.close()
        log("Bridge stopped (SessionEnd not sent)")
        return true
    }

    /// HTTP status of the app.log line written when a chat stream ends, else nil.
    static func streamEndStatus(_ line: String) -> Int? {
        guard let range = line.range(of: #"http\.pattern="POST /api/v1/chat/\{id\}"\s+http\.status=(\d+)"#,
                                     options: .regularExpression) else { return nil }
        return Int(line[range].split(separator: "=").last ?? "")
    }
}
