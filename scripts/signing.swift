// Ed25519 keys for signing releases. The private key never leaves this Mac.
//
//   swift scripts/signing.swift keygen        create the key (once) and print the public key
//   swift scripts/signing.swift public        print the public key (goes in Resources/Info.plist)
//   swift scripts/signing.swift sign FILE     write FILE.sig (base64 signature of FILE)
//   swift scripts/signing.swift verify FILE   check FILE.sig against the public key in Info.plist

import CryptoKit
import Foundation

let keyFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/thatpet-ollama-extension/update-signing-key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func privateKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyFile, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("No signing key at \(keyFile.path): run `swift scripts/signing.swift keygen` first.") }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "keygen":
    if FileManager.default.fileExists(atPath: keyFile.path) {
        fail("A key already exists at \(keyFile.path); not replacing it (installed apps trust it).")
    }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(at: keyFile.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try key.rawRepresentation.base64EncodedString().write(to: keyFile, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "public":
    print(privateKey().publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard args.count == 2, let data = FileManager.default.contents(atPath: args[1]) else { fail("usage: sign FILE") }
    let signature = try privateKey().signature(for: data)
    try signature.base64EncodedString().write(toFile: args[1] + ".sig", atomically: true, encoding: .utf8)
    print("Signed: \(args[1]).sig")

case "verify":
    guard args.count == 2, let data = FileManager.default.contents(atPath: args[1]),
          let sigText = try? String(contentsOfFile: args[1] + ".sig", encoding: .utf8),
          let signature = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let info = NSDictionary(contentsOfFile: "Resources/Info.plist"),
          let publicText = info["UpdatePublicKey"] as? String, let publicRaw = Data(base64Encoded: publicText),
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicRaw)
    else { fail("usage: verify FILE (run from the project folder)") }
    if publicKey.isValidSignature(signature, for: data) { print("Signature OK") } else { fail("Signature does NOT match") }

default:
    fail("usage: swift scripts/signing.swift keygen | public | sign FILE | verify FILE")
}
