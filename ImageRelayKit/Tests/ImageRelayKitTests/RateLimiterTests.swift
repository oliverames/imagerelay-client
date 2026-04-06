import Testing
@testable import ImageRelayKit

@Suite("Rate Limiter")
struct RateLimiterTests {
    @Test("Allows requests within limit")
    func allowsWithinLimit() async {
        let limiter = RateLimiter(maxRequests: 3, period: 1.0)
        let start = ContinuousClock.now
        for _ in 0..<3 {
            await limiter.acquire()
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(100))
    }

    @Test("Throttles when exceeding limit")
    func throttlesOverLimit() async {
        let limiter = RateLimiter(maxRequests: 2, period: 0.5)
        await limiter.acquire()
        await limiter.acquire()
        let start = ContinuousClock.now
        await limiter.acquire()
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(400))
    }
}
