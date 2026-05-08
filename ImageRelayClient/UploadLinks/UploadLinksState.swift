import Foundation
import ImageRelayKit
import os.log

/// View-model for the Upload Links Settings tab. Holds the list, current selection,
/// and form drafts for creating new links.
@Observable @MainActor
final class UploadLinksState {
    private let logger = Logger(
        subsystem: "com.oliverames.imagerelay-client",
        category: "UploadLinksState"
    )
    private let service = UploadLinksService()

    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    var phase: LoadPhase = .idle
    var links: [UploadLink] = []

    // Create form drafts
    var draftName: String = ""
    var draftFolderID: String = ""
    var draftExpiresOn: Date? = nil
    var draftMaxFiles: String = ""
    var draftPassword: String = ""
    var isCreating: Bool = false
    var lastCreateError: String? = nil

    var canCreate: Bool {
        !draftName.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(draftFolderID) != nil
            && !isCreating
    }

    func load() async {
        phase = .loading
        do {
            links = try await service.list()
            phase = .loaded
        } catch {
            logger.warning("Upload links list failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    func create() async -> Bool {
        guard let folderID = Int(draftFolderID) else { return false }
        let payload = UploadLinkCreate(
            name: draftName.trimmingCharacters(in: .whitespaces),
            folderID: folderID,
            expiresOn: draftExpiresOn.map { Self.expiresOnFormatter.string(from: $0) },
            maxFiles: Int(draftMaxFiles),
            password: draftPassword.isEmpty ? nil : draftPassword
        )

        isCreating = true
        lastCreateError = nil
        defer { isCreating = false }

        do {
            let created = try await service.create(payload)
            links.insert(created, at: 0)
            // Reset the form
            draftName = ""
            draftFolderID = ""
            draftExpiresOn = nil
            draftMaxFiles = ""
            draftPassword = ""
            return true
        } catch {
            logger.warning("Upload link create failed: \(error.localizedDescription)")
            lastCreateError = error.localizedDescription
            return false
        }
    }

    func delete(_ link: UploadLink) async {
        do {
            try await service.delete(id: link.id)
            links.removeAll { $0.id == link.id }
        } catch {
            logger.warning("Upload link delete failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    private static let expiresOnFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}
