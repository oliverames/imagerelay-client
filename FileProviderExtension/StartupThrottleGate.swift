import Foundation

actor StartupThrottleGate {
    private var readyAt: Date?

    init(delay: TimeInterval) {
        readyAt = delay > 0 ? Date().addingTimeInterval(delay) : nil
    }

    func waitIfNeeded() async {
        guard let readyAt else { return }

        let delay = readyAt.timeIntervalSinceNow
        guard delay > 0 else {
            self.readyAt = nil
            return
        }

        try? await Task.sleep(for: .seconds(delay))
        if Date() >= readyAt {
            self.readyAt = nil
        }
    }
}
