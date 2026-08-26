import Testing
@testable import ImageRelayKit

@Suite("Rate Limiter")
struct RateLimiterTests {
    @Test("Allows requests within limit")
    func allowsWithinLimit() async throws {
        let limiter = RateLimiter(maxRequests: 3, period: 1.0)
        let start = ContinuousClock.now
        for _ in 0..<3 {
            try await limiter.acquire()
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(100))
    }

    @Test("Throttles when exceeding limit")
    func throttlesOverLimit() async throws {
        let limiter = RateLimiter(maxRequests: 2, period: 0.5)
        try await limiter.acquire()
        try await limiter.acquire()
        let start = ContinuousClock.now
        try await limiter.acquire()
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(400))
    }

    @Test("Acquire throws when the task is cancelled while waiting")
    func acquirePropagatesCancellation() async throws {
        let limiter = RateLimiter(maxRequests: 1, period: 5.0)
        try await limiter.acquire()
        let task = Task {
            try await limiter.acquire()
        }
        // Give the task a moment to enter its wait, then cancel it.
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected acquire() to throw CancellationError")
        } catch is CancellationError {
            // Expected.
        }
    }
}
