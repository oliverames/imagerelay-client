import Foundation

public struct SyncAnchor: Sendable {
    public let version: UInt64

    public init(version: UInt64 = 0) {
        self.version = version
    }

    public func incremented() -> SyncAnchor {
        SyncAnchor(version: version + 1)
    }

    public var data: Data {
        withUnsafeBytes(of: version.bigEndian) { Data($0) }
    }

    public init?(data: Data) {
        guard data.count == MemoryLayout<UInt64>.size else { return nil }
        let value = data.withUnsafeBytes { $0.load(as: UInt64.self) }
        self.version = UInt64(bigEndian: value)
    }
}
