// Verify the signed feed and update artifact using the app's public trust anchor.
// No private key, Keychain access, app launch, or installed-app changes.
import CryptoKit
import Foundation

enum VerificationError: Error { case invalid }

func verify() throws {
    guard CommandLine.arguments.count == 5,
          let publicBytes = Data(base64Encoded: CommandLine.arguments[2]),
          let archiveSignature = Data(base64Encoded: CommandLine.arguments[4]) else {
        throw VerificationError.invalid
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let text = String(decoding: data, as: UTF8.self)
    let pattern = #"<!-- sparkle-signatures:\s*edSignature: ([A-Za-z0-9+/=]+)\s*length: ([0-9]+)\s*-->\s*$"#
    let regex = try NSRegularExpression(pattern: pattern)
    guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let signatureRange = Range(match.range(at: 1), in: text),
          let lengthRange = Range(match.range(at: 2), in: text),
          let blockRange = Range(match.range, in: text),
          let signature = Data(base64Encoded: String(text[signatureRange])),
          let length = Int(text[lengthRange]), length > 0, length <= data.count,
          text[..<blockRange.lowerBound].utf8.count == length else {
        throw VerificationError.invalid
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
    guard key.isValidSignature(signature, for: data.prefix(length)) else {
        throw VerificationError.invalid
    }
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
    guard key.isValidSignature(archiveSignature, for: archive) else {
        throw VerificationError.invalid
    }
    print("Feed and update signature match the app public key")
}

do {
    try verify()
} catch {
    FileHandle.standardError.write(Data("Sparkle feed or update signature verification failed\n".utf8))
    exit(1)
}
