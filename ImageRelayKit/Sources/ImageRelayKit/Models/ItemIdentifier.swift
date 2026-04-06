import Foundation

public struct ItemIdentifier: RawRepresentable, Sendable, Hashable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.hasPrefix("folder-") || rawValue.hasPrefix("file-") else {
            return nil
        }
        guard let dashIndex = rawValue.firstIndex(of: "-"),
              Int(rawValue[rawValue.index(after: dashIndex)...]) != nil else {
            return nil
        }
        self.rawValue = rawValue
    }

    // Non-failable init for factory methods
    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    public static func folder(_ id: Int) -> ItemIdentifier {
        ItemIdentifier(unchecked: "folder-\(id)")
    }

    public static func file(_ id: Int) -> ItemIdentifier {
        ItemIdentifier(unchecked: "file-\(id)")
    }

    public var isFolder: Bool { rawValue.hasPrefix("folder-") }
    public var isFile: Bool { rawValue.hasPrefix("file-") }

    public var numericID: Int? {
        guard let dashIndex = rawValue.firstIndex(of: "-") else { return nil }
        return Int(rawValue[rawValue.index(after: dashIndex)...])
    }
}
