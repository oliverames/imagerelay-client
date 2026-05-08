import Foundation

/// An Image Relay product / catalog item. Returned from `GET /products.json` (list)
/// and `GET /products/{id}.json` (detail). This client treats products as read-only.
public struct Product: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let sku: String?
    public let description: String?
    public let primaryImageURL: String?
    public let assetCount: Int?
    public let updatedOn: String?
    public let createdOn: String?
    public let categoryName: String?

    public var updatedAt: Date? { updatedOn.flatMap(ImageRelayDateParser.date) }
    public var createdAt: Date? { createdOn.flatMap(ImageRelayDateParser.date) }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case productName = "product_name"
        case sku
        case description
        case primaryImageURL = "primary_image_url"
        case primaryImage = "primary_image"
        case thumbnailURL = "thumbnail_url"
        case assetCount = "asset_count"
        case fileCount = "file_count"
        case updatedOn = "updated_on"
        case createdOn = "created_on"
        case categoryName = "category_name"
        case category
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .productName)
            ?? "Untitled"
        sku = try c.decodeIfPresent(String.self, forKey: .sku)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        primaryImageURL = try c.decodeIfPresent(String.self, forKey: .primaryImageURL)
            ?? c.decodeIfPresent(String.self, forKey: .primaryImage)
            ?? c.decodeIfPresent(String.self, forKey: .thumbnailURL)
        assetCount = try c.decodeIfPresent(Int.self, forKey: .assetCount)
            ?? c.decodeIfPresent(Int.self, forKey: .fileCount)
        updatedOn = try c.decodeIfPresent(String.self, forKey: .updatedOn)
        createdOn = try c.decodeIfPresent(String.self, forKey: .createdOn)
        // `category` may be a string OR a nested object with `name`.
        if let categoryString = try? c.decodeIfPresent(String.self, forKey: .categoryName) {
            categoryName = categoryString
        } else if let categoryDict = try? c.decodeIfPresent([String: String].self, forKey: .category) {
            categoryName = categoryDict["name"]
        } else {
            categoryName = nil
        }
    }

    public init(
        id: Int,
        name: String,
        sku: String? = nil,
        description: String? = nil,
        primaryImageURL: String? = nil,
        assetCount: Int? = nil,
        updatedOn: String? = nil,
        createdOn: String? = nil,
        categoryName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sku = sku
        self.description = description
        self.primaryImageURL = primaryImageURL
        self.assetCount = assetCount
        self.updatedOn = updatedOn
        self.createdOn = createdOn
        self.categoryName = categoryName
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(sku, forKey: .sku)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(primaryImageURL, forKey: .primaryImageURL)
        try c.encodeIfPresent(assetCount, forKey: .assetCount)
        try c.encodeIfPresent(updatedOn, forKey: .updatedOn)
        try c.encodeIfPresent(createdOn, forKey: .createdOn)
        try c.encodeIfPresent(categoryName, forKey: .categoryName)
    }
}
