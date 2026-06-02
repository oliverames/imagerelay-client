import Foundation

public struct SyncProgressState: Codable, Sendable {
    public var state: SyncState
    public var phase: String
    public var completedSteps: Int
    public var totalSteps: Int
    public var etaSeconds: Int?
    public var currentItem: String?
    public var lastError: String?
    public var lastRemotePollAt: Date?
    public var nextRemotePollAt: Date?
    public var lastSuccessfulAPIAt: Date?
    public var rateLimitedUntil: Date?
    public var rateLimitInFlight: Int
    public var recentRateLimitCount: Int
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var instantaneousBytesPerSecond: Int64
    public var smoothedBytesPerSecond: Int64
    public var lastByteSampleAt: Date?
    public var lastIncrementAt: Date?
    public var completionSampleCount: Int
    public var smoothedItemsPerSecond: Double?
    public var fileProviderPID: Int32?
    public var fileProviderStartedAt: Date?
    public var lastFileProviderSignalAt: Date?
    public var lastFileProviderSignalError: String?
    public var lastFileProviderSignalFailureCount: Int
    public var lastDatabaseIntegrityError: String?
    public var updatedAt: Date?

    public static let idle = SyncProgressState(
        state: .idle, phase: "Idle", completedSteps: 0, totalSteps: 0
    )

    public enum SyncState: String, Codable, Sendable {
        case idle, syncing, paused, error
    }

