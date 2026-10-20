// Self-update from this project's GitHub releases.
//
// Each release carries the zipped app and a .sig file: an Ed25519 signature of the zip, made
// with the maintainer's private key (kept on their Mac, never on GitHub). The app installs a
// zip only if the signature matches the public key built into it, the bundle id is the same,
// the version is the announced one and the code signature is intact.

import AppKit
import CryptoKit

final class Updater {
    struct Release {
        let version: String
        let zip: URL
        let signature: URL
        let page: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate, installing
        case available(String)
        case failed(String)
    }

    static let shared = Updater()

    /// "owner/repo" from Info.plist (UpdateRepository).
    let repository = Bundle.main.object(forInfoDictionaryKey: "UpdateRepository") as? String ?? ""
    private let publicKey: Curve25519.Signing.PublicKey? = {
        guard let base64 = Bundle.main.object(forInfoDictionaryKey: "UpdatePublicKey") as? String,
              let raw = Data(base64Encoded: base64) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }()
    private(set) var state: State = .idle { didSet { DispatchQueue.main.async { self.onChange?() } } }
    private(set) var release: Release?
    var onChange: (() -> Void)?

    var projectPage: URL { URL(string: "https://github.com/\(repository)")! }

    /// Latest release feed; TPOE_UPDATE_FEED overrides it in tests (a signature is still required).
    private var feed: URL? {
        if let override = ProcessInfo.processInfo.environment["TPOE_UPDATE_FEED"] { return URL(string: override) }
        return repository.isEmpty ? nil : URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    }

    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "InstallUpdatesAutomatically") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "InstallUpdatesAutomatically") }
    }

    /// Looks for a newer release. Calls back on the main queue.
    func check(completion: ((Release?) -> Void)? = nil) {
        guard let feed = feed else {
            state = .failed("no update source")
            completion?(nil)
            return
        }
        state = .checking
        var request = URLRequest(url: feed, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let found = self.parse(data: data, response: response, error: error)
            DispatchQueue.main.async { completion?(found) }
        }.resume()
    }

    private func parse(data: Data?, response: URLResponse?, error: Error?) -> Release? {
        guard error == nil, let data = data, (response as? HTTPURLResponse)?.statusCode ?? 200 == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            state = .failed(error?.localizedDescription ?? "no release found")
            return nil
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isNewer(version, than: appVersion) else {
            release = nil
            state = .upToDate
            return nil
        }
        let assets = json["assets"] as? [[String: Any]] ?? []
        func asset(_ suffix: String) -> URL? {
            assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
                .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
        }
        guard let zip = asset(".zip"), let signature = asset(".zip.sig") else {
            state = .failed("release \(version) has no signed zip")
            return nil
        }
        let found = Release(version: version, zip: zip, signature: signature,
                            page: URL(string: json["html_url"] as? String ?? "") ?? projectPage)
        release = found
        state = .available(version)
        return found
    }

    /// Downloads, verifies and swaps in the new app. Returns the new app's location or an error text.
    func install(_ release: Release) -> Result<URL, UpdateError> {
        state = .installing
        let result = installSync(release)
        if case .failure(let error) = result {
            state = .failed(error.text)
            log("Update to \(release.version) failed: \(error.text)")
        } else {
            log("Updated to \(release.version)")
        }
        return result
    }

    struct UpdateError: Error {
        let text: String
    }

    private func installSync(_ release: Release) -> Result<URL, UpdateError> {
        guard let key = publicKey else { return .failure(UpdateError(text: "no public key in this build")) }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("tpoe-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            guard let zipData = try? Data(contentsOf: release.zip),
                  let signatureText = try? String(contentsOf: release.signature, encoding: .utf8),
                  let signature = Data(base64Encoded: signatureText.trimmingCharacters(in: .whitespacesAndNewlines))
            else { return .failure(UpdateError(text: "download failed")) }
            guard key.isValidSignature(signature, for: zipData) else {
                return .failure(UpdateError(text: "the signature does not match: update refused"))
            }
            let zip = work.appendingPathComponent("update.zip")
            try zipData.write(to: zip)
            let unpacked = work.appendingPathComponent("unpacked")
            guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], timeout: 120).status == 0 else {
                return .failure(UpdateError(text: "could not unpack the update"))
            }
            let current = Bundle.main.bundleURL
            let newApp = unpacked.appendingPathComponent(current.lastPathComponent)
            let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  info?["CFBundleShortVersionString"] as? String == release.version else {
                return .failure(UpdateError(text: "the update is not this app or not version \(release.version)"))
            }
            guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path], timeout: 60).status == 0 else {
                return .failure(UpdateError(text: "the update's code signature is broken"))
            }
            run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
            guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
                return .failure(UpdateError(text: "can't write to \(current.deletingLastPathComponent().path)"))
            }
            _ = try FileManager.default.replaceItemAt(current, withItemAt: newApp)
            return .success(current)
        } catch {
            return .failure(UpdateError(text: error.localizedDescription))
        }
    }

    /// Opens the (new) app again once this one has quit.
    func relaunch(_ app: URL) {
        UserDefaults.standard.set(appVersion, forKey: "UpdatedFromVersion")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
