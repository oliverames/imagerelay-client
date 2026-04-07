import Foundation

public enum ConflictResolver {
    public static func conflictName(for originalName: String) -> String {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let url = URL(fileURLWithPath: originalName)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent

        if ext.isEmpty {
            return "\(stem) (imagerelay conflict \(timestamp))"
        }
        return "\(stem) (imagerelay conflict \(timestamp)).\(ext)"
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
