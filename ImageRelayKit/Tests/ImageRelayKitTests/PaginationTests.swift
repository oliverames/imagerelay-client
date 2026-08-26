import Testing
@testable import ImageRelayKit

@Suite("Pagination")
struct PaginationTests {
    @Test("Parse Link header for next page URL")
    func parseLinkHeader() {
        let header = """
        <https://api.imagerelay.com/api/v2/folders.json?page=3>; rel="next", \
        <https://api.imagerelay.com/api/v2/folders.json?page=10>; rel="last"
        """
        let next = Pagination.nextURL(fromLinkHeader: header)
        #expect(next?.absoluteString == "https://api.imagerelay.com/api/v2/folders.json?page=3")
    }

    @Test("Returns nil when no next link")
    func noNextLink() {
        let header = """
        <https://api.imagerelay.com/api/v2/folders.json?page=10>; rel="last"
        """
        let next = Pagination.nextURL(fromLinkHeader: header)
        #expect(next == nil)
    }

    @Test("Accepts a next element decorated with extra parameters")
    func nextElementWithExtraParameters() {
        // RFC 8288 allows additional target attributes after rel.
        let header = "<https://api.imagerelay.com/api/v2/folders.json?page=3>; rel=\"next\"; title=\"Next page\""
        let next = Pagination.nextURL(fromLinkHeader: header)
        #expect(next?.absoluteString == "https://api.imagerelay.com/api/v2/folders.json?page=3")
    }

    @Test("Accepts unquoted rel=next")
    func unquotedRelNext() {
        let header = "<https://api.imagerelay.com/api/v2/folders.json?page=2>; rel=next"
        let next = Pagination.nextURL(fromLinkHeader: header)
        #expect(next?.absoluteString == "https://api.imagerelay.com/api/v2/folders.json?page=2")
    }

    @Test("A malformed next element does not shadow a valid later one")
    func malformedNextDoesNotShadowValidOne() {
        // An empty target (<>) yields no URL; parsing must continue to the
        // following element instead of returning nil early.
        let header = """
        <>; rel="next", \
        <https://api.imagerelay.com/api/v2/folders.json?page=5>; rel="next"
        """
        let next = Pagination.nextURL(fromLinkHeader: header)
        #expect(next?.absoluteString == "https://api.imagerelay.com/api/v2/folders.json?page=5")
    }

    @Test("Parse JSON pagination object")
    func parseJSONPagination() throws {
        let json = """
        {"current": 1, "next": "/folders?page=2", "per_page": 20, "count": 55, "pages": 3}
        """.data(using: .utf8)!
        let page = try JSONDecoder().decode(Pagination.PageInfo.self, from: json)
        #expect(page.page == 1)
        #expect(page.totalPages == 3)
        #expect(page.hasNextPage == true)
    }

    @Test("Last page has no next")
    func lastPage() throws {
        let json = """
        {"current": 3, "next": null, "per_page": 20, "count": 55, "pages": 3}
        """.data(using: .utf8)!
        let page = try JSONDecoder().decode(Pagination.PageInfo.self, from: json)
        #expect(page.hasNextPage == false)
    }
}
