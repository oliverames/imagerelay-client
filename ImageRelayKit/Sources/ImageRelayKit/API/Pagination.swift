import Foundation

public enum Pagination {
    public struct PageInfo: Codable, Sendable {
        public let page: Int
        public let perPage: Int
        public let totalEntries: Int
        public let totalPages: Int

        public var hasNextPage: Bool { page < totalPages }

        enum CodingKeys: String, CodingKey {
            case page
            case perPage = "per_page"
            case totalEntries = "total_entries"
            case totalPages = "total_pages"
        }
    }

    public static func nextURL(fromLinkHeader header: String) -> URL? {
        let links = header.components(separatedBy: ",")
        for link in links {
            let parts = link.components(separatedBy: ";")
            guard parts.count == 2 else { continue }
            let rel = parts[1].trimmingCharacters(in: .whitespaces)
            guard rel == "rel=\"next\"" else { continue }
            var urlString = parts[0].trimmingCharacters(in: .whitespaces)
            if urlString.hasPrefix("<") && urlString.hasSuffix(">") {
                urlString = String(urlString.dropFirst().dropLast())
            }
            return URL(string: urlString)
        }
        return nil
    }
}
