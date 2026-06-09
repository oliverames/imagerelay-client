import Foundation

public struct ImageRelayAPI: Sendable {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    // MARK: - DAM gaps

    public func uploadFileFromURL(_ request: FileURLUploadRequest) async throws -> RemoteFile {
        try await client.post("/files", body: request)
    }

    public func updateFileTerms(fileID: Int, _ update: FileTermsUpdate) async throws {
        try await client.post("/files/\(fileID)/terms", body: update)
    }

    public func updateFileTags(fileID: Int, _ update: FileTagsUpdate) async throws {
        try await client.post("/files/\(fileID)/tags", body: update)
    }

    public func createSyncedFile(fileID: Int, folderIDs: [Int]) async throws {
        try await client.post("/\(fileID)/synced_file", body: SyncedFileRequest(folderIDs: folderIDs))
    }

    public func duplicateFile(fileID: Int, folderID: Int, shouldCopyMetadata: Bool) async throws {
        try await client.post(
            "/files/\(fileID)/dupicate",
            body: DuplicateFileRequest(folderID: folderID, shouldCopyMetadata: shouldCopyMetadata)
        )
    }

    public func updateAssetThumbnail(fileID: Int, filename: String, data: Data) async throws {
        try await client.upload(
            data: data,
            to: "/files/\(fileID)/thumbnail",
            query: ["filename": filename],
            contentType: "application/octet-stream"
        )
    }

    // MARK: - Single-resource admin gaps

    public func quickLink(id: Int) async throws -> QuickLink {
        try await client.get("/quick_links/\(id)")
    }

    public func uploadLink(id: Int) async throws -> UploadLink {
        try await client.get("/upload_links/\(id)")
    }

    public func folderLink(id: Int) async throws -> FolderLink {
        try await client.get("/folder_links/\(id).json")
    }

    public func fileType(id: Int) async throws -> FileType {
        try await client.get("/file_types/\(id)")
    }

    public func invitedUser(id: Int) async throws -> InvitedUser {
        try await client.get("/invited_users/\(id)")
    }

    public func keywordSet(id: Int) async throws -> KeywordSet {
        try await client.get("/keyword_sets/\(id)")
    }

    public func keyword(setID: Int, keywordID: Int) async throws -> Keyword {
        try await client.get("/keyword_sets/\(setID)/keywords/\(keywordID)")
    }

    public func permissionGroup(id: Int) async throws -> PermissionGroup {
        try await client.get("/permissions/\(id)")
    }

    public func webhook(id: Int) async throws -> Webhook {
        try await client.get("/webhooks/\(id)")
    }

    public func updateWebhook(id: Int, _ update: WebhookUpdate) async throws -> Webhook {
        try await client.put("/webhooks/\(id)", body: update)
    }

    public func userQuickLinks(userID: Int) async throws -> [QuickLink] {
        try await client.getAllPages("/users/\(userID)/quick_links")
    }

    public func createSSOUser(_ request: SSOUserCreate) async throws -> ImageRelayUser {
        try await client.post("/users/sso_user", body: request)
    }

    // MARK: - Products

    public func products() async throws -> [Product] {
        try await client.getAllPages("/products")
    }

    public func product(id: Int) async throws -> Product {
        try await client.get("/products/\(id)")
    }

    public func createProduct(_ mutation: ProductMutation) async throws -> Product {
        try await client.post("/products", body: mutation)
    }

    public func updateProduct(id: Int, _ mutation: ProductMutation) async throws -> Product {
        try await client.put("/products/\(id)", body: mutation)
    }

    public func deleteProduct(id: Int) async throws {
        try await client.delete("/products/\(id)")
    }

    public func productVariants(productID: Int) async throws -> [ProductVariant] {
        try await client.getAllPages("/products/\(productID)/variants")
    }

    public func productVariant(productID: Int, variantID: Int) async throws -> ProductVariant {
        try await client.get("/products/\(productID)/variants/\(variantID)")
    }

    public func createProductVariant(productID: Int, _ mutation: ProductVariantMutation) async throws -> ProductVariant {
        try await client.post("/products/\(productID)/variants", body: mutation)
    }

