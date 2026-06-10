import Foundation

/// Async rate-limiter abstraction. The default in-process `RateLimiter` and the
/// cross-process `SharedRateLimiter` both conform; `APIClient` accepts either.
public protocol AsyncRateLimiting: Sendable {
    /// Block until the caller may issue a request.
    func acquire() async
    /// Called by `APIClient` after a 429 response so the limiter can tighten its
    /// budget. `retryAfter` carries a server-provided cooldown hint when one
    /// exists — a parsed `Retry-After` header or a daily-limit reset interval.
    func recordRateLimit(retryAfter: TimeInterval?) async
    /// Called by `APIClient` after a successful request so the limiter can recover.
    func recordSuccess() async
}

public extension AsyncRateLimiting {
    /// Convenience for call sites without a server cooldown hint.
    func recordRateLimit() async {
        await recordRateLimit(retryAfter: nil)
    }
}

public actor RateLimiter: AsyncRateLimiting {
    public static let hostAppShared = RateLimiter(maxRequests: 1, period: 1.0)
    public static let fileProviderExtensionShared = RateLimiter(maxRequests: 4, period: 1.0)

    private let maxRequests: Int
    private let period: Duration
    private var timestamps: [ContinuousClock.Instant] = []

    public init(maxRequests: Int = SharedRateLimiter.defaultMaxRequests, period: Double = 1.0) {
        self.maxRequests = maxRequests
        self.period = .seconds(period)
    }

    public func acquire() async {
        while true {
            let now = ContinuousClock.now
            timestamps.removeAll { now - $0 >= period }

            if timestamps.count < maxRequests {
                timestamps.append(now)
                return
            }

            let oldest = timestamps[0]
            let waitTime = period - (now - oldest)
            if waitTime > .zero {
                try? await Task.sleep(for: waitTime + .milliseconds(10))
            }
        }
    }

    // The in-process limiter is dumb on purpose — feedback hooks no-op so callers
    // that target a single limiter type don't need to special-case the variant.
    public func recordRateLimit(retryAfter: TimeInterval?) async {}
    public func recordSuccess() async {}
}
