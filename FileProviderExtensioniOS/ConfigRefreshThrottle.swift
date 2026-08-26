import Foundation
import ImageRelayKit

/// Throttles `AppConfiguration.loadAndRefresh` for the stateless iOS
/// extension. Every operation used to re-read config.json and query the
/// Keychain, and a burst of downloads during an OAuth near-expiry window
/// serialized each one on the refresh lock file.
///
/// A real refresh runs when at least `interval` seconds have elapsed since
/// the last one OR config.json's modification date moved, so settings edits
/// still apply immediately. Nothing persists beyond the process: with no
/// shared state across restarts the extension stays stateless, and the 60s
/// staleness is safely inside the >600s token-expiry margin that gates
/// refreshes.
final class ConfigRefreshThrottle: @unchecked Sendable {
    static let shared = ConfigRefreshThrottle()

    private let interval: TimeInterval
    private let lock = NSLock()
    private var lastRefreshAt: Date?
    private var lastModDate: Date?

    init(interval: TimeInterval = 60) {
        self.interval = interval
    }

    func refreshIfDue(container: URL) async {
        let configURL = AppConfiguration.fileURL(in: container)
        guard !isFresh(configURL) else { return }

        _ = try? await AppConfiguration.loadAndRefresh(from: configURL)

        // Re-stat after the refresh: loadAndRefresh itself may persist rotated
        // tokens, and that write must count as "fresh" for the next caller.
        markRefreshed(configURL)
    }

    private func isFresh(_ configURL: URL) -> Bool {
        lock.withLock {
            let modDate = Self.modDate(of: configURL)
            if let last = lastRefreshAt,
               Date().timeIntervalSince(last) < interval,
               lastModDate == modDate {
                return true
            }
            return false
        }
    }

    private func markRefreshed(_ configURL: URL) {
        lock.withLock {
            lastRefreshAt = Date()
            lastModDate = Self.modDate(of: configURL)
        }
    }

    private static func modDate(of url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }
}
