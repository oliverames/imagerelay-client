import Foundation

/// Minimal view of `GET /users/me.json`. The Image Relay API surfaces a richer
/// payload (permissions, group ID, etc.); we only model the org subdomain
/// because that is the one piece the client needs in order to construct the
/// account's web URL for actions like "Open Folder in Image Relay Web".
public struct UserInfo: Decodable, Sendable, Equatable {
    public let id: Int?
    public let subdomain: Subdomain

    public struct Subdomain: Decodable, Sendable, Equatable {
        /// Bare host like `bluecrossvt.imagerelay.com`.
        public let domainWithSubDomain: String?
        /// Fully-qualified web base URL like `https://bluecrossvt.imagerelay.com`.
        public let httpBase: URL?

        enum CodingKeys: String, CodingKey {
            case domainWithSubDomain = "domain_with_sub_domain"
            case httpBase = "http_base"
        }

        public init(domainWithSubDomain: String?, httpBase: URL?) {
            self.domainWithSubDomain = domainWithSubDomain
            self.httpBase = httpBase
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            domainWithSubDomain = try c.decodeIfPresent(String.self, forKey: .domainWithSubDomain)
            if let raw = try c.decodeIfPresent(String.self, forKey: .httpBase),
               let url = URL(string: raw) {
                httpBase = url
            } else {
                httpBase = nil
            }
        }
    }

    public init(id: Int?, subdomain: Subdomain) {
        self.id = id
        self.subdomain = subdomain
    }
}
