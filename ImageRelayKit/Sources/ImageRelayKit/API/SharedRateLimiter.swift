import Foundation

/// Persisted state for the cross-process rate limiter. Lives at
/// `<app group container>/rate-limiter-state.json` so the host app and
/// File Provider extension share one token bucket and one ramp position.
///
/// Schema is intentionally minimal and forward-tolerant — all fields decode
/// with defaults so an older binary can read a newer file's payload.
public struct SharedRateLimiterState: Codable, Equatable, Sendable {
    /// Unix-epoch timestamps of recent request acquires across all processes.
    public var timestamps: [Double]
    /// 0 = full rate, 1..3 = partial throttle, 4 = single-probe lock.
    public var rampPhase: Int
    /// Consecutive successful requests at the current ramp phase. When this
    /// crosses the hysteresis threshold the phase steps down toward 0.
    public var consecutiveSuccesses: Int
    /// Process-spanning probe lock. When `rampPhase == 4`, only the process
    /// that holds this token may have an in-flight request.
    public var probeToken: String?
    /// Wall-clock expiry for `probeToken` (Unix-epoch). If the holder dies
    /// without releasing the lock, the next acquire after this point steals
    /// the slot rather than wedging the whole client.
    public var probeTokenExpires: Double?

    public init(
        timestamps: [Double] = [],
        rampPhase: Int = 0,
        consecutiveSuccesses: Int = 0,
        probeToken: String? = nil,
        probeTokenExpires: Double? = nil
    ) {
        self.timestamps = timestamps
        self.rampPhase = max(0, min(4, rampPhase))
        self.consecutiveSuccesses = max(0, consecutiveSuccesses)
        self.probeToken = probeToken
        self.probeTokenExpires = probeTokenExpires
    }

    enum CodingKeys: String, CodingKey {
        case timestamps
        case rampPhase = "ramp_phase"
        case consecutiveSuccesses = "consecutive_successes"
        case probeToken = "probe_token"
        case probeTokenExpires = "probe_token_expires"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamps = (try c.decodeIfPresent([Double].self, forKey: .timestamps)) ?? []
        rampPhase = max(0, min(4, try c.decodeIfPresent(Int.self, forKey: .rampPhase) ?? 0))
        consecutiveSuccesses = max(0, try c.decodeIfPresent(Int.self, forKey: .consecutiveSuccesses) ?? 0)
        probeToken = try c.decodeIfPresent(String.self, forKey: .probeToken)
        probeTokenExpires = try c.decodeIfPresent(Double.self, forKey: .probeTokenExpires)
    }
}

