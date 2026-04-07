import Foundation

public struct QuickLink: Codable, Sendable, Identifiable {
    public let id: Int
    public let uid: String
    public let url: URL
    public let purpose: String?

    public init(id: Int, uid: String, url: URL, purpose: String? = nil) {
        self.id = id
        self.uid = uid
        self.url = url
        self.purpose = purpose
    }
}
