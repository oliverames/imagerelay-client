import FileProvider
import Foundation
import ImageRelayKit
import os.log

/// Registers (and unregisters) the iOS File Provider domain so the extension
/// surfaces in the Files app under "Locations". Idempotent: re-bootstrapping
/// after the user changes their API key just signals enumeration.
@Observable @MainActor
final class FileProviderDomainController {
    static let identifier = NSFileProviderDomainIdentifier("com.oliverames.imagerelay-client.ios.domain")
    static let displayName = "Image Relay"

    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client.ios", category: "FileProviderDomain")

    /// True once the system reports the domain registered. The Files app needs
    /// this before the location appears in Browse.
    private(set) var isRegistered = false
    private(set) var lastError: String?

    /// Registers the domain (or just signals enumeration if already registered).
    /// Safe to call from `App.task` on every launch.
    func bootstrap(isConfigured: Bool) async {
        guard isConfigured else {
            logger.info("Skipping domain registration — app not configured yet")
            return
        }

        let domain = NSFileProviderDomain(identifier: Self.identifier, displayName: Self.displayName)
        do {
            let domains = try await NSFileProviderManager.domains()
            if !domains.contains(where: { $0.identifier == Self.identifier }) {
                try await NSFileProviderManager.add(domain)
                logger.info("Added File Provider domain")
            }
            isRegistered = true
            lastError = nil
            await signalEnumeration()
        } catch {
            logger.error("Domain bootstrap failed: \(error.localizedDescription)")
            isRegistered = false
            lastError = error.localizedDescription
        }
    }

    /// Removes the domain. Used when the user signs out from Settings.
    func unregister() async {
        let domain = NSFileProviderDomain(identifier: Self.identifier, displayName: Self.displayName)
        do {
            try await NSFileProviderManager.remove(domain)
            isRegistered = false
            lastError = nil
        } catch {
            logger.error("Domain unregister failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    /// Tells the system to refresh the working set. Useful after a config change.
    func signalEnumeration() async {
        let domain = NSFileProviderDomain(identifier: Self.identifier, displayName: Self.displayName)
        guard let manager = NSFileProviderManager(for: domain) else { return }
        do {
            try await manager.signalEnumerator(for: .workingSet)
        } catch {
            logger.warning("signalEnumerator failed: \(error.localizedDescription)")
        }
    }
}