/// Cross-process rate limiter shared by the host app and File Provider extension
/// via the App Group container. Coordinates a single 5-RPS token bucket and a
/// single-probe ramp protocol so that:
///
/// - Combined throughput across both processes stays below Image Relay's documented
///   5 requests/second limit (see #16).
/// - After a 429 in either process, both processes immediately observe the tightened
///   ramp on their next acquire (no per-process drift).
/// - During deep throttle (`rampPhase == 4`), only ONE in-flight request is allowed
///   across both processes — the single-probe pattern recommended for recovering
///   from sustained-overage cooldowns.
///
/// The state file is updated through `NSFileCoordinator` to make read-modify-write
/// safe across processes; the same coordination pattern is used by `ThrottleStateStore`.
public actor SharedRateLimiter: AsyncRateLimiting {
    public static let defaultMaxRequests = 5
    public static let defaultPeriodSeconds: Double = 1.0
    /// Number of consecutive successes required before stepping ramp phase down by one.
    public static let defaultRecoveryHysteresis = 5
    /// Maximum time a single probe is allowed to hold the in-flight lock. If the
    /// holder dies without releasing, the next acquire after this elapses steals.
    public static let defaultProbeLockTTL: TimeInterval = 30

    let url: URL
    let maxRequests: Int
    let period: Double
    let recoveryHysteresis: Int
    let probeLockTTL: TimeInterval
    let processIdentifier: String

    public init(
        url: URL,
        maxRequests: Int = SharedRateLimiter.defaultMaxRequests,
        period: Double = SharedRateLimiter.defaultPeriodSeconds,
        recoveryHysteresis: Int = SharedRateLimiter.defaultRecoveryHysteresis,
        probeLockTTL: TimeInterval = SharedRateLimiter.defaultProbeLockTTL,
        processIdentifier: String = UUID().uuidString
    ) {
        self.url = url
        self.maxRequests = max(1, maxRequests)
        self.period = max(0.1, period)
        self.recoveryHysteresis = max(1, recoveryHysteresis)
        self.probeLockTTL = max(1.0, probeLockTTL)
        self.processIdentifier = processIdentifier
    }

    public static func fileURL(in container: URL) -> URL {
        container.appendingPathComponent("rate-limiter-state.json")
    }

    public func acquire() async {
        while true {
            try? Task.checkCancellation()

            let now = Date().timeIntervalSince1970
            var state = readState()
            // Prune timestamps outside the rolling window.
            let cutoff = now - period
            state.timestamps = state.timestamps.filter { $0 >= cutoff }

            let effectiveMax = Self.effectiveMaxRequests(
                rampPhase: state.rampPhase,
                fullMax: maxRequests
            )

            if state.rampPhase == 4 {
                // Single-probe lock semantics: one in-flight request total. If we
                // already hold the lock OR the previous holder's lease has expired,
                // grab it; otherwise spin-wait until the next chance.
                let lockIsFree: Bool
                if let token = state.probeToken {
                    if token == processIdentifier {
                        lockIsFree = true
                    } else if let expires = state.probeTokenExpires, expires < now {
                        // Stale lease — steal.
                        lockIsFree = true
                    } else {
                        lockIsFree = false
                    }
                } else {
                    lockIsFree = true
                }

                if lockIsFree {
                    state.probeToken = processIdentifier
                    state.probeTokenExpires = now + probeLockTTL
                    state.timestamps.append(now)
                    writeState(state)
                    return
                }
            } else {
                if state.timestamps.count < effectiveMax {
                    state.timestamps.append(now)
                    writeState(state)
                    return
                }
            }

            // Sleep until either the oldest timestamp ages out OR the probe lock TTL
            // could have expired, whichever is sooner.
            let oldestAge: Double
            if let oldest = state.timestamps.first {
                oldestAge = max(0.01, period - (now - oldest))
            } else {
                oldestAge = 0.05
            }
            var sleepFor = oldestAge
            if state.rampPhase == 4, let expires = state.probeTokenExpires {
                sleepFor = min(sleepFor, max(0.05, expires - now))
            }
            try? await Task.sleep(for: .seconds(min(sleepFor, period)))
        }
    }

    public func recordRateLimit() async {
        var state = readState()
        // Snap straight to the deepest ramp on any observed 429 — we have empirical
        // evidence (2026-05-13 storm) that Image Relay does not signal Retry-After
        // and the account-level penalty lasts much longer than per-request backoff.
        state.rampPhase = 4
        state.consecutiveSuccesses = 0
        // Releasing whatever probe token we may have held; the next probe will compete
        // for the lock fresh.
        if state.probeToken == processIdentifier {
            state.probeToken = nil
            state.probeTokenExpires = nil
        }
        writeState(state)
    }

    public func recordSuccess() async {
        var state = readState()
        // Release single-probe lock if we hold it — the next request can compete.
        if state.rampPhase == 4, state.probeToken == processIdentifier {
            state.probeToken = nil
            state.probeTokenExpires = nil
        }
        guard state.rampPhase > 0 else {
            // Already at full rate — nothing to recover.
            if state.consecutiveSuccesses != 0 {
                state.consecutiveSuccesses = 0
                writeState(state)
            }
            return
        }
        state.consecutiveSuccesses += 1
        if state.consecutiveSuccesses >= recoveryHysteresis {
            state.rampPhase = max(0, state.rampPhase - 1)
            state.consecutiveSuccesses = 0
        }
        writeState(state)
    }

    /// Compute the in-window request budget at a given ramp phase. Pure function;
    /// shared with tests and APIClient's introspection paths.
    public static func effectiveMaxRequests(rampPhase: Int, fullMax: Int) -> Int {
        switch max(0, min(4, rampPhase)) {
        case 0: return fullMax
        case 1: return max(1, fullMax - 1)
        case 2: return max(1, fullMax / 2 == 0 ? 1 : fullMax - 2)
        case 3: return 1
        default: return 1
        }
    }

    /// Reads the persisted state with `NSFileCoordinator`, falling back to a
    /// best-effort direct read if coordination times out. Returns a default
    /// state when the file is missing or unparseable.
    func readState() -> SharedRateLimiterState {
        var loaded = SharedRateLimiterState()
        var coordinatedRead = false
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            guard FileManager.default.fileExists(atPath: coordinatedURL.path),
                  let data = try? Data(contentsOf: coordinatedURL),
                  let state = try? JSONDecoder().decode(SharedRateLimiterState.self, from: data) else {
                return
            }
            loaded = state
            coordinatedRead = true
        }

        if !coordinatedRead,
           FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let state = try? JSONDecoder().decode(SharedRateLimiterState.self, from: data) {
            loaded = state
        }

        return loaded
    }

    /// Best-effort write with `NSFileCoordinator`; falls through to a direct
    /// atomic write if coordination fails (the file is recoverable — at worst
    /// we'll re-read a slightly stale state on the next acquire).
    func writeState(_ state: SharedRateLimiterState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var coordinatedWriteSucceeded = false
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
                coordinatedWriteSucceeded = true
            } catch {
                coordinatedWriteSucceeded = false
            }
        }

        if !coordinatedWriteSucceeded {
            try? data.write(to: url, options: .atomic)
        }
    }
}
