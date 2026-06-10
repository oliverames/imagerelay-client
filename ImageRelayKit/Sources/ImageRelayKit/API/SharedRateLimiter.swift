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
    /// Earliest Unix-epoch timestamp when another deep-throttle probe may run.
    public var nextProbeAfter: Double?
    /// Consecutive 429 responses observed while trying to recover.
    public var consecutiveRateLimits: Int

    public init(
        timestamps: [Double] = [],
        rampPhase: Int = 0,
        consecutiveSuccesses: Int = 0,
        probeToken: String? = nil,
        probeTokenExpires: Double? = nil,
        nextProbeAfter: Double? = nil,
        consecutiveRateLimits: Int = 0
    ) {
        self.timestamps = timestamps
        self.rampPhase = max(0, min(4, rampPhase))
        self.consecutiveSuccesses = max(0, consecutiveSuccesses)
        self.probeToken = probeToken
        self.probeTokenExpires = probeTokenExpires
        self.nextProbeAfter = nextProbeAfter
        self.consecutiveRateLimits = max(0, consecutiveRateLimits)
    }

    enum CodingKeys: String, CodingKey {
        case timestamps
        case rampPhase = "ramp_phase"
        case consecutiveSuccesses = "consecutive_successes"
        case probeToken = "probe_token"
        case probeTokenExpires = "probe_token_expires"
        case nextProbeAfter = "next_probe_after"
        case consecutiveRateLimits = "consecutive_rate_limits"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamps = (try c.decodeIfPresent([Double].self, forKey: .timestamps)) ?? []
        rampPhase = max(0, min(4, try c.decodeIfPresent(Int.self, forKey: .rampPhase) ?? 0))
        consecutiveSuccesses = max(0, try c.decodeIfPresent(Int.self, forKey: .consecutiveSuccesses) ?? 0)
        probeToken = try c.decodeIfPresent(String.self, forKey: .probeToken)
        probeTokenExpires = try c.decodeIfPresent(Double.self, forKey: .probeTokenExpires)
        nextProbeAfter = try c.decodeIfPresent(Double.self, forKey: .nextProbeAfter)
        consecutiveRateLimits = max(0, try c.decodeIfPresent(Int.self, forKey: .consecutiveRateLimits) ?? 0)
    }
}

