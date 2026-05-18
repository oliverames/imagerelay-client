import Foundation
import Testing
@testable import ImageRelayKit

@Suite("SharedRateLimiter")
struct SharedRateLimiterTests {

    private static func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageRelayKitTests")
            .appendingPathComponent("shared-rate-limiter-\(UUID().uuidString).json")
    }

    @Test("Effective max requests by ramp phase covers all phases")
    func effectiveMaxByRampPhase() {
        let full = 5
        #expect(SharedRateLimiter.effectiveMaxRequests(rampPhase: 0, fullMax: full) == 5)
        #expect(SharedRateLimiter.effectiveMaxRequests(rampPhase: 1, fullMax: full) == 4)
        #expect(SharedRateLimiter.effectiveMaxRequests(rampPhase: 2, fullMax: full) == 3)
        #expect(SharedRateLimiter.effectiveMaxRequests(rampPhase: 3, fullMax: full) == 1)
        #expect(SharedRateLimiter.effectiveMaxRequests(rampPhase: 4, fullMax: full) == 1)
        // Out-of-range values clamp into [0,4].
        #expect(SharedRateLimiter.effectiveMaxRequests(rampPhase: -5, fullMax: full) == 5)
        #expect(SharedRateLimiter.effectiveMaxRequests(rampPhase: 99, fullMax: full) == 1)
    }

    @Test("acquire stays within budget under sequential calls")
    func acquireBudget() async throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let limiter = SharedRateLimiter(url: url, maxRequests: 3, period: 0.5)
        let start = Date()
        for _ in 0..<5 { await limiter.acquire() }
        let elapsed = Date().timeIntervalSince(start)
        // 5 acquires at 3 RPS over 0.5s budget means at least one window must roll over.
        #expect(elapsed >= 0.4)
    }

    @Test("recordRateLimit pushes ramp to 4 and clears process probe")
    func recordRateLimitSnapsToFour() async throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let limiter = SharedRateLimiter(url: url, processIdentifier: "test-process")
        await limiter.recordRateLimit()
        let state = await limiter.readState()
        #expect(state.rampPhase == 4)
        #expect(state.consecutiveSuccesses == 0)
        // recordRateLimit always clears the probe token even if this process didn't hold it,
        // so a stuck lock from a prior run can never wedge the next probe attempt.
        #expect(state.probeToken == nil)
    }

    @Test("recordSuccess steps down only after hysteresis")
    func recordSuccessRequiresHysteresis() async throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let limiter = SharedRateLimiter(url: url, recoveryHysteresis: 3)

        // Seed state at phase 2.
        var seed = SharedRateLimiterState(rampPhase: 2)
        await limiter.writeState(seed)

        await limiter.recordSuccess()
        var current = await limiter.readState()
        #expect(current.rampPhase == 2)
        #expect(current.consecutiveSuccesses == 1)

        await limiter.recordSuccess()
        await limiter.recordSuccess()
        current = await limiter.readState()
        #expect(current.rampPhase == 1)
        #expect(current.consecutiveSuccesses == 0)
    }

    @Test("Probe lock TTL expiry allows a second process to steal")
    func probeLockTTLExpiry() async throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let limiter = SharedRateLimiter(
            url: url,
            probeLockTTL: 0.1,
            processIdentifier: "process-B"
        )
        // Seed: rampPhase 4 with a stale lock held by "process-A" that expired long ago.
        let stale = SharedRateLimiterState(
            timestamps: [],
            rampPhase: 4,
            probeToken: "process-A",
            probeTokenExpires: Date().timeIntervalSince1970 - 10
        )
        await limiter.writeState(stale)

        let start = Date()
        await limiter.acquire()
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.5, "Expired probe lock should be stealable immediately")

        let after = await limiter.readState()
        #expect(after.probeToken == "process-B")
    }
}
