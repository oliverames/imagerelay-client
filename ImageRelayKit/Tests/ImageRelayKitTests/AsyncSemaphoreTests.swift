import Testing
@testable import ImageRelayKit

@Suite("AsyncSemaphore")
struct AsyncSemaphoreTests {
    actor Counter {
        var current = 0
        var maximum = 0

        func enter() {
            current += 1
            maximum = max(maximum, current)
        }

        func leave() {
            current -= 1
        }
    }

    @Test("Limits concurrent access")
    func limitsConcurrentAccess() async {
        let semaphore = AsyncSemaphore(value: 2)
        let counter = Counter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await semaphore.wait()
                    await counter.enter()
                    try? await Task.sleep(for: .milliseconds(20))
                    await counter.leave()
                    await semaphore.signal()
                }
            }
        }

        #expect(await counter.maximum == 2)
    }
}
