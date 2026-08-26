import Foundation

public struct PersistedThrottleState: Codable, Equatable, Sendable {
    public var lastObserved429At: Date?
    public var consecutiveFailures: Int

    enum CodingKeys: String, CodingKey {
        case lastObserved429At
        case consecutiveFailures
    }

    public init(lastObserved429At: Date? = nil, consecutiveFailures: Int = 0) {
        self.lastObserved429At = lastObserved429At
        self.consecutiveFailures = max(0, consecutiveFailures)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastObserved429At = try container.decodeIfPresent(Date.self, forKey: .lastObserved429At)
        consecutiveFailures = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        )
    }

    public static let `default` = PersistedThrottleState()
}

public final class ThrottleStateStore: @unchecked Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func fileURL(in container: URL) -> URL {
        container.appendingPathComponent("throttle-state.json")
    }

    public func load() -> PersistedThrottleState {
        var loadedState = PersistedThrottleState.default
        var foundState = false
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            guard FileManager.default.fileExists(atPath: coordinatedURL.path),
                  let data = try? Data(contentsOf: coordinatedURL),
                  let state = try? JSONDecoder().decode(PersistedThrottleState.self, from: data) else {
                return
            }
            loadedState = state
            foundState = true
        }

        if !foundState,
           FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let state = try? JSONDecoder().decode(PersistedThrottleState.self, from: data) {
            loadedState = state
        }

        return loadedState
    }

    public func recordRateLimit(now: Date = Date()) {
        mutate { state in
            state.lastObserved429At = now
            state.consecutiveFailures += 1
        }
    }

    public func recordSuccess() {
        mutate { state in
            guard state.consecutiveFailures > 0 || state.lastObserved429At != nil else { return }
            state.consecutiveFailures = 0
        }
    }

    /// Read-modify-write performed as a single coordinated write so concurrent
    /// instances (every host service builds its own store over the same shared
    /// file) cannot clobber each other's increments. Mirrors
    /// `SharedRateLimiter.updateState`.
    private func mutate(_ update: (inout PersistedThrottleState) -> Void) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var coordinatedWriteSucceeded = false
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            var state = Self.readStateDirect(from: coordinatedURL)
            update(&state)
            coordinatedWriteSucceeded = Self.writeStateDirect(state, to: coordinatedURL)
        }

        guard !coordinatedWriteSucceeded else { return }
        var state = Self.readStateDirect(from: url)
        update(&state)
        _ = Self.writeStateDirect(state, to: url)
    }

    private static func readStateDirect(from url: URL) -> PersistedThrottleState {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PersistedThrottleState.self, from: data) else {
            return PersistedThrottleState.default
        }
        return state
    }

    @discardableResult
    private static func writeStateDirect(_ state: PersistedThrottleState, to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public func save(_ state: PersistedThrottleState) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try JSONEncoder().encode(state)
        var coordinatedWriteSucceeded = false
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)

        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
                coordinatedWriteSucceeded = true
            } catch {
                coordinatedWriteSucceeded = false
            }
        }

        if !coordinatedWriteSucceeded {
            try data.write(to: url, options: .atomic)
        }
    }
}
