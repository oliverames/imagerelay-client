import Foundation

public struct SyncPauseState: Codable, Sendable {
    public var paused: Bool
    public var until: Date?
    public var updatedAt: Date?

    public static let `default` = SyncPauseState(paused: false, until: nil, updatedAt: nil)

    public var isActive: Bool {
        guard paused else { return false }
        guard let until else { return true }  // indefinite
        return until > Date()
    }

    public var remainingSeconds: Int? {
        guard let until else { return nil }
        return max(Int(until.timeIntervalSinceNow), 0)
    }

    public var description: String {
        guard paused else { return "Syncing is active." }
        guard let until else { return "Paused until you resume." }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "Paused until \(formatter.string(from: until))"
    }

    public static func deadline(for choice: PauseDuration) -> Date? {
        switch choice {
        case .thirtyMinutes: return Date().addingTimeInterval(30 * 60)
        case .oneHour: return Date().addingTimeInterval(60 * 60)
        case .untilTomorrow9AM:
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
            return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        case .indefinite: return nil
        }
    }
}

public enum PauseDuration: Sendable {
    case thirtyMinutes
    case oneHour
    case untilTomorrow9AM
    case indefinite
}
