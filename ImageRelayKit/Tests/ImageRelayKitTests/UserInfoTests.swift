import Testing
import Foundation
@testable import ImageRelayKit

@Suite("UserInfo decoding")
struct UserInfoTests {
    /// Pinned against the actual `/users/me.json` shape captured live on
    /// 2026-05-17 from the BCBSVT account during 1.2.1 development. Only the
    /// fields we model (`id`, `subdomain.domain_with_sub_domain`,
    /// `subdomain.http_base`) are exercised here — the API also returns
    /// `login`, `email`, `permissions`, etc., which are deliberately ignored
    /// because the desktop client has no use for them.
    @Test("Decodes /users/me.json with subdomain block")
    func decodesUsersMe() throws {
        let json = """
        {
            "id": 274329,
            "login": "ameso",
            "email": "ameso@example.com",
            "permissions": [],
            "subdomain": {
                "domain_with_sub_domain": "bluecrossvt.imagerelay.com",
                "http_base": "https://bluecrossvt.imagerelay.com"
            }
        }
        """
        let info = try JSONDecoder.imageRelay.decode(UserInfo.self, from: Data(json.utf8))
        #expect(info.id == 274329)
        #expect(info.subdomain.domainWithSubDomain == "bluecrossvt.imagerelay.com")
        #expect(info.subdomain.httpBase?.absoluteString == "https://bluecrossvt.imagerelay.com")
    }

    @Test("Missing http_base decodes as nil rather than failing")
    func missingHTTPBaseIsNil() throws {
        let json = """
        {
            "id": 1,
            "subdomain": {
                "domain_with_sub_domain": "example.imagerelay.com"
            }
        }
        """
        let info = try JSONDecoder.imageRelay.decode(UserInfo.self, from: Data(json.utf8))
        #expect(info.subdomain.httpBase == nil)
        #expect(info.subdomain.domainWithSubDomain == "example.imagerelay.com")
    }

    @Test("Malformed http_base string decodes as nil")
    func malformedHTTPBaseIsNil() throws {
        let json = """
        {
            "subdomain": {
                "http_base": ""
            }
        }
        """
        let info = try JSONDecoder.imageRelay.decode(UserInfo.self, from: Data(json.utf8))
        #expect(info.subdomain.httpBase == nil)
    }
}
