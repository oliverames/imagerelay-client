import Foundation

/// Controls how server-canonical filenames are presented in Finder.
///
/// Image Relay lowercases names on upload and replaces spaces with dashes,
/// so a file uploaded as `Annual Report.pdf` is stored server-side as
/// `annual-report.pdf` and surfaces in Finder under that ugly form. The
/// `humanReadable` style reverses the visible part of that transformation
/// at the File Provider boundary without touching the canonical name in
/// the database or on the server.
public enum FilenamePresentationStyle: String, Codable, Sendable, CaseIterable {
    /// Show the exact name the API returned. Default and lossless.
    case serverCanonical = "server_canonical"

    /// Replace dashes with spaces and title-case words. Lossy for names
    /// with intentional hyphens (e.g. "spider-man") or acronyms that were
    /// originally uppercase ("api-spec" → "Api Spec").
    case humanReadable = "human_readable"
}

public enum FilenamePresentation {
    /// Returns the display name for `canonicalName` under the given style.
    /// The canonical name (what the database and API see) is never mutated.
    public static func display(
        _ canonicalName: String,
        style: FilenamePresentationStyle = .serverCanonical
    ) -> String {
        switch style {
        case .serverCanonical:
            return canonicalName
        case .humanReadable:
            return humanReadable(canonicalName)
        }
    }

    private static func humanReadable(_ canonicalName: String) -> String {
        guard !canonicalName.isEmpty else { return canonicalName }
        // Dot-files are config/metadata, not user documents — leave alone.
        if canonicalName.hasPrefix(".") { return canonicalName }

        let nsName = canonicalName as NSString
        let ext = nsName.pathExtension
        let basename = nsName.deletingPathExtension

        let tokens = basename.split(separator: "-", omittingEmptySubsequences: true)
        let beautified = tokens.map(titleCase).joined(separator: " ")
        let finalBasename = beautified.isEmpty ? basename : beautified

        return ext.isEmpty ? finalBasename : "\(finalBasename).\(ext)"
    }

    /// Title-cases the first character of `word`, but leaves words that
    /// already contain uppercase letters alone. This preserves acronyms
    /// and proper case like "iPhone" or "API" when they reach us.
    private static func titleCase(_ word: Substring) -> String {
        if word.contains(where: \.isUppercase) {
            return String(word)
        }
        guard let first = word.first else { return "" }
        return String(first).uppercased() + word.dropFirst()
    }
}
