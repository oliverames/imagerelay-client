import AppKit
import Foundation
import os.log

/// Reads the current Finder selection via AppleScript. Sandboxed: requires
/// `com.apple.security.scripting-targets` with `com.apple.finder` access in the
/// app's entitlements.
///
/// Two failure shapes the caller should distinguish:
///   - `notAuthorized`: the user hasn't granted Automation permission (or
///     the entitlement is missing/wrong). The caller should fall back to a
///     file picker instead of showing a hard error.
///   - `applescriptFailed`: AppleScript ran but returned an error. Surface
///     to the user.
@MainActor
struct FinderSelectionReader {
    private let logger = Logger(
        subsystem: "com.oliverames.imagerelay-client",
        category: "FinderSelection"
    )

    enum SelectionError: LocalizedError {
        case notAuthorized
        case applescriptFailed(String)
        case noSelection

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Image Relay needs permission to read your Finder selection. Approve the prompt or grant access in System Settings → Privacy & Security → Automation."
            case .applescriptFailed(let message):
                return "Reading Finder selection failed: \(message)"
            case .noSelection:
                return "Nothing is selected in Finder. Click an asset in the Image Relay folder, then try again."
            }
        }
    }

    /// Returns file URLs for items currently selected in Finder. Throws
    /// `SelectionError.noSelection` if Finder reports an empty selection.
    func readSelection() throws -> [URL] {
        let source = """
        tell application "Finder"
            set _selection to selection as alias list
            set _paths to {}
            repeat with _item in _selection
                set end of _paths to POSIX path of (_item as text)
            end repeat
            return _paths
        end tell
        """

        guard let script = NSAppleScript(source: source) else {
            throw SelectionError.applescriptFailed("Couldn't compile selection script.")
        }

        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)

        if let error = errorInfo as? [String: Any] {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
            logger.warning("AppleScript error \(code): \(message)")
            // -1743 is the standard "not authorized" Apple Events error
            if code == -1743 {
                throw SelectionError.notAuthorized
            }
            throw SelectionError.applescriptFailed(message)
        }

        var urls: [URL] = []
        for index in 1...max(descriptor.numberOfItems, 0) {
            guard let item = descriptor.atIndex(index) else { continue }
            guard let path = item.stringValue, !path.isEmpty else { continue }
            urls.append(URL(fileURLWithPath: path))
        }

        if urls.isEmpty { throw SelectionError.noSelection }
        return urls
    }
}