    public init(
        state: SyncState = .idle,
        phase: String = "Idle",
        completedSteps: Int = 0,
        totalSteps: Int = 0,
        etaSeconds: Int? = nil,
        currentItem: String? = nil,
        lastError: String? = nil,
        lastRemotePollAt: Date? = nil,
        nextRemotePollAt: Date? = nil,
        lastSuccessfulAPIAt: Date? = nil,
        rateLimitedUntil: Date? = nil,
        rateLimitInFlight: Int = 0,
        recentRateLimitCount: Int = 0,
        completedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        instantaneousBytesPerSecond: Int64 = 0,
        smoothedBytesPerSecond: Int64 = 0,
        lastByteSampleAt: Date? = nil,
        lastIncrementAt: Date? = nil,
        completionSampleCount: Int = 0,
        smoothedItemsPerSecond: Double? = nil,
        fileProviderPID: Int32? = nil,
        fileProviderStartedAt: Date? = nil,
        lastFileProviderSignalAt: Date? = nil,
        lastFileProviderSignalError: String? = nil,
        lastFileProviderSignalFailureCount: Int = 0,
        lastDatabaseIntegrityError: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.state = state
        self.phase = phase
        self.completedSteps = completedSteps
        self.totalSteps = totalSteps
        self.etaSeconds = etaSeconds
        self.currentItem = currentItem
        self.lastError = lastError
        self.lastRemotePollAt = lastRemotePollAt
        self.nextRemotePollAt = nextRemotePollAt
        self.lastSuccessfulAPIAt = lastSuccessfulAPIAt
        self.rateLimitedUntil = rateLimitedUntil
        self.rateLimitInFlight = max(0, rateLimitInFlight)
        self.recentRateLimitCount = max(0, recentRateLimitCount)
        self.completedBytes = max(0, completedBytes)
        self.totalBytes = max(0, totalBytes)
        self.instantaneousBytesPerSecond = max(0, instantaneousBytesPerSecond)
        self.smoothedBytesPerSecond = max(0, smoothedBytesPerSecond)
        self.lastByteSampleAt = lastByteSampleAt
        self.lastIncrementAt = lastIncrementAt
        self.completionSampleCount = max(0, completionSampleCount)
        self.smoothedItemsPerSecond = smoothedItemsPerSecond
        self.fileProviderPID = fileProviderPID
        self.fileProviderStartedAt = fileProviderStartedAt
        self.lastFileProviderSignalAt = lastFileProviderSignalAt
        self.lastFileProviderSignalError = lastFileProviderSignalError
        self.lastFileProviderSignalFailureCount = max(0, lastFileProviderSignalFailureCount)
        self.lastDatabaseIntegrityError = lastDatabaseIntegrityError
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case state, phase, completedSteps, totalSteps, etaSeconds, currentItem, lastError
        case lastRemotePollAt, nextRemotePollAt, lastSuccessfulAPIAt
        case rateLimitedUntil, rateLimitInFlight, recentRateLimitCount
        case completedBytes, totalBytes, instantaneousBytesPerSecond, smoothedBytesPerSecond
        case lastByteSampleAt, lastIncrementAt, completionSampleCount, smoothedItemsPerSecond
        case fileProviderPID, fileProviderStartedAt
        case lastFileProviderSignalAt, lastFileProviderSignalError, lastFileProviderSignalFailureCount
        case lastDatabaseIntegrityError, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(SyncState.self, forKey: .state) ?? .idle
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? "Idle"
        completedSteps = max(0, try c.decodeIfPresent(Int.self, forKey: .completedSteps) ?? 0)
        totalSteps = max(0, try c.decodeIfPresent(Int.self, forKey: .totalSteps) ?? 0)
        etaSeconds = try c.decodeIfPresent(Int.self, forKey: .etaSeconds)
        currentItem = try c.decodeIfPresent(String.self, forKey: .currentItem)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        lastRemotePollAt = try c.decodeIfPresent(Date.self, forKey: .lastRemotePollAt)
        nextRemotePollAt = try c.decodeIfPresent(Date.self, forKey: .nextRemotePollAt)
        lastSuccessfulAPIAt = try c.decodeIfPresent(Date.self, forKey: .lastSuccessfulAPIAt)
        rateLimitedUntil = try c.decodeIfPresent(Date.self, forKey: .rateLimitedUntil)
        rateLimitInFlight = max(0, try c.decodeIfPresent(Int.self, forKey: .rateLimitInFlight) ?? 0)
        recentRateLimitCount = max(0, try c.decodeIfPresent(Int.self, forKey: .recentRateLimitCount) ?? 0)
        completedBytes = max(0, try c.decodeIfPresent(Int64.self, forKey: .completedBytes) ?? 0)
        totalBytes = max(0, try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0)
        instantaneousBytesPerSecond = max(0, try c.decodeIfPresent(Int64.self, forKey: .instantaneousBytesPerSecond) ?? 0)
        smoothedBytesPerSecond = max(0, try c.decodeIfPresent(Int64.self, forKey: .smoothedBytesPerSecond) ?? 0)
        lastByteSampleAt = try c.decodeIfPresent(Date.self, forKey: .lastByteSampleAt)
        lastIncrementAt = try c.decodeIfPresent(Date.self, forKey: .lastIncrementAt)
        completionSampleCount = max(0, try c.decodeIfPresent(Int.self, forKey: .completionSampleCount) ?? 0)
        smoothedItemsPerSecond = try c.decodeIfPresent(Double.self, forKey: .smoothedItemsPerSecond)
        fileProviderPID = try c.decodeIfPresent(Int32.self, forKey: .fileProviderPID)
        fileProviderStartedAt = try c.decodeIfPresent(Date.self, forKey: .fileProviderStartedAt)
        lastFileProviderSignalAt = try c.decodeIfPresent(Date.self, forKey: .lastFileProviderSignalAt)
        lastFileProviderSignalError = try c.decodeIfPresent(String.self, forKey: .lastFileProviderSignalError)
        lastFileProviderSignalFailureCount = max(0, try c.decodeIfPresent(Int.self, forKey: .lastFileProviderSignalFailureCount) ?? 0)
        lastDatabaseIntegrityError = try c.decodeIfPresent(String.self, forKey: .lastDatabaseIntegrityError)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    public mutating func markRemotePollSucceeded(intervalSeconds: Int, now: Date = Date()) {
        if state != .syncing {
            state = .idle
            phase = "Idle"
            completedSteps = 0
            totalSteps = 0
            etaSeconds = nil
            currentItem = nil
            completedBytes = 0
            totalBytes = 0
            instantaneousBytesPerSecond = 0
            smoothedBytesPerSecond = 0
            lastByteSampleAt = nil
            lastIncrementAt = nil
            completionSampleCount = 0
            smoothedItemsPerSecond = nil
        }
        lastError = nil
        lastFileProviderSignalError = nil
        lastFileProviderSignalFailureCount = 0
        rateLimitedUntil = nil
        rateLimitInFlight = 0
        lastRemotePollAt = now
        nextRemotePollAt = now.addingTimeInterval(Double(intervalSeconds))
    }

    public mutating func markRemotePollScheduled(after intervalSeconds: TimeInterval, now: Date = Date()) {
        nextRemotePollAt = now.addingTimeInterval(max(1, intervalSeconds))
    }

    public mutating func markRemotePollFailed(_ message: String) {
        state = .error
        phase = "Error"
        currentItem = nil
        lastError = message
    }

    public mutating func markFileProviderSignalSucceeded(now: Date = Date()) {
        lastFileProviderSignalAt = now
        lastFileProviderSignalError = nil
        lastFileProviderSignalFailureCount = 0
    }

    public mutating func markFileProviderSignalFailed(_ message: String, failureCount: Int, now: Date = Date()) {
        lastFileProviderSignalAt = now
        lastFileProviderSignalError = message
        lastFileProviderSignalFailureCount = max(1, failureCount)
    }

    public mutating func markDatabaseIntegrityFailed(_ message: String) {
        state = .error
        phase = "Database Error"
        currentItem = nil
        lastError = message
        lastDatabaseIntegrityError = message
    }

    public mutating func markDatabaseIntegritySucceeded() {
        lastDatabaseIntegrityError = nil
    }
}
