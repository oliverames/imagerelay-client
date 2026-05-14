import Foundation

public actor AsyncSemaphore {
    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(value: Int) {
        self.availablePermits = max(1, value)
    }

    public func wait() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func signal() {
        guard !waiters.isEmpty else {
            availablePermits += 1
            return
        }

        let continuation = waiters.removeFirst()
        continuation.resume()
    }
}
