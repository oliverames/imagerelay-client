import Foundation
import Testing
@testable import ImageRelayKit

@Suite("FileFingerprinting")
struct FileFingerprintTests {
    @Test("Fingerprint streams file size and SHA-256")
    func fingerprintStreamsFileSizeAndHash() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("Image Relay".utf8).write(to: url)
        let fingerprint = try FileFingerprinting.fingerprint(of: url, chunkSize: 4)

        #expect(fingerprint.size == 11)
        #expect(fingerprint.sha256 == "fc3400b3fbec36535476b5b5e89e0e461190ba5ac1509b458e3e4917373976db")
    }
}