/// Cross-process rate limiter shared by the host app and File Provider extension
/// via the App Group container. Coordinates one conservative token bucket and a
/// single-probe ramp protocol so that:
///
/// - Combined throughput across both processes stays below Image Relay's documented
///   5 requests/second/IP limit with one request/second reserved as safety headroom.
/// - After a 429 in either process, both processes immediately observe the tightened
///   ramp on their next acquire (no per-process drift).
/// - During deep throttle (`rampPhase == 4`), only ONE in-flight request is allowed
///   across both processes — the single-probe pattern recommended for recovering
///   from sustained-overage cooldowns.
///
/// The state file is updated through `NSFileCoordinator` to make read-modify-write
/// safe across processes; the same coordination pattern is used by `ThrottleStateStore`.
public actor SharedRateLimiter: AsyncRateLimiting {
    private struct AcquireAttempt: Sendable {
        let acquired: Bool
        let sleepFor: Double
    }

    // Image Relay documents a hard 5 requests/second/IP ceiling. Keep one
    // request/second of headroom for timing drift, browser/API activity, and
    // other Image Relay clients on the same network.
    public static let defaultMaxRequests = 4
    public static let defaultPeriodSeconds: Double = 1.0
    /// Number of consecutive successes required before stepping ramp phase down by one.
    public static let defaultRecoveryHysteresis = 5
    /// Maximum time a single probe is allowed to hold the in-flight lock. If the
    /// holder dies without releasing, the next acquire after this elapses steals.
    public static let defaultProbeLockTTL: TimeInterval = 30
    /// First cooldown after a 429 when Image Relay omits Retry-After.
    public static let defaultRateLimitCooldownBase: TimeInterval = 15
    /// Upper bound for coordinated recovery probes after repeated 429s in the
    /// incidental tier (a short burst that trips the 5-RPS bucket).
    public static let defaultMaxRateLimitCooldown: TimeInterval = 10 * 60
    /// Consecutive 429s after which the cooldown escalates past the incidental
    /// cap into the sustained-penalty tier.
    public static let defaultSustainedRateLimitThreshold = 6
    /// Upper bound for sustained-penalty cooldowns. Image Relay's account-level
    /// penalty empirically takes ~3 hours of cumulative silence to clear
    /// (2026-05-13 storm data), so probing every 10 minutes wastes budget
    /// without advancing recovery.
    public static let defaultSustainedMaxCooldown: TimeInterval = 3 * 60 * 60
    /// Sanity ceiling for server-provided cooldown hints (a daily limit resets
    /// within 24 hours by definition).
    public static let maxServerCooldownHint: TimeInterval = 24 * 60 * 60

    let url: URL
    let maxRequests: Int
    let period: Double
    let recoveryHysteresis: Int
    let probeLockTTL: TimeInterval
    let rateLimitCooldownBase: TimeInterval
    let maxRateLimitCooldown: TimeInterval
    let sustainedRateLimitThreshold: Int
    let sustainedMaxCooldown: TimeInterval
    let processIdentifier: String
    private var activeProbeToken: String?

    public init(
        url: URL,
        maxRequests: Int = SharedRateLimiter.defaultMaxRequests,
        period: Double = SharedRateLimiter.defaultPeriodSeconds,
        recoveryHysteresis: Int = SharedRateLimiter.defaultRecoveryHysteresis,
        probeLockTTL: TimeInterval = SharedRateLimiter.defaultProbeLockTTL,
        rateLimitCooldownBase: TimeInterval = SharedRateLimiter.defaultRateLimitCooldownBase,
        maxRateLimitCooldown: TimeInterval = SharedRateLimiter.defaultMaxRateLimitCooldown,
        sustainedRateLimitThreshold: Int = SharedRateLimiter.defaultSustainedRateLimitThreshold,
        sustainedMaxCooldown: TimeInterval = SharedRateLimiter.defaultSustainedMaxCooldown,
        processIdentifier: String = UUID().uuidString
    ) {
        self.url = url
        self.maxRequests = max(1, maxRequests)
        self.period = max(0.1, period)
        self.recoveryHysteresis = max(1, recoveryHysteresis)
        self.probeLockTTL = max(1.0, probeLockTTL)
        self.rateLimitCooldownBase = max(0.1, rateLimitCooldownBase)
        self.maxRateLimitCooldown = max(self.rateLimitCooldownBase, maxRateLimitCooldown)
        self.sustainedRateLimitThreshold = max(1, sustainedRateLimitThreshold)
        self.sustainedMaxCooldown = max(self.maxRateLimitCooldown, sustainedMaxCooldown)
        self.processIdentifier = processIdentifier
    }

    public static func fileURL(in container: URL) -> URL {
        container.appendingPathComponent("rate-limiter-state.json")
    }

    public func acquire() async {
        while true {
            try? Task.checkCancellation()

            let now = Date().timeIntervalSince1970
            let attempt = updateState { state in
                // Prune timestamps outside the rolling window.
                let cutoff = now - period
                state.timestamps = state.timestamps.filter { $0 >= cutoff }

                let effectiveMax = Self.effectiveMaxRequests(
                    rampPhase: state.rampPhase,
                    fullMax: maxRequests
                )
                let cooldownWait = state.nextProbeAfter.map { max(0, $0 - now) } ?? 0
                let windowIsFull = state.timestamps.count >= effectiveMax

                if state.rampPhase == 4 {
                    if let activeProbeToken {
                        let tokenStillLeased = state.probeToken == activeProbeToken
                            && (state.probeTokenExpires ?? 0) > now
                        if !tokenStillLeased {
                            self.activeProbeToken = nil
                        }
                    }
                    // Single-probe lock semantics: one in-flight request total. If
                    // the previous holder's lease has expired, grab it; otherwise wait until
                    // the next chance. The same actor is not allowed to reacquire while
                    // its previous probe is still awaiting an API outcome.
                    let lockIsFree: Bool
                    if state.probeToken != nil {
                        if let expires = state.probeTokenExpires, expires < now {
                            // Stale lease — steal.
                            lockIsFree = true
                        } else {
                            lockIsFree = false
                        }
                    } else {
                        lockIsFree = true
                    }

                    if cooldownWait <= 0, lockIsFree, !windowIsFull, activeProbeToken == nil {
                        let token = "\(processIdentifier):\(UUID().uuidString)"
                        activeProbeToken = token
                        state.probeToken = token
                        state.probeTokenExpires = now + probeLockTTL
                        state.nextProbeAfter = nil
                        state.timestamps.append(now)
                        return AcquireAttempt(acquired: true, sleepFor: 0)
                    }
                } else {
                    if cooldownWait <= 0, !windowIsFull {
                        state.nextProbeAfter = nil
                        state.timestamps.append(now)
                        return AcquireAttempt(acquired: true, sleepFor: 0)
                    }
                }

                var sleepCandidates: [Double] = []
                if cooldownWait > 0 {
                    sleepCandidates.append(cooldownWait)
                }
                if windowIsFull, let oldest = state.timestamps.first {
                    sleepCandidates.append(max(0.01, period - (now - oldest)))
                }
                if state.rampPhase == 4, activeProbeToken != nil {
                    sleepCandidates.append(0.05)
                } else if state.rampPhase == 4,
                          let expires = state.probeTokenExpires,
                          expires > now {
                    sleepCandidates.append(max(0.05, expires - now))
                }
                return AcquireAttempt(acquired: false, sleepFor: sleepCandidates.min() ?? 0.05)
            }

            if attempt.acquired {
                return
            }
            try? await Task.sleep(for: .seconds(attempt.sleepFor))
        }
    }

    public func recordRateLimit(retryAfter: TimeInterval?) async {
        updateState { state in
            let now = Date().timeIntervalSince1970
            // Tighten gradually so one incidental 429 does not collapse the whole
            // client into single-probe mode. Repeated 429s still converge quickly
            // to phase 4, where only one cross-process recovery probe is allowed.
            state.rampPhase = min(4, max(state.rampPhase, state.consecutiveRateLimits + 1))
            state.consecutiveSuccesses = 0
            state.consecutiveRateLimits = min(state.consecutiveRateLimits + 1, 20)
            state.nextProbeAfter = now + Self.rateLimitCooldown(
                consecutiveRateLimits: state.consecutiveRateLimits,
                base: rateLimitCooldownBase,
                maximum: maxRateLimitCooldown,
                sustainedThreshold: sustainedRateLimitThreshold,
                sustainedMaximum: sustainedMaxCooldown,
                retryAfter: retryAfter
            )
            // Releasing whatever probe token we may have held; the next probe will compete
            // for the lock fresh.
            if let activeProbeToken, state.probeToken == activeProbeToken {
                state.probeToken = nil
                state.probeTokenExpires = nil
                self.activeProbeToken = nil
            }
        }
    }

    public func recordSuccess() async {
        updateState { state in
            let now = Date().timeIntervalSince1970
            let hadRecoveryState = state.consecutiveRateLimits != 0 || state.nextProbeAfter != nil
            let cooldownStillActive = state.nextProbeAfter.map { $0 > now } ?? false
            let holdsActiveProbe = state.rampPhase == 4
                && activeProbeToken != nil
                && state.probeToken == activeProbeToken

            if cooldownStillActive && !holdsActiveProbe {
                // This success belongs to a request that was already in flight when
                // another request hit a 429. Do not let stale successes reopen the
                // bucket before the coordinated cooldown expires.
                if activeProbeToken != nil {
                    activeProbeToken = nil
                }
                return
            }

            if state.rampPhase == 4 && !holdsActiveProbe {
                // A success from a request that was already in flight before another
                // process observed a 429 must not clear the shared cooldown.
                if activeProbeToken != nil {
                    activeProbeToken = nil
                }
                return
            }

            // Release single-probe lock if we hold it — the next request can compete.
            if holdsActiveProbe {
                state.probeToken = nil
                state.probeTokenExpires = nil
                self.activeProbeToken = nil
            }
            state.consecutiveRateLimits = 0
            state.nextProbeAfter = nil
            guard state.rampPhase > 0 else {
                // Already at full rate — nothing to recover.
                if state.consecutiveSuccesses != 0 || hadRecoveryState {
                    state.consecutiveSuccesses = 0
                }
                return
            }
            state.consecutiveSuccesses += 1
            if state.consecutiveSuccesses >= recoveryHysteresis {
                state.rampPhase = max(0, state.rampPhase - 1)
                state.consecutiveSuccesses = 0
            }
        }
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

    public static func rateLimitCooldown(
        consecutiveRateLimits: Int,
        base: TimeInterval = SharedRateLimiter.defaultRateLimitCooldownBase,
        maximum: TimeInterval = SharedRateLimiter.defaultMaxRateLimitCooldown,
        sustainedThreshold: Int = SharedRateLimiter.defaultSustainedRateLimitThreshold,
        sustainedMaximum: TimeInterval = SharedRateLimiter.defaultSustainedMaxCooldown,
        retryAfter: TimeInterval? = nil
    ) -> TimeInterval {
        let failures = max(1, consecutiveRateLimits)
        let computed: TimeInterval
        if failures <= sustainedThreshold {
            // Incidental tier: short exponential schedule for a burst that
            // tripped the per-second bucket.
            let exponent = min(failures - 1, 10)
            computed = min(base * pow(2.0, Double(exponent)), maximum)
        } else {
            // Sustained tier: 429s persisting past the incidental schedule mean
            // the account is in Image Relay's penalty box, which clears only
            // after hours of cumulative silence. Keep doubling from the
            // incidental cap toward the multi-hour ceiling.
            let exponent = min(failures - sustainedThreshold, 10)
            computed = min(maximum * pow(2.0, Double(exponent)), sustainedMaximum)
        }
        // A server-provided hint (Retry-After header or daily-limit reset
        // interval) overrides the client-side schedule when it is longer.
        if let retryAfter, retryAfter > computed {
            return min(retryAfter, maxServerCooldownHint)
        }
        return computed
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
            loaded = Self.readStateDirect(from: coordinatedURL)
            coordinatedRead = true
        }

        if !coordinatedRead {
            loaded = Self.readStateDirect(from: url)
        }

        return loaded
    }

    /// Best-effort write with `NSFileCoordinator`; falls through to a direct
    /// atomic write if coordination fails (the file is recoverable — at worst
    /// we'll re-read a slightly stale state on the next acquire).
    func writeState(_ state: SharedRateLimiterState) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var coordinatedWriteSucceeded = false
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            coordinatedWriteSucceeded = Self.writeStateDirect(state, to: coordinatedURL)
        }

        if !coordinatedWriteSucceeded {
            _ = Self.writeStateDirect(state, to: url)
        }
    }

    @discardableResult
    private func updateState<T>(_ update: (inout SharedRateLimiterState) -> T) -> T {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var result: T?
        var coordinatedWriteSucceeded = false
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            var state = Self.readStateDirect(from: coordinatedURL)
            let updateResult = update(&state)
            coordinatedWriteSucceeded = Self.writeStateDirect(state, to: coordinatedURL)
            if coordinatedWriteSucceeded {
                result = updateResult
            }
        }

        if let result {
            return result
        }

        var state = Self.readStateDirect(from: url)
        let updateResult = update(&state)
        _ = Self.writeStateDirect(state, to: url)
        return updateResult
    }

    private static func readStateDirect(from url: URL) -> SharedRateLimiterState {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SharedRateLimiterState.self, from: data) else {
            return SharedRateLimiterState()
        }
        return state
    }

    private static func writeStateDirect(_ state: SharedRateLimiterState, to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
