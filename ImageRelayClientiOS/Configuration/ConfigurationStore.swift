import Foundation
import ImageRelayKit
import os.log

/// Reads and writes `AppConfiguration` from the shared App Group container.
/// The same `config.json` and Keychain entry are used by the iOS host app and
/// the iOS File Provider extension. The macOS app writes to a separate per-device
/// container, so iOS state is independent.
@Observable @MainActor
final class ConfigurationStore {
    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client.ios", category: "ConfigurationStore")

    /// Latest snapshot of configuration. UI bindings read from `draft*` fields and
    /// commit via `save()`; this is the post-save value.
    private(set) var snapshot: AppConfiguration = .default

    /// Editable mirror of `apiKey`. Stays empty until the user starts typing or
    /// `refresh()` populates it from Keychain.
    var draftAPIKey: String = ""

    /// Editable mirror of `remoteRootFolderID`. Empty string means "unset".
    var draftRootFolderID: String = ""

    /// Last error message, if any, from `save()` or `refresh()`.
    var lastError: String?

    func refresh() {
        let loaded = load()
        snapshot = loaded
        draftAPIKey = loaded.apiKey
        draftRootFolderID = loaded.remoteRootFolderID.map(String.init) ?? ""
    }

    /// Outcome of a save attempt. `materialChange` is true when the API key
    /// or root folder ID changed — the caller needs to bounce the File
    /// Provider domain so the extension re-instantiates with fresh services.
    struct SaveResult: Sendable {
        var saved: Bool
        var materialChange: Bool
    }

    /// Persists the draft fields. Caller inspects `SaveResult.materialChange`
    /// to decide whether to reload the File Provider domain.
    @discardableResult
    func save() -> SaveResult {
        guard let container = AppConfiguration.containerURL() else {
            lastError = "App Group container unavailable. Reinstall the app."
            return SaveResult(saved: false, materialChange: false)
        }
        var next = snapshot
        next.apiKey = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = draftRootFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
        next.remoteRootFolderID = trimmedRoot.isEmpty ? nil : Int(trimmedRoot)
        next.userAgent = "ImageRelayClient/1.1 (iOS)"

        let materialChange = next.apiKey != snapshot.apiKey
            || next.remoteRootFolderID != snapshot.remoteRootFolderID

        do {
            try next.save(to: AppConfiguration.fileURL(in: container))
            snapshot = next
            lastError = nil
            return SaveResult(saved: true, materialChange: materialChange)
        } catch {
            logger.error("Save failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            return SaveResult(saved: false, materialChange: false)
        }
    }

    /// Updates a single sync flag and persists. Used by the Settings toggles.
    @discardableResult
    func setSyncDownload(_ value: Bool) -> Bool {
        snapshot.syncDownload = value
        return persistSnapshot()
    }

    @discardableResult
    func setSyncUpload(_ value: Bool) -> Bool {
        snapshot.syncUpload = value
        return persistSnapshot()
    }

    private func persistSnapshot() -> Bool {
        guard let container = AppConfiguration.containerURL() else {
            lastError = "App Group container unavailable. Reinstall the app."
            return false
        }
        do {
            try snapshot.save(to: AppConfiguration.fileURL(in: container))
            lastError = nil
            return true
        } catch {
            logger.error("Persist failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            return false
        }
    }

    private func load() -> AppConfiguration {
        guard let container = AppConfiguration.containerURL() else { return .default }
        return (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
    }
}
