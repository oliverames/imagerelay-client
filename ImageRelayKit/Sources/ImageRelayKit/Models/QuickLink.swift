import Foundation

public struct QuickLink: Codable, Sendable, Identifiable {
    public let id: Int
    public let uid: String
    public let url: URL
    public let purpose: String?
    public let createdOn: String?

    enum CodingKeys: String, CodingKey {
        case id
        case uid
        case url
        case quickLinkURL = "quick_link_url"
        case purpose
        case createdOn = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        uid = try c.decodeIfPresent(String.self, forKey: .uid) ?? ""
        let urlString = try c.decodeIfPresent(String.self, forKey: .url)
            ?? c.decodeIfPresent(String.self, forKey: .quickLinkURL)
            ?? ""
        url = URL(string: urlString) ?? URL(string: "about:blank")!
        purpose = try c.decodeIfPresent(String.self, forKey: .purpose)
        createdOn = try c.decodeIfPresent(String.self, forKey: .createdOn)
    }

    public init(id: Int, uid: String, url: URL, purpose: String? = nil, createdOn: String? = nil) {
        self.id = id
        self.uid = uid
        self.url = url
        self.purpose = purpose
        self.createdOn = createdOn
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(uid, forKey: .uid)
        try c.encode(url, forKey: .url)
        try c.encodeIfPresent(purpose, forKey: .purpose)
        try c.encodeIfPresent(createdOn, forKey: .createdOn)
    }
}
