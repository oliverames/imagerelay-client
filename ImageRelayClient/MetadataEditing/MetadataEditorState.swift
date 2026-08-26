import Foundation
import ImageRelayKit
import os.log

/// View-model for `MetadataEditorView`. Now handles 1..N targets so multi-selecting
/// files in Finder edits the whole batch with Finder-style semantics:
/// - Description / custom fields: shown only when every selected file shares the
///   same value, otherwise blanked with a "Multiple values" hint. Typing into the
///   field overwrites every selected file on save.
/// - Keywords: union across all selected files (mirrors Finder Tags). Saving
///   replaces each file's keywords with the displayed set, so the warning hint
///   in the view makes that explicit.
@Observable @MainActor
final class MetadataEditorState {
    private let logger = Logger(
        subsystem: "com.oliverames.imagerelay-client",
        category: "MetadataEditor"
    )
    private let service = MetadataEditingService()

    enum Phase: Equatable {
        case empty
        case loading(targets: [Target])
        case loaded(details: [RemoteFileDetail])
        case saving(details: [RemoteFileDetail])
        case saved(details: [RemoteFileDetail], failures: [SaveFailure])
        case failed(message: String, remoteIDs: [Int])
    }

    struct Target: Hashable, Sendable {
        let remoteID: Int
        let fileName: String
    }

    struct SaveFailure: Equatable, Hashable, Identifiable, Sendable {
        let remoteID: Int
        let fileName: String
        let message: String
        var id: Int { remoteID }
    }

    var phase: Phase = .empty
    var descriptionDraft: String = ""
    var keywordsDraft: String = ""
    /// Map keyed by `CustomField.stableID` so renames are stable across reloads.
    var customFieldDrafts: [String: String] = [:]

    /// Per-field mixed-value flags drive the "Multiple values" hint in the view.
    var descriptionHasMixedValues: Bool = false
    var customFieldHasMixedValues: [String: Bool] = [:]

    /// Keyword suggestions for autocomplete, sorted by usage_count desc. Loaded
    /// lazily after the first detail fetch so the editor opens fast.
    var keywordSuggestions: [Keyword] = []
    private var hasLoadedSuggestions = false

