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

    @Test("Parse JSON pagination object")
    func parseJSONPagination() throws {
        let json = """
        {"page": 1, "per_page": 20, "total_entries": 55, "total_pages": 3}
        """.data(using: .utf8)!
        let page = try JSONDecoder().decode(Pagination.PageInfo.self, from: json)
        #expect(page.page == 1)
        #expect(page.totalPages == 3)
        #expect(page.hasNextPage == true)
    }

    @Test("Last page has no next")
    func lastPage() throws {
        let json = """
        {"page": 3, "per_page": 20, "total_entries": 55, "total_pages": 3}
        """.data(using: .utf8)!
        let page = try JSONDecoder().decode(Pagination.PageInfo.self, from: json)
        #expect(page.hasNextPage == false)
    }
}
