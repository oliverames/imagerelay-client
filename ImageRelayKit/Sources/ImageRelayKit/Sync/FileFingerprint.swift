import CryptoKit
import Foundation

public struct FileFingerprint: Codable, Sendable, Equatable, Hashable {
    public let size: Int64
    public let sha256: String

    public init(size: Int64, sha256: String) {
        self.size = max(0, size)
        self.sha256 = sha256
    }
}

public enum FileFingerprinting {
    public static func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw CocoaError(.fileReadUnknown)
        }
        return Int64(values.fileSize ?? 0)
    }

    public static func fingerprint(of url: URL, chunkSize: Int = 1024 * 1024) throws -> FileFingerprint {
        let size = try fileSize(at: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var bytesRead: Int64 = 0
        while true {
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            guard !data.isEmpty else { break }
            bytesRead += Int64(data.count)
            hasher.update(data: data)
        }

        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return FileFingerprint(size: max(size, bytesRead), sha256: hex)
    }
}