    /// Current keyword tokens parsed from `keywordsDraft`. Cheap enough to
    /// recompute on every access; surfaced as a property for view binding.
    var currentKeywordTokens: [String] {
        keywordsDraft
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var isBusy: Bool {
        switch phase {
        case .loading, .saving: return true
        default: return false
        }
    }

    var targetCount: Int {
        switch phase {
        case .loading(let targets): return targets.count
        case .loaded(let details), .saving(let details): return details.count
        case .saved(let details, _): return details.count
        case .failed(_, let remoteIDs): return remoteIDs.count
        case .empty: return 0
        }
    }

    var isMultiSelect: Bool { targetCount > 1 }

    var canSave: Bool {
        let details = currentDetails()
        guard !details.isEmpty else { return false }
        switch phase {
        case .loaded, .saved:
            return draftsHaveChanges(against: details)
        default:
            return false
        }
    }

    var displayedFileName: String? {
        switch phase {
        case .loading(let targets):
            return targets.first?.fileName
        case .loaded(let details), .saving(let details), .saved(let details, _):
            return details.first?.name
        default:
            return nil
        }
    }

    var headerSubtitle: String? {
        let count = targetCount
        if count > 1 {
            return "Editing \(count) files"
        }
        switch phase {
        case .loaded(let details), .saving(let details), .saved(let details, _):
            return details.first.map { "Asset ID \($0.id)" }
        default:
            return nil
        }
    }

    func currentDetails() -> [RemoteFileDetail] {
        switch phase {
        case .loaded(let details), .saving(let details), .saved(let details, _):
            return details
        default:
            return []
        }
    }

    // MARK: - Loading

    /// Backwards-compatible single-target load. Wraps `load(targets:)` with N=1.
    func load(remoteID: Int, fileName: String) async {
        await load(targets: [Target(remoteID: remoteID, fileName: fileName)])
    }

    func load(targets: [Target]) async {
        guard !targets.isEmpty else {
            phase = .empty
            return
        }
        phase = .loading(targets: targets)

        // Fan out concurrently; APIClient's RateLimiter + retry handle throttling.
        var fetched: [Int: RemoteFileDetail] = [:]
        var firstError: String?
        let service = self.service
        await withTaskGroup(of: (Int, Result<RemoteFileDetail, Error>).self) { group in
            for target in targets {
                let remoteID = target.remoteID
                group.addTask {
                    do {
                        let detail = try await service.fetchDetail(remoteID: remoteID)
                        return (remoteID, .success(detail))
                    } catch {
                        return (remoteID, .failure(error))
                    }
                }
            }
            for await (remoteID, result) in group {
                switch result {
                case .success(let detail):
                    fetched[remoteID] = detail
                case .failure(let error):
                    if firstError == nil {
                        firstError = error.localizedDescription
                    }
                    logger.warning("Metadata fetch failed for \(remoteID): \(error.localizedDescription)")
                }
            }
        }

        if fetched.isEmpty {
            phase = .failed(
                message: firstError ?? "Couldn't load metadata.",
                remoteIDs: targets.map(\.remoteID)
            )
            return
        }

        // Preserve user-selected order in the displayed details.
        let ordered = targets.compactMap { fetched[$0.remoteID] }
        applyDrafts(from: ordered)
        phase = .loaded(details: ordered)
    }

    /// Fetches keyword suggestions once per session. Safe to call repeatedly;
    /// subsequent calls are no-ops. Fetch happens off-MainActor via the service.
    func loadSuggestionsIfNeeded() async {
        guard !hasLoadedSuggestions else { return }
        hasLoadedSuggestions = true
        let fetched = await service.fetchAllKeywords()
        // Sort by usage_count desc with nil treated as 0; ties broken by name.
        keywordSuggestions = fetched.sorted {
            let lhsUsage = $0.usageCount ?? 0
            let rhsUsage = $1.usageCount ?? 0
            if lhsUsage != rhsUsage { return lhsUsage > rhsUsage }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Adds a keyword to `keywordsDraft` if not already present.
    func toggleKeyword(_ name: String) {
        var tokens = currentKeywordTokens
        if let index = tokens.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            tokens.remove(at: index)
        } else {
            tokens.append(name)
        }
        keywordsDraft = tokens.joined(separator: ", ")
    }

    func isKeywordSelected(_ name: String) -> Bool {
        currentKeywordTokens.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func reload() async {
        switch phase {
        case .loaded(let details), .saved(let details, _), .saving(let details):
            let targets = details.map { Target(remoteID: $0.id, fileName: $0.name) }
            await load(targets: targets)
        case .failed(_, let remoteIDs) where !remoteIDs.isEmpty:
            let targets = remoteIDs.map { Target(remoteID: $0, fileName: "") }
            await load(targets: targets)
        case .empty, .loading, .failed:
            break
        }
    }

    // MARK: - Saving

    func save() async {
        guard case .loaded(let details) = phase, !details.isEmpty else { return }
        phase = .saving(details: details)

        let update = computeUpdate(against: details)
        guard update.hasChanges else {
            phase = .loaded(details: details)
            return
        }

        var saved: [Int: RemoteFileDetail] = [:]
        var failures: [SaveFailure] = []
        let service = self.service

        await withTaskGroup(of: (Int, Result<RemoteFileDetail, Error>).self) { group in
            for detail in details {
                let id = detail.id
                let payload = update
                group.addTask {
                    do {
                        let result = try await service.updateMetadata(remoteID: id, update: payload)
                        return (id, .success(result))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let detail):
                    saved[id] = detail
                case .failure(let error):
                    let original = details.first { $0.id == id }
                    failures.append(SaveFailure(
                        remoteID: id,
                        fileName: original?.name ?? "asset \(id)",
                        message: error.localizedDescription
                    ))
                    logger.warning("Save failed for \(id): \(error.localizedDescription)")
                }
            }
        }

        // Merge: prefer the saved (server-returned) detail, fall back to the original
        // for any file that failed so the editor stays usable for a retry.
        let merged = details.map { saved[$0.id] ?? $0 }
        applyDrafts(from: merged)
        phase = .saved(details: merged, failures: failures)
    }

    // MARK: - Draft <-> details

    private func applyDrafts(from details: [RemoteFileDetail]) {
        guard !details.isEmpty else {
            descriptionDraft = ""
            keywordsDraft = ""
            customFieldDrafts = [:]
            descriptionHasMixedValues = false
            customFieldHasMixedValues = [:]
            return
        }

        let descriptions = details.map { $0.description ?? "" }
        let descriptionsMatch = descriptions.allEqual()
        descriptionDraft = descriptionsMatch ? (descriptions.first ?? "") : ""
        descriptionHasMixedValues = !descriptionsMatch && details.count > 1

        // Keywords: union across all selected files (Finder Tags semantics).
        // Order preserves first-seen-first across the selection.
        var unionKeywords: [String] = []
        var seenKeywords: Set<String> = []
        for detail in details {
            for keyword in detail.keywords where !seenKeywords.contains(keyword) {
                unionKeywords.append(keyword)
                seenKeywords.insert(keyword)
            }
        }
        keywordsDraft = unionKeywords.joined(separator: ", ")

        // Custom fields: per stableID, value is the common value when every selected
        // file has the field with the same value; otherwise blank + mixed-flagged.
        var newDrafts: [String: String] = [:]
        var newMixed: [String: Bool] = [:]
        let allFieldKeys = Set(details.flatMap { detail in
            detail.customFields.map(\.stableID)
        })
        for key in allFieldKeys {
            let valuesOnEach: [String?] = details.map { detail in
                detail.customFields.first(where: { $0.stableID == key })?.value
            }
            let appearsOnAll = valuesOnEach.allSatisfy { $0 != nil }
            let normalized = valuesOnEach.map { $0 ?? "" }
            let matches = normalized.allEqual()
            let allSame = appearsOnAll && matches
            newDrafts[key] = allSame ? (normalized.first ?? "") : ""
            newMixed[key] = !allSame && details.count > 1
        }
        customFieldDrafts = newDrafts
        customFieldHasMixedValues = newMixed
    }

    private func draftsHaveChanges(against details: [RemoteFileDetail]) -> Bool {
        for detail in details {
            if descriptionDraft != (detail.description ?? "") { return true }
            if parsedKeywords() != detail.keywords { return true }
            for field in detail.customFields {
                let current = field.value ?? ""
                let draft = customFieldDrafts[field.stableID] ?? ""
                if draft != current { return true }
            }
        }
        return false
    }

    private func computeUpdate(against details: [RemoteFileDetail]) -> FileMetadataUpdate {
        // Description: send when draft differs from any file's current value AND
        // the user actually has a value to apply (mixed-blank means "don't touch").
        let descriptionUpdate: String? = {
            if descriptionHasMixedValues && descriptionDraft.isEmpty {
                return nil
            }
            let differs = details.contains { ($0.description ?? "") != descriptionDraft }
            return differs ? descriptionDraft : nil
        }()

        // Keywords: send the parsed set when it differs from any file's current keywords.
        // With union semantics, this almost always fires on multi-select; that's the
        // documented behavior surfaced in the view's warning hint.
        let parsed = parsedKeywords()
        let keywordsUpdate: [String]? = {
            let differs = details.contains { $0.keywords != parsed }
            return differs ? parsed : nil
        }()

        // Custom fields: per-field updates, skipping mixed-blank (don't-touch).
        var customFieldUpdates: [FileMetadataUpdate.CustomFieldUpdate] = []
        let fieldsByKey = Dictionary(
            details
                .flatMap(\.customFields)
                .map { ($0.stableID, $0) },
            uniquingKeysWith: { _, latest in latest }
            // Last write wins; we just need a representative field for id/name.
            // uniquingKeysWith is required: multi-selected files routinely share
            // field definitions, and uniqueKeysWithValues would trap on the
            // duplicate keys.
        )
        for (key, field) in fieldsByKey {
            let draft = customFieldDrafts[key] ?? ""
            if (customFieldHasMixedValues[key] ?? false) && draft.isEmpty {
                continue
            }
            let differs = details.contains { detail in
                let current = detail.customFields
                    .first(where: { $0.stableID == key })?.value ?? ""
                return draft != current
            }
            if differs {
                customFieldUpdates.append(.init(
                    id: field.id,
                    name: field.name,
                    value: draft.isEmpty ? nil : draft
                ))
            }
        }

        return FileMetadataUpdate(
            description: descriptionUpdate,
            keywords: keywordsUpdate,
            customFields: customFieldUpdates.isEmpty ? nil : customFieldUpdates
        )
    }

    private func parsedKeywords() -> [String] {
        keywordsDraft
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension Array where Element: Equatable {
    func allEqual() -> Bool {
        guard let head = first else { return true }
        return dropFirst().allSatisfy { $0 == head }
    }
}
