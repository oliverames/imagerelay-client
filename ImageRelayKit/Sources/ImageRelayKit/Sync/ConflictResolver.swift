import Foundation

public enum ConflictResolver {
    public static func conflictName(for originalName: String) -> String {
        // ISO8601DateFormatter is documented as thread-safe, unlike DateFormatter.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "T", with: " ")
        let url = URL(fileURLWithPath: originalName)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent

        if ext.isEmpty {
            return "\(stem) (imagerelay conflict \(timestamp))"
        }
        return "\(stem) (imagerelay conflict \(timestamp)).\(ext)"
    }
}
