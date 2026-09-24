#!/usr/bin/env python3
"""Compile the actual folder-membership state with isolated environment doubles.

No app-group, Keychain, File Provider domain, or network calls are possible.
SwiftUI rendering is intentionally outside this state-machine fixture.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'ImageRelayClient/Collections/FolderMembershipView.swift').read_text()
state = source[source.index('@Observable @MainActor'):source.index('struct FolderMembershipView: View')]
stubs = r'''
import Foundation
import Observation

struct RemoteFolder { let id: Int; let name: String }
struct Detail { let folderIDs: [Int] }
struct Pause { let isActive: Bool; let description: String }
@MainActor enum Fixture {
    static var config = AppConfiguration()
    static var paused = false
    static var writes: [Int] = []
    static var duringWrite: (() -> Void)?
    static var duringLoad: (() -> Void)?
    static var duringRead: (() -> Void)?
    static func reset() {
        config = AppConfiguration(); paused = false; writes = []
        duringWrite = nil; duringLoad = nil; duringRead = nil
    }
}
struct AppConfiguration {
    var credential = "fixture-account-A"
    var baseURL = URL(string: "https://fixture.invalid")!
    var syncUpload = true
    var isConfigured: Bool { !credential.isEmpty }
    static func containerURL() -> URL? { URL(fileURLWithPath: "/unused-fixture") }
    static func fileURL(in container: URL) -> URL { container }
    @MainActor static func load(from url: URL) throws -> Self { Fixture.config }
    static let currentServiceUserAgent = "fixture"
    static func sharedOrPerProcessRateLimiter() -> Int { 0 }
    static func sharedThrottleStateStore() -> Int { 0 }
}
struct APIClient {
    init(baseURL: URL, credential: String, userAgent: String, rateLimiter: Int, throttleStateStore: Int) {}
    @MainActor func getAllPages(_ path: String) async throws -> [RemoteFolder] {
        Fixture.duringLoad?()
        return [RemoteFolder(id: 101, name: "First"), RemoteFolder(id: 202, name: "Second")]
    }
}
struct SyncDatabase {
    init(url: URL) throws {}
    static func databaseURL(in container: URL) -> URL { container }
    @MainActor func getPauseState() throws -> Pause? { Fixture.paused ? Pause(isActive: true, description: "Paused") : nil }
}
struct ImageRelayAPI {
    let client: APIClient
    @MainActor func addSyncedFileMemberships(fileID: Int, folderIDs: [Int], beforeWrite: @Sendable () async throws -> Void = {}) async throws -> Detail {
        Fixture.duringRead?()
        try await beforeWrite()
        Fixture.writes.append(fileID)
        Fixture.duringWrite?()
        return Detail(folderIDs: folderIDs)
    }
}
enum CollectionsService { enum ServiceError: Error { case notConfigured } }
struct NSFileProviderItemIdentifier {
    init(_ raw: String) {}
    static let workingSet = Self("workingSet")
    static let rootContainer = Self("root")
}
struct NSFileProviderDomain { init(identifier: String, displayName: String) {} }
enum DomainManager { static let domainIdentifier = "fixture"; static let domainDisplayName = "Fixture" }
struct NSFileProviderManager {
    init?(for domain: NSFileProviderDomain) { return nil }
    func signalEnumerator(for identifier: NSFileProviderItemIdentifier) async throws {}
}
struct ItemIdentifier { let rawValue: String; static func folder(_ id: Int) -> Self { Self(rawValue: "folder-\(id)") } }
'''
checks = r'''
@main struct MembershipStateChecks {
    @MainActor static func prepared() async -> FolderMembershipState {
        Fixture.reset()
        let state = FolderMembershipState()
        state.setTargets([7, 8])
        await state.load()
        state.selected = [101]
        return state
    }
    @MainActor static func main() async {
        var state = await prepared()
        await state.add()
        precondition(Fixture.writes == [7, 8]); print("PASS normal batch")

        state = await prepared()
        Fixture.config.credential = "fixture-account-B"
        await state.add()
        precondition(Fixture.writes.isEmpty && state.fileIDs.isEmpty && state.selected.isEmpty)
        print("PASS changed credential blocks stale selection")

        state = await prepared()
        Fixture.config.baseURL = URL(string: "https://other.invalid")!
        await state.add()
        precondition(Fixture.writes.isEmpty); print("PASS changed tenant blocks stale selection")

        state = await prepared()
        Fixture.duringWrite = { Fixture.paused = true }
        await state.add()
        precondition(Fixture.writes == [7] && state.message!.contains("1 of 2"))
        print("PASS pause stops remaining batch and reports partial result")

        state = await prepared()
        Fixture.duringWrite = { Fixture.config.syncUpload = false }
        await state.add()
        precondition(Fixture.writes == [7]); print("PASS disabled upload stops remaining batch")

        state = await prepared()
        Fixture.duringWrite = { Fixture.config.credential = "fixture-account-B" }
        await state.add()
        precondition(Fixture.writes == [7]); print("PASS account switch stops remaining batch")

        state = await prepared()
        let running = state
        Fixture.duringWrite = { running.setTargets([99]) }
        await state.add()
        precondition(Fixture.writes == [7, 8] && state.fileIDs == [7, 8])
        print("PASS incoming action cannot replace active batch targets")

        state = await prepared()
        Fixture.duringLoad = { Fixture.config.credential = "fixture-account-B" }
        await state.load()
        precondition(state.fileIDs.isEmpty && state.folders.isEmpty && state.selected.isEmpty)
        print("PASS account switch during folder load discards stale list")

        state = await prepared()
        let loading = state
        Fixture.duringLoad = { loading.setTargets([99]) }
        await state.load()
        precondition(state.fileIDs == [99] && state.folders.count == 2)
        print("PASS incoming action during folder load is retained")

        state = await prepared()
        Fixture.duringRead = { Fixture.paused = true }
        await state.add()
        precondition(Fixture.writes.isEmpty); print("PASS pause during preflight prevents POST")

        state = await prepared()
        Fixture.duringRead = { Fixture.config.credential = "fixture-account-B" }
        await state.add()
        precondition(Fixture.writes.isEmpty); print("PASS changed account during preflight prevents POST")

        state = await prepared()
        state.selected = [999]
        await state.add()
        precondition(Fixture.writes.isEmpty); print("PASS unknown destination rejected")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='membership-state-') as tmp:
    fixture = Path(tmp) / 'fixture.swift'
    fixture.write_text(stubs + state + checks)
    executable = Path(tmp) / 'fixture'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(Path(tmp) / 'modules'), str(fixture), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
