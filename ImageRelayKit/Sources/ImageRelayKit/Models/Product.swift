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

public struct ProductCustomAttributeAssignment: Codable, Sendable, Hashable {
    public let id: Int
    public let value: String

    public init(id: Int, value: String) {
        self.id = id
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case id
        case productCustomAttributeID = "product_custom_attribute_id"
        case value
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id)
            ?? c.decode(Int.self, forKey: .productCustomAttributeID)
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .productCustomAttributeID)
        try c.encode(value, forKey: .value)
    }
}

public struct ProductMutation: Encodable, Sendable {
    public let name: String?
    public let productTemplateID: Int?
    public let templateID: Int?
    public let sku: String?
    public let dimension1Name: String?
    public let dimension1Value: String?
    public let dimension2Name: String?
    public let dimension2Value: String?
    public let dimension3Name: String?
    public let dimension3Value: String?
    public let hasVariants: Bool?
    public let dimension1ID: Int?
    public let dimension2ID: Int?
    public let dimension3ID: Int?
    public let customAttributes: [ProductCustomAttributeAssignment]?

    public init(
        name: String? = nil,
        productTemplateID: Int? = nil,
        templateID: Int? = nil,
        sku: String? = nil,
        dimension1Name: String? = nil,
        dimension1Value: String? = nil,
        dimension2Name: String? = nil,
        dimension2Value: String? = nil,
        dimension3Name: String? = nil,
        dimension3Value: String? = nil,
        hasVariants: Bool? = nil,
        dimension1ID: Int? = nil,
        dimension2ID: Int? = nil,
        dimension3ID: Int? = nil,
        customAttributes: [ProductCustomAttributeAssignment]? = nil
    ) {
        self.name = name
        self.productTemplateID = productTemplateID
        self.templateID = templateID
        self.sku = sku
        self.dimension1Name = dimension1Name
        self.dimension1Value = dimension1Value
        self.dimension2Name = dimension2Name
        self.dimension2Value = dimension2Value
        self.dimension3Name = dimension3Name
        self.dimension3Value = dimension3Value
        self.hasVariants = hasVariants
        self.dimension1ID = dimension1ID
        self.dimension2ID = dimension2ID
        self.dimension3ID = dimension3ID
        self.customAttributes = customAttributes
    }

    enum CodingKeys: String, CodingKey {
        case name
        case productTemplateID = "product_template_id"
        case templateID = "template_id"
        case sku
        case dimension1Name = "dimension_1_name"
        case dimension1Value = "dimension_1_value"
        case dimension2Name = "dimension_2_name"
        case dimension2Value = "dimension_2_value"
        case dimension3Name = "dimension_3_name"
        case dimension3Value = "dimension_3_value"
        case hasVariants = "has_variants"
        case dimension1ID = "dimension_1_id"
        case dimension2ID = "dimension_2_id"
        case dimension3ID = "dimension_3_id"
        case customAttributes = "custom_attributes"
    }
}

public struct ProductVariant: Decodable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let sku: String?
    public let productID: Int?
    public let options: [ProductVariantOptionAssignment]
    public let customAttributes: [ProductCustomAttributeAssignment]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sku
        case productID = "product_id"
        case options
        case dimensionOptions = "dimension_options"
        case customAttributes = "custom_attributes"
        case productCustomAttributes = "product_custom_attributes"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        sku = try c.decodeIfPresent(String.self, forKey: .sku)
        productID = try c.decodeIfPresent(Int.self, forKey: .productID)
        options = try c.decodeIfPresent([ProductVariantOptionAssignment].self, forKey: .options)
            ?? c.decodeIfPresent([ProductVariantOptionAssignment].self, forKey: .dimensionOptions)
            ?? []
        customAttributes = try c.decodeIfPresent([ProductCustomAttributeAssignment].self, forKey: .customAttributes)
            ?? c.decodeIfPresent([ProductCustomAttributeAssignment].self, forKey: .productCustomAttributes)
            ?? []
    }

    public init(
        id: Int,
        name: String,
        sku: String? = nil,
        productID: Int? = nil,
        options: [ProductVariantOptionAssignment] = [],
        customAttributes: [ProductCustomAttributeAssignment] = []
    ) {
        self.id = id
        self.name = name
        self.sku = sku
        self.productID = productID
        self.options = options
        self.customAttributes = customAttributes
    }
}

public struct ProductVariantOptionAssignment: Codable, Sendable, Hashable {
    public let dimensionID: Int
    public let dimensionOptionID: Int

    public init(dimensionID: Int, dimensionOptionID: Int) {
        self.dimensionID = dimensionID
        self.dimensionOptionID = dimensionOptionID
    }

    enum CodingKeys: String, CodingKey {
        case dimensionID = "dimension_id"
        case dimensionOptionID = "dimension_option_id"
    }
}

public struct ProductVariantMutation: Encodable, Sendable {
    public let name: String?
    public let options: [ProductVariantOptionAssignment]?
    public let customAttributes: [ProductCustomAttributeAssignment]?

    public init(
        name: String? = nil,
        options: [ProductVariantOptionAssignment]? = nil,
        customAttributes: [ProductCustomAttributeAssignment]? = nil
    ) {
        self.name = name
        self.options = options
        self.customAttributes = customAttributes
    }

    enum CodingKeys: String, CodingKey {
        case name
        case options = "variant_dimension_options"
        case customAttributes = "product_custom_attributes"
    }
}

public struct ChannelTemplateMapping: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let source: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case source
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let intID = try? c.decodeIfPresent(Int.self, forKey: .id) {
            id = String(intID)
        } else {
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        }
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

public struct ProductCatalog: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let summary: String?
    public let productCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case summary
        case productCount = "product_count"
    }
}

public struct ProductCatalogMutation: Encodable, Sendable {
    public let name: String?
    public let summary: String?

    public init(name: String? = nil, summary: String? = nil) {
        self.name = name
        self.summary = summary
    }
}

public struct ProductTemplate: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let summary: String?
}

public struct ProductTemplateMutation: Encodable, Sendable {
    public let name: String?
    public let summary: String?

    public init(name: String? = nil, summary: String? = nil) {
        self.name = name
        self.summary = summary
    }
}

public struct ProductCustomAttribute: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
}

public struct ProductCustomAttributeMutation: Encodable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

public struct ProductCategory: Decodable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let children: [ProductCategory]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case children
        case descendants
        case categories
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        children = try c.decodeIfPresent([ProductCategory].self, forKey: .children)
            ?? c.decodeIfPresent([ProductCategory].self, forKey: .descendants)
            ?? c.decodeIfPresent([ProductCategory].self, forKey: .categories)
            ?? []
    }
}

public struct ProductDimension: Decodable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let options: [ProductDimensionOption]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case options
        case dimensionOptions = "dimension_options"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        options = try c.decodeIfPresent([ProductDimensionOption].self, forKey: .options)
            ?? c.decodeIfPresent([ProductDimensionOption].self, forKey: .dimensionOptions)
            ?? []
    }
}

public struct ProductDimensionOption: Decodable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case value
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .value)
            ?? "Untitled"
    }
}

public struct ProductDimensionMutation: Encodable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

public struct ProductDimensionOptionMutation: Encodable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}
