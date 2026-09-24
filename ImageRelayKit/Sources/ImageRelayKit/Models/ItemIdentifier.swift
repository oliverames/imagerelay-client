import Foundation

public struct ItemIdentifier: RawRepresentable, Sendable, Hashable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.hasPrefix("folder-") || rawValue.hasPrefix("file-") else {
            return nil
        }
        let payload = String(rawValue.dropFirst(rawValue.hasPrefix("folder-") ? 7 : 5))
        let components = payload.components(separatedBy: "-in-")
        guard Int(components[0]) != nil else { return nil }
        if components.count > 1 {
            guard rawValue.hasPrefix("file-"), components.count == 2,
                  let folderID = Int(components[1]), folderID > 0 else { return nil }
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

    /// A separate local appearance of an asset in another folder. The remote
    /// asset ID is unchanged, and legacy file IDs remain valid.
    public static func membership(fileID: Int, folderID: Int) -> ItemIdentifier {
        precondition(folderID > 0)
        return ItemIdentifier(unchecked: "file-\(fileID)-in-\(folderID)")
    }

    public var membershipFolderID: Int? {
        guard isFile else { return nil }
        let components = rawValue.components(separatedBy: "-in-")
        return components.count == 2 ? Int(components[1]) : nil
    }

    public var isFolder: Bool { rawValue.hasPrefix("folder-") }
    public var isFile: Bool { rawValue.hasPrefix("file-") }

    public var numericID: Int? {
        guard let dashIndex = rawValue.firstIndex(of: "-") else { return nil }
        return Int(rawValue[rawValue.index(after: dashIndex)...].components(separatedBy: "-in-")[0])
    }
}
