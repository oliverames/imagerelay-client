import AppKit
import FileProvider
import ImageRelayKit
import os.log

@Observable @MainActor
final class DomainManager {
    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client", category: "DomainManager")
    static let domainIdentifier = NSFileProviderDomainIdentifier("com.oliverames.imagerelay-client.domain")
    static let domainDisplayName = "Image Relay"

    var isDomainActive = false
    var lastError: String?

    func setupDomain() async {
        let domain = NSFileProviderDomain(
            identifier: Self.domainIdentifier,
            displayName: Self.domainDisplayName
        )

        do {
            try await NSFileProviderManager.add(domain)
            isDomainActive = true
            lastError = nil
            logger.info("File Provider domain added successfully")
        } catch let error as NSError where error.code == NSFileWriteFileExistsError {
            isDomainActive = true
            lastError = nil
        } catch {
            isDomainActive = false
            lastError = error.localizedDescription
            logger.error("Failed to add domain: \(error.localizedDescription)")
        }
    }

    func removeDomain() async {
        let domain = NSFileProviderDomain(
            identifier: Self.domainIdentifier,
            displayName: Self.domainDisplayName
        )
        do {
            try await NSFileProviderManager.remove(domain)
            isDomainActive = false
        } catch {
            logger.error("Failed to remove domain: \(error.localizedDescription)")
        }
    }

    func signalSync() async {
        let domain = NSFileProviderDomain(
            identifier: Self.domainIdentifier,
            displayName: Self.domainDisplayName
        )
        guard let manager = NSFileProviderManager(for: domain) else { return }
        do {
            try await manager.signalEnumerator(for: .workingSet)
        } catch {
            logger.error("Failed to signal sync: \(error.localizedDescription)")
        }
    }

    func openInFinder() {
        let domain = NSFileProviderDomain(
            identifier: Self.domainIdentifier,
            displayName: Self.domainDisplayName
        )
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.getUserVisibleURL(for: .rootContainer) { url, error in
            if let url {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
