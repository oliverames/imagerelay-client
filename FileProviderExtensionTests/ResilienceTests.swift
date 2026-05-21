import Foundation
import Testing
@testable import ImageRelayKit

@Suite("Resilience controls")
struct ResilienceTests {
    @Test("Remote poll delay doubles on failures with jitter")
    func pollDelayDoublesOnFailures() {
        let delay = RemoteChangePoller.pollDelay(
            baseIntervalSeconds: 60,
            consecutiveFailures: 2,
            jitterMultiplier: 1
        )

        #expect(delay == 240)
    }

    @Test("Remote poll delay caps at ten minutes after jitter")
    func pollDelayCapsAtTenMinutes() {
        let delay = RemoteChangePoller.pollDelay(
            baseIntervalSeconds: 300,
            consecutiveFailures: 4,
            jitterMultiplier: 1.5
        )

        #expect(delay == 600)
    }

    @Test("Remote poller skips when download sync is disabled or paused")
    func pollerSkipsDisabledOrPausedSync() {
        var config = AppConfiguration.default
        #expect(RemoteChangePoller.shouldSignalRemoteChanges(config: config, pauseState: .default))

        config.syncUpload = false
        #expect(RemoteChangePoller.shouldSignalRemoteChanges(config: config, pauseState: .default))

        config.syncUpload = true
        config.syncDownload = false
        #expect(!RemoteChangePoller.shouldSignalRemoteChanges(config: config, pauseState: .default))

        config.syncDownload = true
        config.fileProviderDisconnected = true
        #expect(!RemoteChangePoller.shouldSignalRemoteChanges(config: config, pauseState: .default))

        var pauseState = SyncPauseState.default
        pauseState.paused = true
        config.fileProviderDisconnected = false
        #expect(!RemoteChangePoller.shouldSignalRemoteChanges(config: config, pauseState: pauseState))
    }

    @Test("Folder update request always encodes parent id")
    func folderUpdateRequestEncodesParentID() throws {
        let request = UpdateFolderRequest(name: "Renamed", parent_id: 2_907_644)
        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["name"] as? String == "Renamed")
        #expect(object["parent_id"] as? Int == 2_907_644)
    }

    @Test("Folder delete path matches documented Image Relay endpoint")
    func folderDeletePathUsesSingularFolderEndpoint() {
        #expect(ImageRelayAPIPath.deleteFolder(2_907_644) == "/folder/2907644")
    }

    @Test("Recent 429 state delays first File Provider batch")
    func recent429DelaysFirstBatch() {
        let state = PersistedThrottleState(
            lastObserved429At: Date(timeIntervalSince1970: 1_000),
            consecutiveFailures: 4
        )

        let delay = Extension.initialThrottleDelay(
            from: state,
            now: Date(timeIntervalSince1970: 1_060)
        )

        #expect(delay == 120)
    }

    @Test("Stale 429 state does not delay first File Provider batch")
    func stale429DoesNotDelayFirstBatch() {
        let state = PersistedThrottleState(
            lastObserved429At: Date(timeIntervalSince1970: 1_000),
            consecutiveFailures: 4
        )

        let delay = Extension.initialThrottleDelay(
            from: state,
            now: Date(timeIntervalSince1970: 1_000 + 4 * 60 * 60)
        )

        #expect(delay == 0)
    }

    @Test("Startup throttle delays concurrent launch operations")
    func startupThrottleDelaysConcurrentCalls() async {
        let gate = StartupThrottleGate(delay: 0.15)

        async let firstWait = elapsedWait(for: gate)
        try? await Task.sleep(for: .milliseconds(25))
        async let secondWait = elapsedWait(for: gate)

        let waits = await (firstWait, secondWait)
        #expect(waits.0 >= 0.10)
        #expect(waits.1 >= 0.08)
    }

    private func elapsedWait(for gate: StartupThrottleGate) async -> TimeInterval {
        let startedAt = Date()
        await gate.waitIfNeeded()
        return Date().timeIntervalSince(startedAt)
    }
}
