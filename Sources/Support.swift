// Shared constants and helpers.

import AppKit

let appName = "ThatPet Ollama Extension"
let home = FileManager.default.homeDirectoryForCurrentUser.path
let thatPetID = "com.thatlev.ThatPet"
let ollamaID = "com.electron.ollama"
let thatPetHelper = "/Applications/ThatPet.app/Contents/MacOS/ThatPet"
/// Lock file, health.json and versions.json.
let stateDirectory = home + "/Library/Application Support/ThatPet Ollama Extension"
let logFilePath = home + "/Library/Logs/ThatPet Ollama Extension.log"
let healthFilePath = stateDirectory + "/health.json"

/// Runs a program and waits for it (at most `timeout` seconds).
@discardableResult
func run(_ path: String, _ args: [String], input: Data? = nil, timeout: Double = 30)
    -> (status: Int32, output: String, error: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    let stdin = Pipe()
    process.standardInput = input == nil ? FileHandle.nullDevice : stdin
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do { try process.run() } catch { return (-1, "", "\(error)") }
    if let input = input {
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
    }
    // Read while it runs, so a full pipe can't block it.
    var outData = Data(), errData = Data()
    let readers = DispatchGroup()
    readers.enter()
    DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); readers.leave() }
    readers.enter()
    DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); readers.leave() }
    if finished.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        finished.wait()
        readers.wait()
        return (-2, "", "timed out after \(Int(timeout)) s")
    }
    readers.wait()
    return (process.terminationStatus,
            String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// 75 -> "1:15"
func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

/// "1.10.0" > "1.9.2"
func isNewer(_ version: String, than current: String) -> Bool {
    let a = version.split(separator: ".").map { Int($0) ?? 0 }
    let b = current.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
}

/// Log lines "[HH:mm:ss] message" to stdout (command line) or to the log file (app).
/// The file is opened for appending, so it can be cut back while it is in use.
final class Log {
    static let shared = Log()
    private let lock = NSLock()
    private var fd: Int32 = 1
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func useFile(_ path: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let opened = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        if opened >= 0 { fd = opened }
    }

    func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        line.utf8CString.withUnsafeBufferPointer { buffer in
            _ = Darwin.write(fd, buffer.baseAddress, buffer.count - 1)
        }
    }

    /// Past 1 MB, keep only the last 200 KB (from a whole line). Only for files opened for appending.
    func trim(limit: Int = 1_000_000, keep: Int = 200_000) {
        lock.lock()
        defer { lock.unlock() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) > limit,
              fcntl(fd, F_GETFL) & O_APPEND != 0 else { return }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0, let handle = FileHandle(forUpdatingAtPath: String(cString: buffer))
        else { return }
        defer { try? handle.close() }
        handle.seek(toFileOffset: UInt64(Int(info.st_size) - keep))
        var tail = handle.readDataToEndOfFile()
        if let newline = tail.firstIndex(of: 0x0A) { tail = tail.subdata(in: tail.index(after: newline)..<tail.endIndex) }
        handle.seek(toFileOffset: 0)
        handle.write(tail)
        handle.truncateFile(atOffset: UInt64(tail.count))
        let note = "[\(formatter.string(from: Date()))] Log trimmed to its last \(tail.count / 1000) KB\n"
        note.utf8CString.withUnsafeBufferPointer { _ = Darwin.write(fd, $0.baseAddress, $0.count - 1) }
    }
}

func log(_ message: String) { Log.shared.write(message) }
