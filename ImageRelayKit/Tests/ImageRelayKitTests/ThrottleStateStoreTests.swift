import Foundation
import Testing
@testable import ImageRelayKit

@Suite("ThrottleStateStore")
struct ThrottleStateStoreTests {
    func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("throttle-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Missing state loads as default")
    func missingStateLoadsDefault() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ThrottleStateStore(url: ThrottleStateStore.fileURL(in: directory))
        #expect(store.load() == .default)
    }

    @Test("Partial state decodes with defaults")
    func partialStateDecodesWithDefaults() throws {
        let data = Data("{}".utf8)

        let state = try JSONDecoder().decode(PersistedThrottleState.self, from: data)

        #expect(state == .default)
    }

    @Test("Rate limits increment persisted failures")
    func rateLimitsIncrementFailures() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_800)
        let store = ThrottleStateStore(url: ThrottleStateStore.fileURL(in: directory))
        store.recordRateLimit(now: now)
        store.recordRateLimit(now: now.addingTimeInterval(1))

        let state = store.load()
        #expect(state.lastObserved429At == now.addingTimeInterval(1))
        #expect(state.consecutiveFailures == 2)
    }

    @Test("Success clears failure count but keeps last observed 429")
    func successClearsFailures() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ThrottleStateStore(url: ThrottleStateStore.fileURL(in: directory))
        store.recordRateLimit(now: Date(timeIntervalSince1970: 1_800))
        store.recordSuccess()

        let state = store.load()
        #expect(state.lastObserved429At != nil)
        #expect(state.consecutiveFailures == 0)
    }

    @Test("Concurrent store instances over one file keep every increment")
    func concurrentInstancesKeepIncrements() async throws {
        // Host services each build their own ThrottleStateStore over the same
        // shared-container file; the coordinated read-modify-write must not
        // clobber increments the way independent load/save pairs did.
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = ThrottleStateStore.fileURL(in: directory)
        let iterationsPerStore = 25
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    let store = ThrottleStateStore(url: url)
                    for _ in 0..<iterationsPerStore {
                        store.recordRateLimit()
                    }
                }
            }
            try await group.waitForAll()
        }

        let state = ThrottleStateStore(url: url).load()
        #expect(state.consecutiveFailures == iterationsPerStore * 2)
    }
}
