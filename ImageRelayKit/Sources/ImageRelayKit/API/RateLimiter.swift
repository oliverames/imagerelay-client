import Foundation

public actor RateLimiter {
    private let maxRequests: Int
    private let period: Duration
    private var timestamps: [ContinuousClock.Instant] = []

    public init(maxRequests: Int = 5, period: Double = 1.0) {
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
}
