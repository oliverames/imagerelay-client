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
        self.updatedAt = updatedAt
    }
}