    public func updateProductVariant(
        productID: Int,
        variantID: Int,
        _ mutation: ProductVariantMutation
    ) async throws -> ProductVariant {
        try await client.patch("/products/\(productID)/variants/\(variantID)", body: mutation)
    }

    public func deleteProductVariant(productID: Int, variantID: Int) async throws {
        try await client.delete("/products/\(productID)/variants/\(variantID)")
    }

    public func channelTemplateMappings(channelTemplateID: Int) async throws -> [ChannelTemplateMapping] {
        try await client.getAllPages("/product_channel_template_mappings/\(channelTemplateID)")
    }

    // MARK: - Catalogs

    public func productCatalogs() async throws -> [ProductCatalog] {
        try await client.getAllPages("/product_catalogs")
    }

    public func productCatalog(id: Int) async throws -> ProductCatalog {
        try await client.get("/product_catalogs/\(id)")
    }

    public func catalogProducts(catalogID: Int) async throws -> [Product] {
        try await client.getAllPages("/product_catalogs/\(catalogID)/products")
    }

    public func createProductCatalog(_ mutation: ProductCatalogMutation) async throws -> ProductCatalog {
        try await client.post("/product_catalogs", body: mutation)
    }

    public func updateProductCatalog(id: Int, _ mutation: ProductCatalogMutation) async throws -> ProductCatalog {
        try await client.put("/product_catalogs/\(id)", body: mutation)
    }

    public func deleteProductCatalog(id: Int) async throws {
        try await client.delete("/product_catalogs/\(id)")
    }

    // MARK: - Templates

    public func productTemplates() async throws -> [ProductTemplate] {
        try await client.getAllPages("/product_templates")
    }

    public func productTemplate(id: Int) async throws -> ProductTemplate {
        try await client.get("/product_templates/\(id)")
    }

    public func createProductTemplate(_ mutation: ProductTemplateMutation) async throws -> ProductTemplate {
        try await client.post("/product_template", body: mutation)
    }

    public func updateProductTemplate(id: Int, _ mutation: ProductTemplateMutation) async throws -> ProductTemplate {
        try await client.put("/product_templates/\(id)", body: mutation)
    }

    // MARK: - Product metadata

    public func productCustomAttributes() async throws -> [ProductCustomAttribute] {
        try await client.getAllPages("/product_custom_attributes")
    }

    public func productCustomAttribute(id: Int) async throws -> ProductCustomAttribute {
        try await client.get("/product_custom_attributes/\(id)")
    }

    public func createProductCustomAttribute(_ mutation: ProductCustomAttributeMutation) async throws -> ProductCustomAttribute {
        try await client.post("/product_custom_attributes", body: mutation)
    }

    public func updateProductCustomAttribute(
        id: Int,
        _ mutation: ProductCustomAttributeMutation
    ) async throws -> ProductCustomAttribute {
        try await client.put("/product_custom_attributes/\(id)", body: mutation)
    }

    public func productCategories() async throws -> [ProductCategory] {
        try await client.getAllPages("/product_categories")
    }

    public func productCategory(id: Int) async throws -> ProductCategory {
        try await client.get("/product_categories/\(id)")
    }

    public func productDimensions() async throws -> [ProductDimension] {
        try await client.getAllPages("/product_dimensions")
    }

    public func productDimension(id: Int) async throws -> ProductDimension {
        try await client.get("/product_dimensions/\(id)")
    }

    public func createProductDimension(_ mutation: ProductDimensionMutation) async throws -> ProductDimension {
        try await client.post("/product_dimensions", body: mutation)
    }

    public func updateProductDimension(id: Int, _ mutation: ProductDimensionMutation) async throws -> ProductDimension {
        try await client.put("/product_dimensions/\(id)", body: mutation)
    }

    public func addProductDimensionOption(
        dimensionID: Int,
        _ mutation: ProductDimensionOptionMutation
    ) async throws -> ProductDimensionOption {
        try await client.post("/product_dimensions/\(dimensionID)/add_option", body: mutation)
    }
}
