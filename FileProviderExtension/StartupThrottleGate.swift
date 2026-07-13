import Foundation

actor StartupThrottleGate {
    private var readyAt: Date?

    init(delay: TimeInterval) {
        readyAt = delay > 0 ? Date().addingTimeInterval(delay) : nil
    }

    func waitIfNeeded() async {
        guard let readyAt else { return }

        let delay = remainingDelay(at: Date())
        guard delay > 0 else {
            self.readyAt = nil
            return
        }

        try? await Task.sleep(for: .seconds(delay))
        if Date() >= readyAt {
            self.readyAt = nil
        }
    }

    func remainingDelay(at now: Date) -> TimeInterval {
        guard let readyAt else { return 0 }
        return max(0, readyAt.timeIntervalSince(now))
    }
}
