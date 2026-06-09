import Foundation

public enum TemporaryFileURL {
    public static let fallbackFilename = "download"
    public static let maxFilenameBytes = 180

    public static func make(
        originalName: String,
        directory: URL = FileManager.default.temporaryDirectory,
        uniquePrefix: String = UUID().uuidString
    ) -> URL {
        let safePrefix = safeFilename(from: uniquePrefix)
        let safeName = safeFilename(from: originalName)
        return directory.appendingPathComponent("\(safePrefix)-\(safeName)", isDirectory: false)
    }

    public static func safeFilename(from originalName: String) -> String {
        let replaced = String(
            originalName.unicodeScalars.map { scalar in
                disallowedScalars.contains(scalar) ? "_" : Character(scalar)
            }
        )
        let trimmed = replaced.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else {
            return fallbackFilename
        }
        return truncated(trimmed, maxBytes: maxFilenameBytes)
    }

    private static let disallowedScalars = CharacterSet(charactersIn: "/\\:")
        .union(.controlCharacters)
        .union(.newlines)

    private static func truncated(_ value: String, maxBytes: Int) -> String {
        var output = ""
        var byteCount = 0
        for character in value {
            let nextCount = String(character).utf8.count
            guard byteCount + nextCount <= maxBytes else { break }
            output.append(character)
            byteCount += nextCount
        }
        return output.isEmpty ? fallbackFilename : output
    }
}
