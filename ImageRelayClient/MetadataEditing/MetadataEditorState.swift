import Foundation
import ImageRelayKit
import os.log

/// View-model for `MetadataEditorView`. Holds the loading/error/dirty state and
/// coordinates calls into `MetadataEditingService`. Bound to the SwiftUI view via
/// `@Bindable`; mutated only on `@MainActor`.
@Observable @MainActor
final class MetadataEditorState {
    private let logger = Logger(
        subsystem: "com.oliverames.imagerelay-client",
        category: "MetadataEditor"
    )
    private let service = MetadataEditingService()

    enum Phase: Equatable {
        case empty
        case loading(remoteID: Int, fileName: String)
        case loaded(RemoteFileDetail)
        case failed(message: String, remoteID: Int?)
        case saving(RemoteFileDetail)
        case saved(RemoteFileDetail)
    }

    var phase: Phase = .empty
    var descriptionDraft: String = ""
    var keywordsDraft: String = ""

    var isBusy: Bool {
        switch phase {
        case .loading, .saving: return true
        default: return false
        }
    }

    var canSave: Bool {
        switch phase {
        case .loaded(let detail), .saved(let detail):
            return draftsDifferFrom(detail)
        default:
            return false
        }
    }

    var displayedFileName: String? {
        switch phase {
        case .loading(_, let name): return name
        case .loaded(let detail), .saving(let detail), .saved(let detail): return detail.name
        case .empty, .failed: return nil
        }
    }

    func load(remoteID: Int, fileName: String) async {
        phase = .loading(remoteID: remoteID, fileName: fileName)
        do {
            let detail = try await service.fetchDetail(remoteID: remoteID)
            descriptionDraft = detail.description ?? ""
            keywordsDraft = detail.keywords.joined(separator: ", ")
            phase = .loaded(detail)
        } catch {
            logger.warning("Metadata fetch failed for \(remoteID): \(error.localizedDescription)")
            phase = .failed(message: error.localizedDescription, remoteID: remoteID)
        }
    }

    func reload() async {
        switch phase {
        case .loaded(let detail), .saved(let detail), .saving(let detail):
            await load(remoteID: detail.id, fileName: detail.name)
        case .failed(_, let remoteID):
            if let remoteID { await load(remoteID: remoteID, fileName: "") }
        case .empty, .loading:
            break
        }
    }

    func save() async {
        guard case .loaded(let detail) = phase else { return }
        phase = .saving(detail)
        let update = FileMetadataUpdate(
            description: descriptionDraft != (detail.description ?? "") ? descriptionDraft : nil,
            keywords: parsedKeywords() != detail.keywords ? parsedKeywords() : nil
        )
        guard update.hasChanges else {
            phase = .loaded(detail)
            return
        }
        do {
            let saved = try await service.updateMetadata(remoteID: detail.id, update: update)
            descriptionDraft = saved.description ?? ""
            keywordsDraft = saved.keywords.joined(separator: ", ")
            phase = .saved(saved)
        } catch {
            logger.warning("Metadata save failed for \(detail.id): \(error.localizedDescription)")
            phase = .failed(message: error.localizedDescription, remoteID: detail.id)
        }
    }

    private func draftsDifferFrom(_ detail: RemoteFileDetail) -> Bool {
        if descriptionDraft != (detail.description ?? "") { return true }
        if parsedKeywords() != detail.keywords { return true }
        return false
    }

    private func parsedKeywords() -> [String] {
        keywordsDraft
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
