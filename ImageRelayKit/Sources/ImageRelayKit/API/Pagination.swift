import Foundation

public enum Pagination {
    public struct PageInfo: Decodable, Sendable {
        public let page: Int
        public let perPage: Int
        public let totalEntries: Int
        public let totalPages: Int
        private let hasExplicitNext: Bool?

        public var hasNextPage: Bool { hasExplicitNext ?? (page < totalPages) }

        enum CodingKeys: String, CodingKey {
            case page
            case current
            case perPage = "per_page"
            case totalEntries = "total_entries"
            case count
            case totalPages = "total_pages"
            case pages
            case next
            case hasNext = "has_next"
            case nextPagePath = "next_page_path"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            page = try container.decodeIfPresent(Int.self, forKey: .page)
                ?? container.decode(Int.self, forKey: .current)
            perPage = try container.decode(Int.self, forKey: .perPage)
            totalEntries = try container.decodeIfPresent(Int.self, forKey: .totalEntries)
                ?? container.decode(Int.self, forKey: .count)
            totalPages = try container.decodeIfPresent(Int.self, forKey: .totalPages)
                ?? container.decode(Int.self, forKey: .pages)

            if let hasNext = try container.decodeIfPresent(Bool.self, forKey: .hasNext) {
                hasExplicitNext = hasNext
            } else if let next = try container.decodeIfPresent(String.self, forKey: .next) {
                hasExplicitNext = !next.isEmpty
            } else if let nextPagePath = try container.decodeIfPresent(String.self, forKey: .nextPagePath) {
                hasExplicitNext = !nextPagePath.isEmpty
            } else {
                hasExplicitNext = nil
            }
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
