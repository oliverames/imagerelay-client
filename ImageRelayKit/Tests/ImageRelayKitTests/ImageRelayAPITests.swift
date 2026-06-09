import Foundation
import Testing
@testable import ImageRelayKit

final class ImageRelayAPIMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        requestHandler != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("ImageRelayAPI", .serialized)
struct ImageRelayAPITests {
    private let baseURL = URL(string: "https://api.test.imagerelay.com/api/v2")!

    private func makeAPI() -> ImageRelayAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ImageRelayAPIMockURLProtocol.self]
        let client = APIClient(
            baseURL: baseURL,
            apiKey: "test-key",
            userAgent: "TestAgent/1.0",
            sessionConfiguration: config,
            rateLimiter: RateLimiter(maxRequests: 100, period: 1.0)
        )
        return ImageRelayAPI(client: client)
    }

    @Test("DAM gap endpoints use documented paths and bodies")
    func damGapEndpoints() async throws {
        var seen: [String] = []
        ImageRelayAPIMockURLProtocol.requestHandler = { request in
            let path = request.url?.path.replacingOccurrences(of: "/api/v2", with: "") ?? ""
            seen.append("\(request.httpMethod ?? "") \(path)")

            switch path {
            case "/files":
                let body = try jsonBody(request)
                #expect(body["filename"] as? String == "remote.jpg")
                #expect(body["folder_id"] as? String == "2907644")
                #expect(body["file_type_id"] as? String == "6096")
                #expect(body["url"] as? String == "https://example.com/remote.jpg")
                return jsonResponse(request, #"{"id":101,"filename":"remote.jpg","size":0}"#)
            case "/files/101/terms":
                let body = try jsonBody(request)
                #expect(body["overwrite"] as? Bool == true)
                let terms = try #require(body["terms"] as? [[String: Any]])
                #expect(terms.first?["term_id"] as? String == "8393")
                #expect(terms.first?["value"] as? String == "Credit")
                return jsonResponse(request, "{}")
            case "/files/101/tags":
                let body = try jsonBody(request)
                let tags = try #require(body["tags"] as? [String: Any])
                #expect(tags["add_ids"] as? [String] == ["12922"])
                #expect(tags["remove_ids"] as? [String] == ["48612"])
                return jsonResponse(request, "{}")
            case "/101/synced_file":
                let body = try jsonBody(request)
                #expect(body["folder_ids"] as? [String] == ["123", "456"])
                return jsonResponse(request, "{}")
            case "/files/101/dupicate":
                let body = try jsonBody(request)
                #expect(body["folder_id"] as? String == "987")
                #expect(body["should_copy_metadata"] as? Bool == true)
                return jsonResponse(request, "{}")
            case "/files/101/thumbnail":
                #expect(request.url?.query == "filename=thumb.jpg")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
                #expect(try requestBodyData(request) == Data([0x01, 0x02]))
                return jsonResponse(request, "{}")
            default:
                Issue.record("Unexpected request path: \(path)")
                return jsonResponse(request, "{}")
            }
        }

        let api = makeAPI()
        let uploaded = try await api.uploadFileFromURL(
            FileURLUploadRequest(
                filename: "remote.jpg",
                folderID: 2_907_644,
                fileTypeID: 6_096,
                terms: [FileTermValue(termID: 8_393, value: "Credit")],
                url: URL(string: "https://example.com/remote.jpg")!,
                keywordIDs: [12_922]
            )
        )
        #expect(uploaded.id == 101)

        try await api.updateFileTerms(
            fileID: 101,
            FileTermsUpdate(terms: [FileTermValue(termID: 8_393, value: "Credit")], overwrite: true)
        )
        try await api.updateFileTags(
            fileID: 101,
            FileTagsUpdate(addIDs: [12_922], removeIDs: [48_612])
        )
        try await api.createSyncedFile(fileID: 101, folderIDs: [123, 456])
        try await api.duplicateFile(fileID: 101, folderID: 987, shouldCopyMetadata: true)
        try await api.updateAssetThumbnail(fileID: 101, filename: "thumb.jpg", data: Data([0x01, 0x02]))

        #expect(seen == [
            "POST /files",
            "POST /files/101/terms",
            "POST /files/101/tags",
            "POST /101/synced_file",
            "POST /files/101/dupicate",
            "POST /files/101/thumbnail"
        ])
    }

    @Test("Admin single-resource gap endpoints are typed")
    func adminSingleResourceGapEndpoints() async throws {
        var seen: [String] = []
        ImageRelayAPIMockURLProtocol.requestHandler = { request in
            let path = request.url?.path.replacingOccurrences(of: "/api/v2", with: "") ?? ""
            seen.append("\(request.httpMethod ?? "") \(path)")
            switch path {
            case "/quick_links/1":
                return jsonResponse(request, #"{"id":1,"uid":"q1","url":"https://ir.example/q1"}"#)
            case "/upload_links/2":
                return jsonResponse(request, #"{"id":2,"purpose":"Drop Box","upload_link_url":"https://ir.example/u2"}"#)
            case "/folder_links/3.json":
                return jsonResponse(request, #"{"id":3,"uid":"f3","url":"https://ir.example/f3","folder_id":44}"#)
            case "/file_types/4":
                return jsonResponse(request, #"{"id":4,"name":"Asset","terms":[]}"#)
            case "/invited_users/5":
                return jsonResponse(request, #"{"id":5,"email":"invite@example.com"}"#)
            case "/keyword_sets/6":
                return jsonResponse(request, #"{"id":6,"name":"Topics"}"#)
            case "/keyword_sets/6/keywords/7":
                return jsonResponse(request, #"{"id":7,"name":"Health"}"#)
            case "/permissions/8":
                return jsonResponse(request, #"{"id":8,"name":"Admin"}"#)
            case "/webhooks/9":
                return jsonResponse(request, #"{"id":9,"url":"https://hooks.example","state":"normal","events":["file.create"]}"#)
            case "/users/10/quick_links":
                return jsonResponse(request, #"[{"id":11,"uid":"q11","url":"https://ir.example/q11"}]"#)
            case "/users/sso_user":
                let body = try jsonBody(request)
                #expect(body["first_name"] as? String == "Ava")
                #expect(body["permission_id"] as? Int == 8)
                return jsonResponse(request, #"{"id":12,"email":"ava@example.com","first_name":"Ava","permission_id":8}"#, statusCode: 201)
            default:
                Issue.record("Unexpected request path: \(path)")
                return jsonResponse(request, "{}")
            }
        }

        let api = makeAPI()
        #expect(try await api.quickLink(id: 1).uid == "q1")
        #expect(try await api.uploadLink(id: 2).name == "Drop Box")
        #expect(try await api.folderLink(id: 3).folderID == 44)
        #expect(try await api.fileType(id: 4).name == "Asset")
        #expect(try await api.invitedUser(id: 5).email == "invite@example.com")
        #expect(try await api.keywordSet(id: 6).name == "Topics")
        #expect(try await api.keyword(setID: 6, keywordID: 7).name == "Health")
        #expect(try await api.permissionGroup(id: 8).name == "Admin")
        #expect(try await api.webhook(id: 9).isActive == true)
        #expect(try await api.userQuickLinks(userID: 10).first?.id == 11)
        #expect(try await api.createSSOUser(SSOUserCreate(firstName: "Ava", lastName: "Smith", email: "ava@example.com", company: "Example", permissionID: 8)).id == 12)

        #expect(seen == [
            "GET /quick_links/1",
            "GET /upload_links/2",
            "GET /folder_links/3.json",
            "GET /file_types/4",
            "GET /invited_users/5",
            "GET /keyword_sets/6",
            "GET /keyword_sets/6/keywords/7",
            "GET /permissions/8",
            "GET /webhooks/9",
            "GET /users/10/quick_links",
            "POST /users/sso_user"
        ])
    }

    @Test("Webhook state update is typed")
    func webhookStateUpdate() async throws {
        ImageRelayAPIMockURLProtocol.requestHandler = { request in
            let path = request.url?.path.replacingOccurrences(of: "/api/v2", with: "") ?? ""
            #expect(request.httpMethod == "PUT")
            #expect(path == "/webhooks/9")
            let body = try jsonBody(request)
            #expect(body["state"] as? String == "paused")
            return jsonResponse(request, #"{"id":9,"url":"https://hooks.example","state":"paused","events":[]}"#)
        }

        let api = makeAPI()
        let webhook = try await api.updateWebhook(id: 9, WebhookUpdate(state: .paused))
        #expect(webhook.isActive == false)
    }

    @Test("Products API gap endpoints are typed")
    func productAPIGapEndpoints() async throws {
        var seen: [String] = []
        ImageRelayAPIMockURLProtocol.requestHandler = { request in
            let path = request.url?.path.replacingOccurrences(of: "/api/v2", with: "") ?? ""
            seen.append("\(request.httpMethod ?? "") \(path)")

            switch path {
            case "/products/1":
                if request.httpMethod == "GET" {
                    return jsonResponse(request, #"{"id":1,"name":"Bottle","sku":"BOT-1"}"#)
                } else if request.httpMethod == "PUT" {
                    let body = try jsonBody(request)
                    #expect(body["name"] as? String == "Updated Bottle")
                    return jsonResponse(request, #"{"id":1,"name":"Updated Bottle","sku":"BOT-1"}"#)
                }
                return jsonResponse(request, "{}")
            case "/products":
                let body = try jsonBody(request)
                #expect(body["name"] as? String == "Bottle")
                #expect(body["product_template_id"] as? Int == 20)
                return jsonResponse(request, #"{"id":1,"name":"Bottle","sku":"BOT-1"}"#)
            case "/products/1/variants":
                if request.httpMethod == "GET" {
                    return jsonResponse(request, #"[{"id":2,"name":"Blue Bottle","product_id":1}]"#)
                }
                let body = try jsonBody(request)
                #expect(body["variant_dimension_options"] != nil)
                #expect(body["product_custom_attributes"] != nil)
                return jsonResponse(request, #"{"id":2,"name":"Blue Bottle","product_id":1}"#)
            case "/products/1/variants/2":
                if request.httpMethod == "GET" || request.httpMethod == "PATCH" {
                    if request.httpMethod == "PATCH" {
                        let body = try jsonBody(request)
                        #expect(body["variant_dimension_options"] != nil)
                        #expect(body["product_custom_attributes"] != nil)
                    }
                    return jsonResponse(request, #"{"id":2,"name":"Blue Bottle","product_id":1}"#)
                }
                return jsonResponse(request, "{}")
            case "/product_channel_template_mappings/77":
                return jsonResponse(request, #"[{"id":88,"name":"Shopify Title","source":"name"}]"#)
            case "/product_catalogs":
                if request.httpMethod == "GET" {
                    return jsonResponse(request, #"[{"id":3,"name":"Spring","summary":"Catalog"}]"#)
                }
                return jsonResponse(request, #"{"id":3,"name":"Spring","summary":"Catalog"}"#)
            case "/product_catalogs/3":
                if request.httpMethod == "GET" || request.httpMethod == "PUT" {
                    return jsonResponse(request, #"{"id":3,"name":"Spring","summary":"Catalog"}"#)
                }
                return jsonResponse(request, "{}")
            case "/product_catalogs/3/products":
                return jsonResponse(request, #"[{"id":1,"name":"Bottle"}]"#)
            case "/product_templates":
                return jsonResponse(request, #"[{"id":4,"name":"Apparel","summary":"Template"}]"#)
            case "/product_template":
                return jsonResponse(request, #"{"id":4,"name":"Apparel","summary":"Template"}"#)
            case "/product_templates/4":
                return jsonResponse(request, #"{"id":4,"name":"Apparel Updated","summary":"Template"}"#)
            case "/product_custom_attributes":
                if request.httpMethod == "GET" {
                    return jsonResponse(request, #"[{"id":5,"name":"Material"}]"#)
                }
                return jsonResponse(request, #"{"id":5,"name":"Material"}"#)
            case "/product_custom_attributes/5":
                return jsonResponse(request, #"{"id":5,"name":"Material"}"#)
            case "/product_categories":
                return jsonResponse(request, #"[{"id":6,"name":"Outdoor","children":[{"id":7,"name":"Bikes"}]}]"#)
            case "/product_categories/6":
                return jsonResponse(request, #"{"id":6,"name":"Outdoor","children":[{"id":7,"name":"Bikes"}]}"#)
            case "/product_dimensions":
                if request.httpMethod == "GET" {
                    return jsonResponse(request, #"[{"id":8,"name":"Size","options":[{"id":9,"name":"Large"}]}]"#)
                }
                return jsonResponse(request, #"{"id":8,"name":"Size","options":[]}"#)
            case "/product_dimensions/8":
                return jsonResponse(request, #"{"id":8,"name":"Size","options":[{"id":9,"name":"Large"}]}"#)
            case "/product_dimensions/8/add_option":
                return jsonResponse(request, #"{"id":10,"name":"Small"}"#)
            default:
                Issue.record("Unexpected request path: \(path)")
                return jsonResponse(request, "{}")
            }
        }

        let api = makeAPI()
        #expect(try await api.product(id: 1).sku == "BOT-1")
        #expect(try await api.createProduct(ProductMutation(name: "Bottle", productTemplateID: 20, sku: "BOT-1")).id == 1)
        #expect(try await api.updateProduct(id: 1, ProductMutation(name: "Updated Bottle")).name == "Updated Bottle")
        try await api.deleteProduct(id: 1)
        #expect(try await api.productVariants(productID: 1).first?.id == 2)
        #expect(try await api.productVariant(productID: 1, variantID: 2).name == "Blue Bottle")
        let variantMutation = ProductVariantMutation(
            name: "Blue Bottle",
            options: [ProductVariantOptionAssignment(dimensionID: 20, dimensionOptionID: 21)],
            customAttributes: [ProductCustomAttributeAssignment(id: 5, value: "Steel")]
        )
        #expect(try await api.createProductVariant(productID: 1, variantMutation).id == 2)
        #expect(try await api.updateProductVariant(productID: 1, variantID: 2, variantMutation).id == 2)
        try await api.deleteProductVariant(productID: 1, variantID: 2)
        #expect(try await api.channelTemplateMappings(channelTemplateID: 77).first?.name == "Shopify Title")
        #expect(try await api.productCatalogs().first?.id == 3)
        #expect(try await api.productCatalog(id: 3).name == "Spring")
        #expect(try await api.catalogProducts(catalogID: 3).first?.id == 1)
        #expect(try await api.createProductCatalog(ProductCatalogMutation(name: "Spring", summary: "Catalog")).id == 3)
        #expect(try await api.updateProductCatalog(id: 3, ProductCatalogMutation(name: "Spring", summary: "Catalog")).id == 3)
        try await api.deleteProductCatalog(id: 3)
        #expect(try await api.productTemplates().first?.id == 4)
        #expect(try await api.createProductTemplate(ProductTemplateMutation(name: "Apparel", summary: "Template")).id == 4)
        #expect(try await api.updateProductTemplate(id: 4, ProductTemplateMutation(name: "Apparel Updated")).name == "Apparel Updated")
        #expect(try await api.productCustomAttributes().first?.id == 5)
        #expect(try await api.productCustomAttribute(id: 5).name == "Material")
        #expect(try await api.createProductCustomAttribute(ProductCustomAttributeMutation(name: "Material")).id == 5)
        #expect(try await api.updateProductCustomAttribute(id: 5, ProductCustomAttributeMutation(name: "Material")).id == 5)
        #expect(try await api.productCategories().first?.children.first?.name == "Bikes")
        #expect(try await api.productCategory(id: 6).children.first?.id == 7)
        #expect(try await api.productDimensions().first?.options.first?.name == "Large")
        #expect(try await api.productDimension(id: 8).options.first?.id == 9)
        #expect(try await api.createProductDimension(ProductDimensionMutation(name: "Size")).id == 8)
        #expect(try await api.updateProductDimension(id: 8, ProductDimensionMutation(name: "Size")).id == 8)
        #expect(try await api.addProductDimensionOption(dimensionID: 8, ProductDimensionOptionMutation(name: "Small")).id == 10)

        #expect(seen == [
            "GET /products/1",
            "POST /products",
            "PUT /products/1",
            "DELETE /products/1",
            "GET /products/1/variants",
            "GET /products/1/variants/2",
            "POST /products/1/variants",
            "PATCH /products/1/variants/2",
            "DELETE /products/1/variants/2",
            "GET /product_channel_template_mappings/77",
            "GET /product_catalogs",
            "GET /product_catalogs/3",
            "GET /product_catalogs/3/products",
            "POST /product_catalogs",
            "PUT /product_catalogs/3",
            "DELETE /product_catalogs/3",
            "GET /product_templates",
            "POST /product_template",
            "PUT /product_templates/4",
            "GET /product_custom_attributes",
            "GET /product_custom_attributes/5",
            "POST /product_custom_attributes",
            "PUT /product_custom_attributes/5",
            "GET /product_categories",
            "GET /product_categories/6",
            "GET /product_dimensions",
            "GET /product_dimensions/8",
            "POST /product_dimensions",
            "PUT /product_dimensions/8",
            "POST /product_dimensions/8/add_option"
        ])
    }
}

private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
    let data = try requestBodyData(request)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func requestBodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }

    let stream = try #require(request.httpBodyStream)
    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            throw stream.streamError ?? URLError(.cannotDecodeRawData)
        }
        if count == 0 {
            break
        }
        data.append(buffer, count: count)
    }
    return data
}

private func jsonResponse(
    _ request: URLRequest,
    _ json: String,
    statusCode: Int = 200
) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
    return (response, Data(json.utf8))
}
