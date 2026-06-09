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

    @Test("Default budget leaves headroom below Image Relay's five RPS IP cap")
    func defaultBudgetLeavesHeadroom() {
        #expect(SharedRateLimiter.defaultMaxRequests == 4)
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

    @Test("recordRateLimit tightens gradually and clears process probe")
    func recordRateLimitTightensGradually() async throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let limiter = SharedRateLimiter(url: url, processIdentifier: "test-process")

        await limiter.recordRateLimit()
        var state = await limiter.readState()
        #expect(state.rampPhase == 1)
        #expect(state.consecutiveSuccesses == 0)
        // No in-flight probe was held, so recording the 429 should not create a lock.
        #expect(state.probeToken == nil)

        await limiter.recordRateLimit()
        await limiter.recordRateLimit()
        await limiter.recordRateLimit()
        state = await limiter.readState()
        #expect(state.rampPhase == 4)
        #expect(state.consecutiveRateLimits == 4)
    }

    @Test("recordSuccess steps down only after hysteresis")
    func recordSuccessRequiresHysteresis() async throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let limiter = SharedRateLimiter(url: url, recoveryHysteresis: 3)

        // Seed state at phase 2.
        let seed = SharedRateLimiterState(rampPhase: 2)
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
        #expect(after.probeToken?.hasPrefix("process-B:") == true)
    }

    @Test("Phase 4 does not allow the same limiter to reacquire while a probe is in flight")
    func phaseFourBlocksReentrantAcquireUntilOutcomeRecorded() async throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let limiter = SharedRateLimiter(
            url: url,
            maxRequests: 1,
            period: 0.1,
            probeLockTTL: 5,
            processIdentifier: "process-A"
        )
        await limiter.writeState(SharedRateLimiterState(rampPhase: 4))

        await limiter.acquire()

        let flag = CompletionFlag()
        let secondAcquire = Task {
            await limiter.acquire()
            await flag.markCompleted()
        }
        defer { secondAcquire.cancel() }

        try await Task.sleep(for: .milliseconds(100))
        #expect(await flag.isCompleted == false)

        await limiter.recordSuccess()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await flag.isCompleted == true)
        await limiter.recordSuccess()
    }

    @Test("429 cooldown gates the next phase 4 probe across limiter instances")
    func rateLimitCooldownGatesQueuedProbes() async throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = SharedRateLimiter(
            url: url,
            maxRequests: 1,
            period: 0.1,
            rateLimitCooldownBase: 0.4,
            maxRateLimitCooldown: 0.4,
            processIdentifier: "process-A"
        )
        let second = SharedRateLimiter(
            url: url,
            maxRequests: 1,
            period: 0.1,
            rateLimitCooldownBase: 0.4,
            maxRateLimitCooldown: 0.4,
            processIdentifier: "process-B"
        )
        await first.writeState(SharedRateLimiterState(rampPhase: 4))

        await first.acquire()
        await first.recordRateLimit()

        let flag = CompletionFlag()
        let queuedProbe = Task {
            await second.acquire()
            await flag.markCompleted()
        }
        defer { queuedProbe.cancel() }

        try await Task.sleep(for: .milliseconds(150))
        #expect(await flag.isCompleted == false)

        try await Task.sleep(for: .milliseconds(350))
        #expect(await flag.isCompleted == true)
        await second.recordSuccess()
    }

    @Test("Expired local phase 4 probe does not wedge later acquires")
    func expiredLocalProbeDoesNotWedgeAcquire() async throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let limiter = SharedRateLimiter(
            url: url,
            maxRequests: 1,
            period: 0.1,
            probeLockTTL: 0.1,
            processIdentifier: "process-A"
        )
        await limiter.writeState(SharedRateLimiterState(rampPhase: 4))
        await limiter.acquire()

        let heldToken = await limiter.readState().probeToken
        await limiter.writeState(SharedRateLimiterState(
            rampPhase: 4,
            probeToken: heldToken,
            probeTokenExpires: Date().timeIntervalSince1970 - 1
        ))

        let flag = CompletionFlag()
        let nextAcquire = Task {
            await limiter.acquire()
            await flag.markCompleted()
        }
        defer { nextAcquire.cancel() }

        try await Task.sleep(for: .milliseconds(150))
        #expect(await flag.isCompleted == true)
        await limiter.recordSuccess()
    }

    @Test("Pre-throttle success does not clear phase 4 cooldown")
    func staleSuccessDoesNotClearCooldown() async throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let limiter = SharedRateLimiter(
            url: url,
            processIdentifier: "process-A"
        )
        let cooldownUntil = Date().timeIntervalSince1970 + 60
        await limiter.writeState(SharedRateLimiterState(
            rampPhase: 4,
            consecutiveSuccesses: 0,
            nextProbeAfter: cooldownUntil,
            consecutiveRateLimits: 2
        ))

        await limiter.recordSuccess()

        let state = await limiter.readState()
        #expect(state.rampPhase == 4)
        #expect(state.consecutiveSuccesses == 0)
        #expect(state.nextProbeAfter == cooldownUntil)
        #expect(state.consecutiveRateLimits == 2)
    }

    @Test("Pre-throttle success does not clear partial cooldown")
    func staleSuccessDoesNotClearPartialCooldown() async throws {
        let url = Self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let limiter = SharedRateLimiter(url: url, processIdentifier: "process-A")
        let cooldownUntil = Date().timeIntervalSince1970 + 60
        await limiter.writeState(SharedRateLimiterState(
            rampPhase: 2,
            consecutiveSuccesses: 0,
            nextProbeAfter: cooldownUntil,
            consecutiveRateLimits: 1
        ))

        await limiter.recordSuccess()

        let state = await limiter.readState()
        #expect(state.rampPhase == 2)
        #expect(state.consecutiveSuccesses == 0)
        #expect(state.nextProbeAfter == cooldownUntil)
        #expect(state.consecutiveRateLimits == 1)
    }
}

private actor CompletionFlag {
    private var completed = false

    var isCompleted: Bool { completed }

    func markCompleted() {
        completed = true
    }
}
