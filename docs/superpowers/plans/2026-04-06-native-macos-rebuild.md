# ImageRelay Client: Native macOS Rebuild — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Python-based ImageRelay sync client as a native macOS Tahoe app with Finder integration via File Provider, a SwiftUI menu bar utility, and a shared Swift package for API/sync logic.

**Architecture:** Monorepo with three Xcode targets (host app, File Provider extension, tests) sharing a local Swift package (ImageRelayKit). The extension handles Finder integration; the host app provides menu bar status and a Settings window. Both communicate through an App Group container with a GRDB-backed SQLite database.

**Tech Stack:** Swift 6, SwiftUI (macOS 26), FileProvider framework, GRDB (SPM), XcodeGen, URLSession async/await

**Spec:** `docs/superpowers/specs/2026-04-06-native-macos-rebuild-design.md`

---

## File Structure

```
ImageRelayClient/
├── Project.yml                              # XcodeGen project spec
├── ImageRelayClient/                        # Host app target
│   ├── App.swift                            # @main MenuBarExtra + Settings
│   ├── MenuBarView.swift                    # Menu bar popover content
│   ├── DomainManager.swift                  # NSFileProviderManager domain lifecycle
│   ├── Settings/
│   │   ├── GeneralSettingsView.swift        # API key, root folder, login item
│   │   ├── FoldersSettingsView.swift        # Folder tree with pin toggles
│   │   ├── ActivitySettingsView.swift       # Recent sync events list
│   │   └── AdvancedSettingsView.swift       # Poll interval, directions, conflicts
│   ├── Resources/
│   │   └── Assets.xcassets
│   └── ImageRelayClient.entitlements
├── FileProviderExtension/                   # File Provider extension target
│   ├── Extension.swift                      # NSFileProviderReplicatedExtension impl
│   ├── Enumerator.swift                     # NSFileProviderEnumerator impl
│   ├── FileProviderItem.swift               # NSFileProviderItemProtocol impl
│   ├── RemoteChangePoller.swift             # Background polling + signalEnumerator
│   ├── Info.plist
│   └── FileProviderExtension.entitlements
├── ImageRelayKit/                           # Local Swift Package
│   ├── Package.swift
│   └── Sources/ImageRelayKit/
│       ├── API/
│       │   ├── APIClient.swift              # URLSession async/await client
│       │   ├── APIError.swift               # Typed error enum
│       │   ├── RateLimiter.swift            # Token bucket (5 req/s)
│       │   └── Pagination.swift             # Link header + JSON pagination
│       ├── Models/
│       │   ├── RemoteFolder.swift           # Codable folder model
│       │   ├── RemoteFile.swift             # Codable file model
│       │   ├── QuickLink.swift              # Codable quick link model
│       │   ├── UploadJob.swift              # Codable upload job model
│       │   └── ItemIdentifier.swift         # folder-{id}/file-{id} helpers
│       ├── Storage/
│       │   ├── SyncDatabase.swift           # GRDB schema + queries
│       │   ├── Configuration.swift          # Shared JSON config in app group
│       │   └── ActivityLog.swift            # Recent sync activity records
│       └── Sync/
│           ├── SyncAnchor.swift             # Opaque anchor for change enumeration
│           └── ConflictResolver.swift       # Conservative conflict strategy
└── Tests/
    └── ImageRelayKitTests/
        ├── APIClientTests.swift
        ├── RateLimiterTests.swift
        ├── PaginationTests.swift
        ├── ModelsTests.swift
        ├── ItemIdentifierTests.swift
        ├── SyncDatabaseTests.swift
        ├── ConfigurationTests.swift
        └── ConflictResolverTests.swift
```

---

## Task 1: Project Scaffolding — Swift Package

**Files:**
- Create: `ImageRelayKit/Package.swift`
- Create: `ImageRelayKit/Sources/ImageRelayKit/ImageRelayKit.swift` (namespace placeholder)

This task creates the local Swift package that both the host app and extension will depend on.

- [ ] **Step 1: Create Package.swift**

```swift
// ImageRelayKit/Package.swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImageRelayKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ImageRelayKit", targets: ["ImageRelayKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "ImageRelayKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "ImageRelayKitTests",
            dependencies: ["ImageRelayKit"]
        ),
    ]
)
```

- [ ] **Step 2: Create namespace file**

```swift
// ImageRelayKit/Sources/ImageRelayKit/ImageRelayKit.swift
// Re-exports for convenience
@_exported import Foundation
```

- [ ] **Step 3: Verify package resolves**

Run: `cd ImageRelayKit && swift package resolve`
Expected: Dependencies resolved successfully, GRDB downloaded.

- [ ] **Step 4: Commit**

```bash
git add ImageRelayKit/
git commit -m "feat: scaffold ImageRelayKit Swift package with GRDB dependency"
```

---

## Task 2: Models — Domain Types

**Files:**
- Create: `ImageRelayKit/Sources/ImageRelayKit/Models/RemoteFolder.swift`
- Create: `ImageRelayKit/Sources/ImageRelayKit/Models/RemoteFile.swift`
- Create: `ImageRelayKit/Sources/ImageRelayKit/Models/QuickLink.swift`
- Create: `ImageRelayKit/Sources/ImageRelayKit/Models/UploadJob.swift`
- Create: `ImageRelayKit/Sources/ImageRelayKit/Models/ItemIdentifier.swift`
- Test: `ImageRelayKit/Tests/ImageRelayKitTests/ModelsTests.swift`
- Test: `ImageRelayKit/Tests/ImageRelayKitTests/ItemIdentifierTests.swift`

These mirror the Python dataclasses in `src/imagerelay_client/models.py`, adapted for Swift and Codable.

- [ ] **Step 1: Write model tests**

```swift
// ImageRelayKit/Tests/ImageRelayKitTests/ModelsTests.swift
import Testing
@testable import ImageRelayKit

@Suite("Remote Models")
struct ModelsTests {
    @Test("Decode RemoteFolder from API JSON")
    func decodeFolderFromAPI() throws {
        let json = """
        {
            "id": 123,
            "name": "Photography",
            "parent_id": 456,
            "path": "/Brand Assets/Photography",
            "updated_on": "2026-04-01T10:00:00Z",
            "child_count": 5
        }
        """.data(using: .utf8)!

        let folder = try JSONDecoder.imageRelay.decode(RemoteFolder.self, from: json)
        #expect(folder.id == 123)
        #expect(folder.name == "Photography")
        #expect(folder.parentID == 456)
        #expect(folder.path == "/Brand Assets/Photography")
        #expect(folder.childCount == 5)
    }

    @Test("Decode RemoteFile from API JSON")
    func decodeFileFromAPI() throws {
        let json = """
        {
            "id": 789,
            "filename": "logo.png",
            "file_size": 204800,
            "updated_on": "2026-04-01T12:00:00Z",
            "content_type": "image/png",
            "file_type_id": 10,
            "folder_ids": [123, 456],
            "deleted": false
        }
        """.data(using: .utf8)!

        let file = try JSONDecoder.imageRelay.decode(RemoteFile.self, from: json)
        #expect(file.id == 789)
        #expect(file.name == "logo.png")
        #expect(file.size == 204800)
        #expect(file.contentType == "image/png")
        #expect(file.folderIDs == [123, 456])
        #expect(file.isDeleted == false)
    }

    @Test("Decode QuickLink from API JSON")
    func decodeQuickLink() throws {
        let json = """
        {
            "id": 55,
            "uid": "abc123",
            "url": "https://ir.example.com/quick/abc123",
            "purpose": "download"
        }
        """.data(using: .utf8)!

        let link = try JSONDecoder.imageRelay.decode(QuickLink.self, from: json)
        #expect(link.id == 55)
        #expect(link.uid == "abc123")
        #expect(link.url.absoluteString == "https://ir.example.com/quick/abc123")
    }

    @Test("Decode UploadJob from API JSON")
    func decodeUploadJob() throws {
        let json = """
        {
            "id": 99,
            "status": "pending",
            "file_id": null
        }
        """.data(using: .utf8)!

        let job = try JSONDecoder.imageRelay.decode(UploadJob.self, from: json)
        #expect(job.id == 99)
        #expect(job.status == "pending")
        #expect(job.fileID == nil)
    }

    @Test("RemoteFile with deleted flag is filtered")
    func deletedFileFiltered() throws {
        let json = """
        {"id": 1, "filename": "old.png", "file_size": 100, "updated_on": null,
         "content_type": null, "file_type_id": null, "folder_ids": [], "deleted": true}
        """.data(using: .utf8)!

        let file = try JSONDecoder.imageRelay.decode(RemoteFile.self, from: json)
        #expect(file.isDeleted == true)
    }
}
```

- [ ] **Step 2: Write ItemIdentifier tests**

```swift
// ImageRelayKit/Tests/ImageRelayKitTests/ItemIdentifierTests.swift
import Testing
@testable import ImageRelayKit

@Suite("Item Identifiers")
struct ItemIdentifierTests {
    @Test("Create folder identifier")
    func folderIdentifier() {
        let id = ItemIdentifier.folder(123)
        #expect(id.rawValue == "folder-123")
        #expect(id.isFolder == true)
        #expect(id.isFile == false)
        #expect(id.numericID == 123)
    }

    @Test("Create file identifier")
    func fileIdentifier() {
        let id = ItemIdentifier.file(456)
        #expect(id.rawValue == "file-456")
        #expect(id.isFolder == false)
        #expect(id.isFile == true)
        #expect(id.numericID == 456)
    }

    @Test("Parse identifier from raw string")
    func parseFromRaw() {
        let folderID = ItemIdentifier(rawValue: "folder-123")
        #expect(folderID?.isFolder == true)
        #expect(folderID?.numericID == 123)

        let fileID = ItemIdentifier(rawValue: "file-456")
        #expect(fileID?.isFile == true)
        #expect(fileID?.numericID == 456)

        let invalid = ItemIdentifier(rawValue: "garbage")
        #expect(invalid == nil)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd ImageRelayKit && swift test 2>&1 | head -30`
Expected: Compilation errors — types not defined yet.

- [ ] **Step 4: Implement RemoteFolder**

```swift
// ImageRelayKit/Sources/ImageRelayKit/Models/RemoteFolder.swift
import Foundation

public struct RemoteFolder: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let parentID: Int?
    public let path: String
    public let updatedOn: String?
    public let childCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case parentID = "parent_id"
        case path
        case updatedOn = "updated_on"
        case childCount = "child_count"
    }

    public init(id: Int, name: String, parentID: Int?, path: String, updatedOn: String?, childCount: Int = 0) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.path = path
        self.updatedOn = updatedOn
        self.childCount = childCount
    }
}
```

- [ ] **Step 5: Implement RemoteFile**

```swift
// ImageRelayKit/Sources/ImageRelayKit/Models/RemoteFile.swift
import Foundation

public struct RemoteFile: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let size: Int
    public let updatedOn: String?
    public let contentType: String?
    public let fileTypeID: Int?
    public let folderIDs: [Int]
    public let isDeleted: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name = "filename"
        case size = "file_size"
        case updatedOn = "updated_on"
        case contentType = "content_type"
        case fileTypeID = "file_type_id"
        case folderIDs = "folder_ids"
        case isDeleted = "deleted"
    }

    public init(
        id: Int, name: String, size: Int, updatedOn: String?,
        contentType: String?, fileTypeID: Int?, folderIDs: [Int] = [],
        isDeleted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.updatedOn = updatedOn
        self.contentType = contentType
        self.fileTypeID = fileTypeID
        self.folderIDs = folderIDs
        self.isDeleted = isDeleted
    }
}
```

- [ ] **Step 6: Implement QuickLink**

```swift
// ImageRelayKit/Sources/ImageRelayKit/Models/QuickLink.swift
import Foundation

public struct QuickLink: Codable, Sendable, Identifiable {
    public let id: Int
    public let uid: String
    public let url: URL
    public let purpose: String?

    public init(id: Int, uid: String, url: URL, purpose: String? = nil) {
        self.id = id
        self.uid = uid
        self.url = url
        self.purpose = purpose
    }
}
```

- [ ] **Step 7: Implement UploadJob**

```swift
// ImageRelayKit/Sources/ImageRelayKit/Models/UploadJob.swift
import Foundation

public struct UploadJob: Codable, Sendable, Identifiable {
    public let id: Int
    public let status: String
    public let fileID: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case fileID = "file_id"
    }

    public init(id: Int, status: String, fileID: Int? = nil) {
        self.id = id
        self.status = status
        self.fileID = fileID
    }
}
```

- [ ] **Step 8: Implement ItemIdentifier**

```swift
// ImageRelayKit/Sources/ImageRelayKit/Models/ItemIdentifier.swift
import Foundation

public struct ItemIdentifier: RawRepresentable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func folder(_ id: Int) -> ItemIdentifier {
        ItemIdentifier(rawValue: "folder-\(id)")
    }

    public static func file(_ id: Int) -> ItemIdentifier {
        ItemIdentifier(rawValue: "file-\(id)")
    }

    public var isFolder: Bool { rawValue.hasPrefix("folder-") }
    public var isFile: Bool { rawValue.hasPrefix("file-") }

    public var numericID: Int? {
        guard let dashIndex = rawValue.firstIndex(of: "-") else { return nil }
        return Int(rawValue[rawValue.index(after: dashIndex)...])
    }
}

// Failable initializer for parsing unknown strings
extension ItemIdentifier {
    public init?(rawValue: String) {
        guard rawValue.hasPrefix("folder-") || rawValue.hasPrefix("file-") else {
            return nil
        }
        guard let dashIndex = rawValue.firstIndex(of: "-"),
              Int(rawValue[rawValue.index(after: dashIndex)...]) != nil else {
            return nil
        }
        self.rawValue = rawValue
    }
}
```

- [ ] **Step 9: Add JSONDecoder extension**

```swift
// ImageRelayKit/Sources/ImageRelayKit/Models/JSONCoding.swift
import Foundation

extension JSONDecoder {
    public static let imageRelay: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()
}

extension JSONEncoder {
    public static let imageRelay: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
}
```

- [ ] **Step 10: Run tests**

Run: `cd ImageRelayKit && swift test --filter ModelsTests 2>&1 | tail -10`
Run: `cd ImageRelayKit && swift test --filter ItemIdentifierTests 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 11: Commit**

```bash
git add ImageRelayKit/Sources/ImageRelayKit/Models/ ImageRelayKit/Tests/
git commit -m "feat: add domain models (RemoteFolder, RemoteFile, QuickLink, UploadJob, ItemIdentifier)"
```

---

## Task 3: API Client — Rate Limiter

**Files:**
- Create: `ImageRelayKit/Sources/ImageRelayKit/API/RateLimiter.swift`
- Test: `ImageRelayKit/Tests/ImageRelayKitTests/RateLimiterTests.swift`

Token bucket rate limiter matching Image Relay's 5 req/s limit. This is actor-based for safe concurrency.

- [ ] **Step 1: Write rate limiter tests**

```swift
// ImageRelayKit/Tests/ImageRelayKitTests/RateLimiterTests.swift
import Testing
@testable import ImageRelayKit

@Suite("Rate Limiter")
struct RateLimiterTests {
    @Test("Allows requests within limit")
    func allowsWithinLimit() async {
        let limiter = RateLimiter(maxRequests: 3, period: 1.0)
        // Three requests should proceed without significant delay
        let start = ContinuousClock.now
        for _ in 0..<3 {
            await limiter.acquire()
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(100))
    }

    @Test("Throttles when exceeding limit")
    func throttlesOverLimit() async {
        let limiter = RateLimiter(maxRequests: 2, period: 0.5)
        // First two should be instant
        await limiter.acquire()
        await limiter.acquire()
        // Third should wait ~0.5s
        let start = ContinuousClock.now
        await limiter.acquire()
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(400))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ImageRelayKit && swift test --filter RateLimiterTests 2>&1 | head -20`
Expected: Compilation error — `RateLimiter` not defined.

- [ ] **Step 3: Implement RateLimiter**

```swift
// ImageRelayKit/Sources/ImageRelayKit/API/RateLimiter.swift
import Foundation

public actor RateLimiter {
    private let maxRequests: Int
    private let period: Duration
    private var timestamps: [ContinuousClock.Instant] = []

    public init(maxRequests: Int = 5, period: Double = 1.0) {
        self.maxRequests = maxRequests
        self.period = .seconds(period)
    }

    public func acquire() async {
        while true {
            let now = ContinuousClock.now
            timestamps.removeAll { now - $0 >= period }

            if timestamps.count < maxRequests {
                timestamps.append(now)
                return
            }

            let oldest = timestamps[0]
            let waitTime = period - (now - oldest)
            if waitTime > .zero {
                try? await Task.sleep(for: waitTime + .milliseconds(10))
            }
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd ImageRelayKit && swift test --filter RateLimiterTests 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add ImageRelayKit/Sources/ImageRelayKit/API/RateLimiter.swift ImageRelayKit/Tests/ImageRelayKitTests/RateLimiterTests.swift
git commit -m "feat: add actor-based rate limiter (5 req/s token bucket)"
```

---

## Task 4: API Client — Error Types and Pagination

**Files:**
- Create: `ImageRelayKit/Sources/ImageRelayKit/API/APIError.swift`
- Create: `ImageRelayKit/Sources/ImageRelayKit/API/Pagination.swift`
- Test: `ImageRelayKit/Tests/ImageRelayKitTests/PaginationTests.swift`

- [ ] **Step 1: Write pagination tests**

```swift
// ImageRelayKit/Tests/ImageRelayKitTests/PaginationTests.swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ImageRelayKit && swift test --filter PaginationTests 2>&1 | head -20`
Expected: Compilation error.

- [ ] **Step 3: Implement APIError**

```swift
// ImageRelayKit/Sources/ImageRelayKit/API/APIError.swift
import Foundation

public enum APIError: Error, Sendable {
    case notAuthenticated
    case forbidden
    case notFound(resource: String)
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(statusCode: Int, message: String?)
    case networkError(underlying: any Error)
    case decodingError(underlying: any Error)
    case invalidResponse

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .serverError(statusCode: 502, _),
             .serverError(statusCode: 503, _), .networkError:
            return true
        default:
            return false
        }
    }

    public var userMessage: String {
        switch self {
        case .notAuthenticated:
            return "Your API key is invalid or expired. Check Settings > General."
        case .forbidden:
            return "Your API key does not have permission for this action."
        case .notFound(let resource):
            return "The \(resource) was not found on Image Relay."
        case .rateLimited:
            return "Too many requests. The client will retry automatically."
        case .serverError(let code, _):
            return "Image Relay returned an error (\(code)). Will retry shortly."
        case .networkError:
            return "Cannot reach Image Relay. Check your internet connection."
        case .decodingError:
            return "Received an unexpected response from Image Relay."
        case .invalidResponse:
            return "Received an invalid response from Image Relay."
        }
    }
}
```

- [ ] **Step 4: Implement Pagination**

```swift
// ImageRelayKit/Sources/ImageRelayKit/API/Pagination.swift
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
```

- [ ] **Step 5: Run tests**

Run: `cd ImageRelayKit && swift test --filter PaginationTests 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add ImageRelayKit/Sources/ImageRelayKit/API/APIError.swift ImageRelayKit/Sources/ImageRelayKit/API/Pagination.swift ImageRelayKit/Tests/ImageRelayKitTests/PaginationTests.swift
git commit -m "feat: add APIError types and Link header / JSON pagination parsing"
```

---

## Task 5: API Client — Core APIClient

**Files:**
- Create: `ImageRelayKit/Sources/ImageRelayKit/API/APIClient.swift`
- Test: `ImageRelayKit/Tests/ImageRelayKitTests/APIClientTests.swift`

The core HTTP client wrapping URLSession with rate limiting, retry logic, and pagination. Tests use URLProtocol mocking.

- [ ] **Step 1: Write APIClient tests**

```swift
// ImageRelayKit/Tests/ImageRelayKitTests/APIClientTests.swift
import Testing
@testable import ImageRelayKit

// Mock URL protocol for testing
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocolDidFinishLoading(self)
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

@Suite("APIClient")
struct APIClientTests {
    let baseURL = URL(string: "https://api.test.imagerelay.com/api/v2")!

    func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: baseURL,
            apiKey: "test-key",
            userAgent: "TestAgent/1.0",
            sessionConfiguration: config,
            rateLimiter: RateLimiter(maxRequests: 100, period: 1.0)
        )
    }

    @Test("GET request includes auth and user-agent headers")
    func requestHeaders() async throws {
        MockURLProtocol.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic test-key")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "TestAgent/1.0")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, "[]".data(using: .utf8)!)
        }

        let client = makeClient()
        let _: [RemoteFolder] = try await client.get("/folders.json")
    }

    @Test("Decodes folder list from API response")
    func decodeFolderList() async throws {
        let json = """
        [{"id":1,"name":"Root","parent_id":null,"path":"/Root","updated_on":null,"child_count":2}]
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, json.data(using: .utf8)!)
        }

        let client = makeClient()
        let folders: [RemoteFolder] = try await client.get("/folders.json")
        #expect(folders.count == 1)
        #expect(folders[0].name == "Root")
    }

    @Test("401 throws notAuthenticated")
    func handles401() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        let client = makeClient()
        do {
            let _: [RemoteFolder] = try await client.get("/folders.json")
            Issue.record("Expected error")
        } catch let error as APIError {
            guard case .notAuthenticated = error else {
                Issue.record("Expected notAuthenticated, got \(error)")
                return
            }
        }
    }

    @Test("404 throws notFound")
    func handles404() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        let client = makeClient()
        do {
            let _: [RemoteFolder] = try await client.get("/folders/999.json")
            Issue.record("Expected error")
        } catch let error as APIError {
            guard case .notFound = error else {
                Issue.record("Expected notFound, got \(error)")
                return
            }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ImageRelayKit && swift test --filter APIClientTests 2>&1 | head -20`
Expected: Compilation error — `APIClient` not defined.

- [ ] **Step 3: Implement APIClient**

```swift
// ImageRelayKit/Sources/ImageRelayKit/API/APIClient.swift
import Foundation

public actor APIClient {
    private let baseURL: URL
    private let apiKey: String
    private let userAgent: String
    private let session: URLSession
    private let rateLimiter: RateLimiter
    private let maxRetries: Int
    private let maxRetryDelay: TimeInterval

    public init(
        baseURL: URL,
        apiKey: String,
        userAgent: String = "ImageRelayClient/1.0",
        sessionConfiguration: URLSessionConfiguration = .default,
        rateLimiter: RateLimiter = RateLimiter(),
        maxRetries: Int = 3,
        maxRetryDelay: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.userAgent = userAgent
        self.session = URLSession(configuration: sessionConfiguration)
        self.rateLimiter = rateLimiter
        self.maxRetries = maxRetries
        self.maxRetryDelay = maxRetryDelay
    }

    // MARK: - Public HTTP Methods

    public func get<T: Decodable & Sendable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let request = try buildRequest(method: "GET", path: path, query: query)
        return try await execute(request)
    }

    public func getAllPages<T: Decodable & Sendable>(_ path: String, query: [String: String] = [:]) async throws -> [T] {
        var allItems: [T] = []
        var currentQuery = query
        var page = 1

        while true {
            currentQuery["page"] = "\(page)"
            let request = try buildRequest(method: "GET", path: path, query: currentQuery)
            let (data, response) = try await executeRaw(request)

            let items = try JSONDecoder.imageRelay.decode([T].self, from: data)
            allItems.append(contentsOf: items)

            // Check Link header first, then fall back to item count
            if let linkHeader = response.value(forHTTPHeaderField: "Link"),
               Pagination.nextURL(fromLinkHeader: linkHeader) != nil {
                page += 1
                continue
            }

            // If fewer items than a full page, we're done
            if items.isEmpty {
                break
            }

            page += 1

            // Safety: if no pagination signal, stop after first page
            if response.value(forHTTPHeaderField: "Link") == nil {
                break
            }
        }

        return allItems
    }

    public func post<T: Decodable & Sendable>(_ path: String, body: any Encodable & Sendable) async throws -> T {
        let request = try buildRequest(method: "POST", path: path, body: body)
        return try await execute(request)
    }

    public func post(_ path: String, body: (any Encodable & Sendable)? = nil) async throws {
        let request = try buildRequest(method: "POST", path: path, body: body)
        let _: EmptyResponse = try await execute(request)
    }

    public func put<T: Decodable & Sendable>(_ path: String, body: any Encodable & Sendable) async throws -> T {
        let request = try buildRequest(method: "PUT", path: path, body: body)
        return try await execute(request)
    }

    public func delete(_ path: String) async throws {
        let request = try buildRequest(method: "DELETE", path: path)
        let _: EmptyResponse = try await execute(request)
    }

    public func download(_ url: URL, to destination: URL) async throws {
        await rateLimiter.acquire()
        let (tempURL, response) = try await session.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        try checkStatus(httpResponse, data: nil)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    public func upload(data: Data, to path: String, contentType: String = "application/octet-stream") async throws {
        var request = try buildRequest(method: "POST", path: path)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let _: EmptyResponse = try await execute(request)
    }

    // MARK: - Private

    private func buildRequest(
        method: String, path: String,
        query: [String: String] = [:],
        body: (any Encodable & Sendable)? = nil
    ) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Basic \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = try JSONEncoder.imageRelay.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        return request
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, _) = try await executeRaw(request)
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        do {
            return try JSONDecoder.imageRelay.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(underlying: error)
        }
    }

    private func executeRaw(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var lastError: (any Error)?

        for attempt in 0...maxRetries {
            if attempt > 0 {
                let delay = min(pow(2.0, Double(attempt - 1)), maxRetryDelay)
                try await Task.sleep(for: .seconds(delay))
            }

            await rateLimiter.acquire()

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                lastError = APIError.networkError(underlying: error)
                continue
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            do {
                try checkStatus(httpResponse, data: data)
                return (data, httpResponse)
            } catch let error as APIError where error.isRetryable && attempt < maxRetries {
                lastError = error
                continue
            }
        }

        throw lastError ?? APIError.invalidResponse
    }

    private func checkStatus(_ response: HTTPURLResponse, data: Data?) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 401:
            throw APIError.notAuthenticated
        case 403:
            throw APIError.forbidden
        case 404:
            throw APIError.notFound(resource: "resource")
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            throw APIError.rateLimited(retryAfter: retryAfter)
        default:
            let message = data.flatMap { String(data: $0, encoding: .utf8) }
            throw APIError.serverError(statusCode: response.statusCode, message: message)
        }
    }
}

private struct EmptyResponse: Decodable {
    init() {}
    init(from decoder: any Decoder) throws {}
}
```

- [ ] **Step 4: Run tests**

Run: `cd ImageRelayKit && swift test --filter APIClientTests 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add ImageRelayKit/Sources/ImageRelayKit/API/APIClient.swift ImageRelayKit/Tests/ImageRelayKitTests/APIClientTests.swift
git commit -m "feat: add async/await APIClient with rate limiting and retry logic"
```

---

## Task 6: Storage — Configuration

**Files:**
- Create: `ImageRelayKit/Sources/ImageRelayKit/Storage/Configuration.swift`
- Test: `ImageRelayKit/Tests/ImageRelayKitTests/ConfigurationTests.swift`

Shared configuration stored as JSON in the app group container, readable by both app and extension.

- [ ] **Step 1: Write configuration tests**

```swift
// ImageRelayKit/Tests/ImageRelayKitTests/ConfigurationTests.swift
import Testing
@testable import ImageRelayKit

@Suite("Configuration")
struct ConfigurationTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }

    @Test("Save and load configuration")
    func saveAndLoad() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var config = AppConfiguration.default
        config.apiKey = "my-key"
        config.remoteRootFolderID = 123
        config.defaultFileTypeID = 456

        try config.save(to: url)

        let loaded = try AppConfiguration.load(from: url)
        #expect(loaded.apiKey == "my-key")
        #expect(loaded.remoteRootFolderID == 123)
        #expect(loaded.defaultFileTypeID == 456)
        #expect(loaded.pollIntervalSeconds == 60)
    }

    @Test("Default configuration has sensible values")
    func defaults() {
        let config = AppConfiguration.default
        #expect(config.apiKey == "")
        #expect(config.pollIntervalSeconds == 60)
        #expect(config.syncUpload == true)
        #expect(config.syncDownload == true)
    }

    @Test("Load returns default when file missing")
    func missingFile() throws {
        let url = tempURL()
        let loaded = try AppConfiguration.load(from: url)
        #expect(loaded.apiKey == "")
    }

    @Test("isConfigured requires API key and root folder")
    func isConfigured() {
        var config = AppConfiguration.default
        #expect(config.isConfigured == false)

        config.apiKey = "key"
        #expect(config.isConfigured == false)

        config.remoteRootFolderID = 1
        #expect(config.isConfigured == true)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ImageRelayKit && swift test --filter ConfigurationTests 2>&1 | head -20`
Expected: Compilation error.

- [ ] **Step 3: Implement Configuration**

```swift
// ImageRelayKit/Sources/ImageRelayKit/Storage/Configuration.swift
import Foundation

public struct AppConfiguration: Codable, Sendable {
    public var apiKey: String
    public var remoteRootFolderID: Int?
    public var defaultFileTypeID: Int?
    public var pollIntervalSeconds: Int
    public var syncUpload: Bool
    public var syncDownload: Bool
    public var userAgent: String

    public var isConfigured: Bool {
        !apiKey.isEmpty && remoteRootFolderID != nil
    }

    public var baseURL: URL {
        URL(string: "https://api.imagerelay.com/api/v2")!
    }

    public static let `default` = AppConfiguration(
        apiKey: "",
        remoteRootFolderID: nil,
        defaultFileTypeID: nil,
        pollIntervalSeconds: 60,
        syncUpload: true,
        syncDownload: true,
        userAgent: "ImageRelayClient/1.0 (macOS)"
    )

    public func save(to url: URL) throws {
        let data = try JSONEncoder.imageRelay.encode(self)
        try data.write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .default
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.imageRelay.decode(AppConfiguration.self, from: data)
    }

    /// URL for the configuration file in a container directory
    public static func fileURL(in container: URL) -> URL {
        container.appendingPathComponent("config.json")
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd ImageRelayKit && swift test --filter ConfigurationTests 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add ImageRelayKit/Sources/ImageRelayKit/Storage/Configuration.swift ImageRelayKit/Tests/ImageRelayKitTests/ConfigurationTests.swift
git commit -m "feat: add shared AppConfiguration with JSON persistence"
```

---

## Task 7: Storage — GRDB Database

**Files:**
- Create: `ImageRelayKit/Sources/ImageRelayKit/Storage/SyncDatabase.swift`
- Create: `ImageRelayKit/Sources/ImageRelayKit/Storage/ActivityLog.swift`
- Test: `ImageRelayKit/Tests/ImageRelayKitTests/SyncDatabaseTests.swift`

GRDB-backed SQLite database in the app group container. Tracks item mappings, sync anchors, pin state, and activity.

- [ ] **Step 1: Write database tests**

```swift
// ImageRelayKit/Tests/ImageRelayKitTests/SyncDatabaseTests.swift
import Testing
import GRDB
@testable import ImageRelayKit

@Suite("SyncDatabase")
struct SyncDatabaseTests {
    func makeDB() throws -> SyncDatabase {
        try SyncDatabase(path: ":memory:")
    }

    @Test("Insert and retrieve tracked item")
    func insertAndRetrieve() throws {
        let db = try makeDB()

        let item = TrackedItem(
            identifier: "file-123",
            parentIdentifier: "folder-456",
            remoteID: 123,
            itemType: .file,
            name: "photo.jpg",
            size: 1024,
            contentVersion: "v1",
            metadataVersion: "m1",
            isPinned: false
        )

        try db.upsertItem(item)
        let retrieved = try db.item(for: "file-123")
        #expect(retrieved?.name == "photo.jpg")
        #expect(retrieved?.size == 1024)
        #expect(retrieved?.itemType == .file)
    }

    @Test("List children of a parent")
    func listChildren() throws {
        let db = try makeDB()

        let folder = TrackedItem(
            identifier: "folder-10", parentIdentifier: "root",
            remoteID: 10, itemType: .folder, name: "Photos",
            size: 0, contentVersion: "v1", metadataVersion: "m1", isPinned: false
        )
        let file1 = TrackedItem(
            identifier: "file-20", parentIdentifier: "folder-10",
            remoteID: 20, itemType: .file, name: "a.jpg",
            size: 100, contentVersion: "v1", metadataVersion: "m1", isPinned: false
        )
        let file2 = TrackedItem(
            identifier: "file-21", parentIdentifier: "folder-10",
            remoteID: 21, itemType: .file, name: "b.jpg",
            size: 200, contentVersion: "v1", metadataVersion: "m1", isPinned: false
        )

        try db.upsertItem(folder)
        try db.upsertItem(file1)
        try db.upsertItem(file2)

        let children = try db.children(of: "folder-10")
        #expect(children.count == 2)
    }

    @Test("Delete item by identifier")
    func deleteItem() throws {
        let db = try makeDB()

        let item = TrackedItem(
            identifier: "file-99", parentIdentifier: "folder-1",
            remoteID: 99, itemType: .file, name: "delete-me.png",
            size: 50, contentVersion: "v1", metadataVersion: "m1", isPinned: false
        )
        try db.upsertItem(item)
        try db.deleteItem("file-99")
        let retrieved = try db.item(for: "file-99")
        #expect(retrieved == nil)
    }

    @Test("Save and load sync anchor")
    func syncAnchor() throws {
        let db = try makeDB()

        try db.setSyncAnchor(Data("anchor-1".utf8), for: "root")
        let loaded = try db.syncAnchor(for: "root")
        #expect(loaded == Data("anchor-1".utf8))
    }

    @Test("Log and retrieve activity")
    func activityLog() throws {
        let db = try makeDB()

        try db.logActivity(action: .downloaded, itemName: "photo.jpg", itemType: .file)
        try db.logActivity(action: .uploaded, itemName: "doc.pdf", itemType: .file)

        let entries = try db.recentActivity(limit: 10)
        #expect(entries.count == 2)
        #expect(entries[0].itemName == "doc.pdf") // Most recent first
        #expect(entries[1].itemName == "photo.jpg")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ImageRelayKit && swift test --filter SyncDatabaseTests 2>&1 | head -20`
Expected: Compilation error.

- [ ] **Step 3: Implement TrackedItem and ActivityEntry models**

```swift
// ImageRelayKit/Sources/ImageRelayKit/Storage/ActivityLog.swift
import Foundation
import GRDB

public enum SyncAction: String, Codable, Sendable, DatabaseValueConvertible {
    case downloaded, uploaded, deleted, renamed, moved, conflicted, created
}

public enum TrackedItemType: String, Codable, Sendable, DatabaseValueConvertible {
    case file, folder
}

public struct TrackedItem: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tracked_items"

    public var identifier: String
    public var parentIdentifier: String
    public var remoteID: Int
    public var itemType: TrackedItemType
    public var name: String
    public var size: Int64
    public var contentVersion: String
    public var metadataVersion: String
    public var isPinned: Bool

    public init(
        identifier: String, parentIdentifier: String, remoteID: Int,
        itemType: TrackedItemType, name: String, size: Int64,
        contentVersion: String, metadataVersion: String, isPinned: Bool
    ) {
        self.identifier = identifier
        self.parentIdentifier = parentIdentifier
        self.remoteID = remoteID
        self.itemType = itemType
        self.name = name
        self.size = size
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
        self.isPinned = isPinned
    }
}

public struct ActivityEntry: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "activity_log"

    public var id: Int64?
    public var action: SyncAction
    public var itemName: String
    public var itemType: TrackedItemType
    public var timestamp: Date

    public init(action: SyncAction, itemName: String, itemType: TrackedItemType, timestamp: Date = Date()) {
        self.action = action
        self.itemName = itemName
        self.itemType = itemType
        self.timestamp = timestamp
    }
}
```

- [ ] **Step 4: Implement SyncDatabase**

```swift
// ImageRelayKit/Sources/ImageRelayKit/Storage/SyncDatabase.swift
import Foundation
import GRDB

public final class SyncDatabase: Sendable {
    private let dbPool: DatabasePool

    public init(path: String) throws {
        if path == ":memory:" {
            // In-memory database for testing
            dbPool = try DatabasePool(path: "")
        } else {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            dbPool = try DatabasePool(path: path)
        }
        try migrate()
    }

    /// Convenience: create database at a URL
    public convenience init(url: URL) throws {
        try self.init(path: url.path)
    }

    public static func databaseURL(in container: URL) -> URL {
        container.appendingPathComponent("sync.db")
    }

    // MARK: - Migrations

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "tracked_items") { t in
                t.primaryKey("identifier", .text).notNull()
                t.column("parentIdentifier", .text).notNull().indexed()
                t.column("remoteID", .integer).notNull()
                t.column("itemType", .text).notNull()
                t.column("name", .text).notNull()
                t.column("size", .integer).notNull().defaults(to: 0)
                t.column("contentVersion", .text).notNull()
                t.column("metadataVersion", .text).notNull()
                t.column("isPinned", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "sync_anchors") { t in
                t.primaryKey("containerID", .text).notNull()
                t.column("anchor", .blob).notNull()
            }

            try db.create(table: "activity_log") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("action", .text).notNull()
                t.column("itemName", .text).notNull()
                t.column("itemType", .text).notNull()
                t.column("timestamp", .datetime).notNull()
            }
        }

        try migrator.migrate(dbPool)
    }

    // MARK: - Tracked Items

    public func upsertItem(_ item: TrackedItem) throws {
        try dbPool.write { db in
            try item.save(db, onConflict: .replace)
        }
    }

    public func item(for identifier: String) throws -> TrackedItem? {
        try dbPool.read { db in
            try TrackedItem.fetchOne(db, key: identifier)
        }
    }

    public func children(of parentIdentifier: String) throws -> [TrackedItem] {
        try dbPool.read { db in
            try TrackedItem
                .filter(Column("parentIdentifier") == parentIdentifier)
                .fetchAll(db)
        }
    }

    public func deleteItem(_ identifier: String) throws {
        try dbPool.write { db in
            try TrackedItem.deleteOne(db, key: identifier)
        }
    }

    public func allItems() throws -> [TrackedItem] {
        try dbPool.read { db in
            try TrackedItem.fetchAll(db)
        }
    }

    public func pinnedFolders() throws -> [TrackedItem] {
        try dbPool.read { db in
            try TrackedItem
                .filter(Column("itemType") == TrackedItemType.folder.rawValue)
                .filter(Column("isPinned") == true)
                .fetchAll(db)
        }
    }

    // MARK: - Sync Anchors

    public func syncAnchor(for containerID: String) throws -> Data? {
        try dbPool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT anchor FROM sync_anchors WHERE containerID = ?",
                arguments: [containerID]
            )?["anchor"]
        }
    }

    public func setSyncAnchor(_ anchor: Data, for containerID: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO sync_anchors (containerID, anchor)
                VALUES (?, ?)
                ON CONFLICT(containerID) DO UPDATE SET anchor = excluded.anchor
                """,
                arguments: [containerID, anchor]
            )
        }
    }

    // MARK: - Activity Log

    public func logActivity(action: SyncAction, itemName: String, itemType: TrackedItemType) throws {
        try dbPool.write { db in
            var entry = ActivityEntry(action: action, itemName: itemName, itemType: itemType)
            try entry.insert(db)
        }
    }

    public func recentActivity(limit: Int = 20) throws -> [ActivityEntry] {
        try dbPool.read { db in
            try ActivityEntry
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }
}
```

- [ ] **Step 5: Run tests**

Run: `cd ImageRelayKit && swift test --filter SyncDatabaseTests 2>&1 | tail -15`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add ImageRelayKit/Sources/ImageRelayKit/Storage/ ImageRelayKit/Tests/ImageRelayKitTests/SyncDatabaseTests.swift
git commit -m "feat: add GRDB-backed SyncDatabase with tracked items, sync anchors, and activity log"
```

---

## Task 8: Sync — Anchor and Conflict Resolver

**Files:**
- Create: `ImageRelayKit/Sources/ImageRelayKit/Sync/SyncAnchor.swift`
- Create: `ImageRelayKit/Sources/ImageRelayKit/Sync/ConflictResolver.swift`
- Test: `ImageRelayKit/Tests/ImageRelayKitTests/ConflictResolverTests.swift`

- [ ] **Step 1: Write conflict resolver tests**

```swift
// ImageRelayKit/Tests/ImageRelayKitTests/ConflictResolverTests.swift
import Testing
@testable import ImageRelayKit

@Suite("ConflictResolver")
struct ConflictResolverTests {
    @Test("Generates conflict name with timestamp pattern")
    func conflictName() {
        let name = ConflictResolver.conflictName(for: "photo.jpg")
        #expect(name.hasPrefix("photo (imagerelay conflict"))
        #expect(name.hasSuffix(".jpg"))
        #expect(name.contains("imagerelay conflict"))
    }

    @Test("Handles files without extension")
    func noExtension() {
        let name = ConflictResolver.conflictName(for: "README")
        #expect(name.hasPrefix("README (imagerelay conflict"))
        #expect(!name.contains("."))
    }

    @Test("Conflict name for dotfile")
    func dotfile() {
        let name = ConflictResolver.conflictName(for: ".gitignore")
        #expect(name.hasPrefix(".gitignore (imagerelay conflict"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ImageRelayKit && swift test --filter ConflictResolverTests 2>&1 | head -20`
Expected: Compilation error.

- [ ] **Step 3: Implement SyncAnchor**

```swift
// ImageRelayKit/Sources/ImageRelayKit/Sync/SyncAnchor.swift
import Foundation

/// Opaque sync anchor for File Provider change enumeration.
/// Wraps a monotonically increasing integer that the extension bumps
/// each time it processes remote changes.
public struct SyncAnchor: Sendable {
    public let version: UInt64

    public init(version: UInt64 = 0) {
        self.version = version
    }

    public func incremented() -> SyncAnchor {
        SyncAnchor(version: version + 1)
    }

    public var data: Data {
        withUnsafeBytes(of: version.bigEndian) { Data($0) }
    }

    public init?(data: Data) {
        guard data.count == MemoryLayout<UInt64>.size else { return nil }
        let value = data.withUnsafeBytes { $0.load(as: UInt64.self) }
        self.version = UInt64(bigEndian: value)
    }
}
```

- [ ] **Step 4: Implement ConflictResolver**

```swift
// ImageRelayKit/Sources/ImageRelayKit/Sync/ConflictResolver.swift
import Foundation

public enum ConflictResolver {
    /// Generate a conflict filename following the pattern:
    /// "photo (imagerelay conflict 2026-04-06 143022).jpg"
    public static func conflictName(for originalName: String) -> String {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let url = URL(fileURLWithPath: originalName)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent

        if ext.isEmpty {
            return "\(stem) (imagerelay conflict \(timestamp))"
        }
        return "\(stem) (imagerelay conflict \(timestamp)).\(ext)"
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
```

- [ ] **Step 5: Run tests**

Run: `cd ImageRelayKit && swift test --filter ConflictResolverTests 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add ImageRelayKit/Sources/ImageRelayKit/Sync/ ImageRelayKit/Tests/ImageRelayKitTests/ConflictResolverTests.swift
git commit -m "feat: add SyncAnchor and ConflictResolver (conservative conflict strategy)"
```

---

## Task 9: XcodeGen Project Configuration

**Files:**
- Create: `Project.yml`
- Create: `ImageRelayClient/App.swift` (stub)
- Create: `FileProviderExtension/Extension.swift` (stub)
- Create: `ImageRelayClient/ImageRelayClient.entitlements`
- Create: `FileProviderExtension/FileProviderExtension.entitlements`
- Create: `FileProviderExtension/Info.plist`

This task generates the Xcode project with both targets linked to ImageRelayKit. Use the /xcodegen-project skill for reference on Project.yml format.

- [ ] **Step 1: Create entitlements for host app**

```xml
<!-- ImageRelayClient/ImageRelayClient.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>$(TeamIdentifierPrefix)com.oliverames.imagerelay-client</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: Create entitlements for File Provider extension**

```xml
<!-- FileProviderExtension/FileProviderExtension.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>$(TeamIdentifierPrefix)com.oliverames.imagerelay-client</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 3: Create Info.plist for File Provider extension**

```xml
<!-- FileProviderExtension/Info.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionFileProviderDocumentGroup</key>
        <string>$(TeamIdentifierPrefix)com.oliverames.imagerelay-client</string>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.fileprovider-nonui</string>
        <key>NSExtensionPrincipalClass</key>
        <string>$(PRODUCT_MODULE_NAME).Extension</string>
    </dict>
    <key>CFBundleSymbolName</key>
    <string>cloud</string>
</dict>
</plist>
```

- [ ] **Step 4: Create Project.yml**

```yaml
# Project.yml
name: ImageRelayClient
options:
  minimumXcodeGenVersion: "2.42"
  deploymentTarget:
    macOS: "26.0"
  bundleIdPrefix: com.oliverames
  xcodeVersion: "26"
  groupSortPosition: top

packages:
  ImageRelayKit:
    path: ImageRelayKit

settings:
  base:
    SWIFT_VERSION: "6.0"
    MACOSX_DEPLOYMENT_TARGET: "26.0"
    DEVELOPMENT_TEAM: ""

targets:
  ImageRelayClient:
    type: application
    platform: macOS
    sources:
      - path: ImageRelayClient
    dependencies:
      - package: ImageRelayKit
      - target: FileProviderExtension
        embed: true
        codeSign: false
    entitlements:
      path: ImageRelayClient/ImageRelayClient.entitlements
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.oliverames.imagerelay-client
        INFOPLIST_KEY_LSUIElement: true
        INFOPLIST_KEY_CFBundleDisplayName: "ImageRelay Client"
    info:
      path: ImageRelayClient/Info.plist
      properties:
        LSMinimumSystemVersion: "$(MACOSX_DEPLOYMENT_TARGET)"
        CFBundleDisplayName: "ImageRelay Client"
        LSUIElement: true

  FileProviderExtension:
    type: file-provider
    platform: macOS
    sources:
      - path: FileProviderExtension
    dependencies:
      - package: ImageRelayKit
    entitlements:
      path: FileProviderExtension/FileProviderExtension.entitlements
    info:
      path: FileProviderExtension/Info.plist
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.oliverames.imagerelay-client.fileprovider
```

- [ ] **Step 5: Create stub App.swift**

```swift
// ImageRelayClient/App.swift
import SwiftUI

@main
struct ImageRelayClientApp: App {
    var body: some Scene {
        MenuBarExtra("ImageRelay", systemImage: "cloud") {
            Text("ImageRelay Client")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }

        Settings {
            Text("Settings coming soon")
                .frame(width: 400, height: 300)
        }
    }
}
```

- [ ] **Step 6: Create stub Extension.swift**

```swift
// FileProviderExtension/Extension.swift
import FileProvider
import ImageRelayKit
import os.log

final class Extension: NSObject, NSFileProviderReplicatedExtension {
    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client.fileprovider", category: "Extension")
    let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        logger.info("File Provider extension initialized for domain: \(domain.displayName)")
    }

    func invalidate() {
        logger.info("File Provider extension invalidated")
    }

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, NSFileProviderError(.noSuchItem))
        return Progress()
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Bool, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, nil, false, NSFileProviderError(.noSuchItem))
        return Progress()
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
        return Progress()
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
        return Progress()
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        completionHandler(NSFileProviderError(.noSuchItem))
        return Progress()
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        throw NSFileProviderError(.noSuchItem)
    }
}
```

- [ ] **Step 7: Generate Xcode project**

Run: `cd "/path/to/imagerelay-client" && xcodegen generate`
Expected: "Generated project: ImageRelayClient.xcodeproj"

- [ ] **Step 8: Verify project opens**

Run: `open ImageRelayClient.xcodeproj`
Expected: Xcode opens with both targets visible.

- [ ] **Step 9: Commit**

```bash
git add Project.yml ImageRelayClient/ FileProviderExtension/ ImageRelayClient.xcodeproj
echo "ImageRelayClient.xcodeproj/xcuserdata/" >> .gitignore
git add .gitignore
git commit -m "feat: scaffold Xcode project with host app and File Provider extension targets"
```

---

## Task 10: File Provider — FileProviderItem

**Files:**
- Create: `FileProviderExtension/FileProviderItem.swift`

The `NSFileProviderItemProtocol` implementation that bridges between `TrackedItem`/API models and what Finder displays.

- [ ] **Step 1: Implement FileProviderItem**

```swift
// FileProviderExtension/FileProviderItem.swift
import FileProvider
import ImageRelayKit
import UniformTypeIdentifiers

final class FileProviderItem: NSObject, NSFileProviderItem {
    let identifier: NSFileProviderItemIdentifier
    let parentIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let itemVersion: NSFileProviderItemVersion
    let contentModificationDate: Date?

    private let _capabilities: NSFileProviderItemCapabilities

    var capabilities: NSFileProviderItemCapabilities { _capabilities }

    /// Create from a tracked database item
    init(trackedItem: TrackedItem) {
        self.identifier = NSFileProviderItemIdentifier(trackedItem.identifier)
        self.parentIdentifier = trackedItem.parentIdentifier == "root"
            ? .rootContainer
            : NSFileProviderItemIdentifier(trackedItem.parentIdentifier)
        self.filename = trackedItem.name
        self.documentSize = NSNumber(value: trackedItem.size)
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: Data(trackedItem.contentVersion.utf8),
            metadataVersion: Data(trackedItem.metadataVersion.utf8)
        )
        self.contentModificationDate = nil

        if trackedItem.itemType == .folder {
            self.contentType = .folder
            self._capabilities = [.allowsReading, .allowsWriting, .allowsRenaming,
                                  .allowsDeleting, .allowsAddingSubItems]
        } else {
            self.contentType = UTType(filenameExtension: URL(fileURLWithPath: trackedItem.name).pathExtension) ?? .data
            self._capabilities = [.allowsReading, .allowsWriting, .allowsRenaming,
                                  .allowsReparenting, .allowsDeleting]
        }
        super.init()
    }

    /// Create from an API RemoteFolder
    init(folder: RemoteFolder, parentIdentifier: NSFileProviderItemIdentifier) {
        let id = ItemIdentifier.folder(folder.id)
        self.identifier = NSFileProviderItemIdentifier(id.rawValue)
        self.parentIdentifier = parentIdentifier
        self.filename = folder.name
        self.contentType = .folder
        self.documentSize = nil
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: Data((folder.updatedOn ?? "0").utf8),
            metadataVersion: Data((folder.updatedOn ?? "0").utf8)
        )
        self.contentModificationDate = nil
        self._capabilities = [.allowsReading, .allowsWriting, .allowsRenaming,
                              .allowsDeleting, .allowsAddingSubItems]
        super.init()
    }

    /// Create from an API RemoteFile
    init(file: RemoteFile, parentIdentifier: NSFileProviderItemIdentifier) {
        let id = ItemIdentifier.file(file.id)
        self.identifier = NSFileProviderItemIdentifier(id.rawValue)
        self.parentIdentifier = parentIdentifier
        self.filename = file.name
        self.contentType = UTType(filenameExtension: URL(fileURLWithPath: file.name).pathExtension) ?? .data
        self.documentSize = NSNumber(value: file.size)
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: Data((file.updatedOn ?? "0").utf8),
            metadataVersion: Data((file.updatedOn ?? "0").utf8)
        )
        self.contentModificationDate = nil
        self._capabilities = [.allowsReading, .allowsWriting, .allowsRenaming,
                              .allowsReparenting, .allowsDeleting]
        super.init()
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: Build the FileProviderExtension target in Xcode.
Expected: Compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add FileProviderExtension/FileProviderItem.swift
git commit -m "feat: add FileProviderItem bridging API models to NSFileProviderItemProtocol"
```

---

## Task 11: File Provider — Enumerator

**Files:**
- Create: `FileProviderExtension/Enumerator.swift`

The `NSFileProviderEnumerator` that lists folders/files from the Image Relay API and supports change enumeration via sync anchors.

- [ ] **Step 1: Implement Enumerator**

```swift
// FileProviderExtension/Enumerator.swift
import FileProvider
import ImageRelayKit
import os.log

final class Enumerator: NSObject, NSFileProviderEnumerator {
    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client.fileprovider", category: "Enumerator")
    private let containerIdentifier: NSFileProviderItemIdentifier
    private let api: APIClient
    private let db: SyncDatabase
    private let config: AppConfiguration

    init(
        containerIdentifier: NSFileProviderItemIdentifier,
        api: APIClient,
        db: SyncDatabase,
        config: AppConfiguration
    ) {
        self.containerIdentifier = containerIdentifier
        self.api = api
        self.db = db
        self.config = config
        super.init()
    }

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        Task {
            do {
                let items = try await fetchItems()
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                logger.error("Enumeration failed: \(error.localizedDescription)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from syncAnchor: NSFileProviderSyncAnchor
    ) {
        Task {
            do {
                let currentAnchor = SyncAnchor(data: syncAnchor.rawValue)
                let items = try await fetchItems()

                // Report all items as updated (full re-enumeration approach)
                // A production app would diff against the anchor
                observer.didUpdate(items)

                let newAnchor = (currentAnchor ?? SyncAnchor()).incremented()
                let providerAnchor = NSFileProviderSyncAnchor(newAnchor.data)
                try db.setSyncAnchor(newAnchor.data, for: containerIdentifier.rawValue)

                observer.finishEnumeratingChanges(upTo: providerAnchor, moreComing: false)
            } catch {
                logger.error("Change enumeration failed: \(error.localizedDescription)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        do {
            if let data = try db.syncAnchor(for: containerIdentifier.rawValue) {
                completionHandler(NSFileProviderSyncAnchor(data))
            } else {
                let initial = SyncAnchor().data
                completionHandler(NSFileProviderSyncAnchor(initial))
            }
        } catch {
            completionHandler(nil)
        }
    }

    // MARK: - Private

    private func fetchItems() async throws -> [NSFileProviderItem] {
        let folderID = resolveContainerFolderID()

        // Fetch child folders
        let folders: [RemoteFolder] = try await api.get(
            "/folders/\(folderID)/children.json"
        )

        // Fetch files in this folder
        let files: [RemoteFile] = try await api.get(
            "/folders/\(folderID)/files.json",
            query: ["recursive": "false"]
        )

        var items: [NSFileProviderItem] = []

        for folder in folders {
            let item = FileProviderItem(folder: folder, parentIdentifier: containerIdentifier)
            items.append(item)

            // Track in database
            let tracked = TrackedItem(
                identifier: ItemIdentifier.folder(folder.id).rawValue,
                parentIdentifier: containerIdentifier.rawValue,
                remoteID: folder.id,
                itemType: .folder,
                name: folder.name,
                size: 0,
                contentVersion: folder.updatedOn ?? "0",
                metadataVersion: folder.updatedOn ?? "0",
                isPinned: false
            )
            try db.upsertItem(tracked)
        }

        for file in files where !file.isDeleted {
            let item = FileProviderItem(file: file, parentIdentifier: containerIdentifier)
            items.append(item)

            let tracked = TrackedItem(
                identifier: ItemIdentifier.file(file.id).rawValue,
                parentIdentifier: containerIdentifier.rawValue,
                remoteID: file.id,
                itemType: .file,
                name: file.name,
                size: Int64(file.size),
                contentVersion: file.updatedOn ?? "0",
                metadataVersion: file.updatedOn ?? "0",
                isPinned: false
            )
            try db.upsertItem(tracked)
        }

        return items
    }

    private func resolveContainerFolderID() -> Int {
        if containerIdentifier == .rootContainer {
            return config.remoteRootFolderID ?? 0
        }
        guard let itemID = ItemIdentifier(rawValue: containerIdentifier.rawValue),
              let numericID = itemID.numericID else {
            return 0
        }
        return numericID
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: Build the FileProviderExtension target in Xcode.
Expected: Compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add FileProviderExtension/Enumerator.swift
git commit -m "feat: add File Provider enumerator with API-backed folder/file listing"
```

---

## Task 12: File Provider — Full Extension Implementation

**Files:**
- Modify: `FileProviderExtension/Extension.swift`

Replace the stubs with real implementations that delegate to the API client for downloads, uploads, deletes, and moves.

- [ ] **Step 1: Implement full Extension.swift**

```swift
// FileProviderExtension/Extension.swift
import FileProvider
import ImageRelayKit
import os.log

final class Extension: NSObject, NSFileProviderReplicatedExtension {
    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client.fileprovider", category: "Extension")
    let domain: NSFileProviderDomain

    private let api: APIClient
    private let db: SyncDatabase
    private let config: AppConfiguration

    required init(domain: NSFileProviderDomain) {
        self.domain = domain

        // Load configuration from app group container
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.oliverames.imagerelay-client"
        )!
        let configURL = AppConfiguration.fileURL(in: container)
        let loadedConfig = (try? AppConfiguration.load(from: configURL)) ?? .default
        self.config = loadedConfig

        self.api = APIClient(
            baseURL: loadedConfig.baseURL,
            apiKey: loadedConfig.apiKey,
            userAgent: loadedConfig.userAgent
        )

        let dbURL = SyncDatabase.databaseURL(in: container)
        self.db = (try? SyncDatabase(url: dbURL)) ?? {
            fatalError("Failed to open sync database at \(dbURL)")
        }()

        super.init()
        logger.info("File Provider extension initialized for domain: \(domain.displayName)")
    }

    func invalidate() {
        logger.info("File Provider extension invalidated")
    }

    // MARK: - Item Lookup

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        Task {
            do {
                if let tracked = try db.item(for: identifier.rawValue) {
                    completionHandler(FileProviderItem(trackedItem: tracked), nil)
                } else {
                    completionHandler(nil, NSFileProviderError(.noSuchItem))
                }
            } catch {
                completionHandler(nil, error)
            }
        }
        return Progress()
    }

    // MARK: - Download

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                guard let tracked = try db.item(for: itemIdentifier.rawValue),
                      let itemID = ItemIdentifier(rawValue: itemIdentifier.rawValue),
                      let fileID = itemID.numericID else {
                    completionHandler(nil, nil, false, NSFileProviderError(.noSuchItem))
                    return
                }

                // Create quick link for download
                let quickLink: QuickLink = try await api.post(
                    "/quick_links.json",
                    body: ["file_id": fileID, "purpose": "download"]
                )

                progress.completedUnitCount = 30

                // Download to temp location
                let tempDir = FileManager.default.temporaryDirectory
                let tempFile = tempDir.appendingPathComponent(tracked.name)
                if FileManager.default.fileExists(atPath: tempFile.path) {
                    try FileManager.default.removeItem(at: tempFile)
                }

                try await api.download(quickLink.url, to: tempFile)
                progress.completedUnitCount = 90

                // Clean up quick link
                try? await api.delete("/quick_links/\(quickLink.id).json")
                progress.completedUnitCount = 100

                // Log activity
                try? db.logActivity(action: .downloaded, itemName: tracked.name, itemType: .file)

                let item = FileProviderItem(trackedItem: tracked)
                completionHandler(tempFile, item, false, nil)
            } catch {
                logger.error("Download failed for \(itemIdentifier.rawValue): \(error.localizedDescription)")
                completionHandler(nil, nil, false, mapToFileProviderError(error))
            }
        }

        return progress
    }

    // MARK: - Create

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        Task {
            do {
                let parentFolderID = resolveParentFolderID(itemTemplate.parentItemIdentifier)

                if itemTemplate.contentType == .folder {
                    // Create folder
                    let folder: RemoteFolder = try await api.post(
                        "/folders.json",
                        body: ["name": itemTemplate.filename, "parent_id": parentFolderID]
                    )

                    let tracked = TrackedItem(
                        identifier: ItemIdentifier.folder(folder.id).rawValue,
                        parentIdentifier: itemTemplate.parentItemIdentifier.rawValue,
                        remoteID: folder.id, itemType: .folder, name: folder.name,
                        size: 0, contentVersion: folder.updatedOn ?? "0",
                        metadataVersion: folder.updatedOn ?? "0", isPinned: false
                    )
                    try db.upsertItem(tracked)
                    try? db.logActivity(action: .created, itemName: folder.name, itemType: .folder)

                    let item = FileProviderItem(trackedItem: tracked)
                    completionHandler(item, [], false, nil)
                } else if let contentURL = url {
                    // Upload file via upload job
                    let fileData = try Data(contentsOf: contentURL)

                    struct UploadJobRequest: Encodable {
                        let folder_id: Int
                        let file_type_id: Int
                        let terms: [Term]
                        struct Term: Encodable {
                            let term: String
                            let value: String
                        }
                    }

                    let jobRequest = UploadJobRequest(
                        folder_id: parentFolderID,
                        file_type_id: config.defaultFileTypeID ?? 0,
                        terms: [.init(term: "file_name", value: itemTemplate.filename)]
                    )

                    let job: UploadJob = try await api.post("/upload_jobs.json", body: jobRequest)

                    // Upload chunks (single chunk for simplicity; chunk large files in production)
                    try await api.upload(
                        data: fileData,
                        to: "/upload_jobs/\(job.id)/files/1/chunks/1"
                    )

                    // Wait for completion
                    var completedJob = job
                    for _ in 0..<30 {
                        try await Task.sleep(for: .seconds(2))
                        completedJob = try await api.get("/upload_jobs/\(job.id).json")
                        if completedJob.status == "complete" { break }
                    }

                    guard let fileID = completedJob.fileID else {
                        completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
                        return
                    }

                    let tracked = TrackedItem(
                        identifier: ItemIdentifier.file(fileID).rawValue,
                        parentIdentifier: itemTemplate.parentItemIdentifier.rawValue,
                        remoteID: fileID, itemType: .file, name: itemTemplate.filename,
                        size: Int64(fileData.count), contentVersion: "1",
                        metadataVersion: "1", isPinned: false
                    )
                    try db.upsertItem(tracked)
                    try? db.logActivity(action: .uploaded, itemName: itemTemplate.filename, itemType: .file)

                    let item = FileProviderItem(trackedItem: tracked)
                    completionHandler(item, [], false, nil)
                } else {
                    completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                }
            } catch {
                logger.error("Create failed: \(error.localizedDescription)")
                completionHandler(nil, [], false, mapToFileProviderError(error))
            }
        }
        return Progress()
    }

    // MARK: - Modify

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        Task {
            do {
                guard let tracked = try db.item(for: item.itemIdentifier.rawValue),
                      let itemID = ItemIdentifier(rawValue: item.itemIdentifier.rawValue),
                      let remoteID = itemID.numericID else {
                    completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                    return
                }

                var updated = tracked

                // Handle content change (file version upload)
                if changedFields.contains(.contents), let contentURL = newContents, itemID.isFile {
                    let fileData = try Data(contentsOf: contentURL)

                    struct VersionRequest: Codable { }
                    let versionResponse: [String: String] = try await api.post(
                        "/files/\(remoteID)/versions.json",
                        body: VersionRequest()
                    )

                    if let uuid = versionResponse["uuid"] {
                        try await api.upload(
                            data: fileData,
                            to: "/files/\(remoteID)/versions/\(uuid)/chunk/1"
                        )
                        try await api.post("/files/\(remoteID)/versions/\(uuid)/complete.json")
                    }

                    updated.size = Int64(fileData.count)
                    updated.contentVersion = UUID().uuidString
                    try? db.logActivity(action: .uploaded, itemName: tracked.name, itemType: .file)
                }

                // Handle rename
                if changedFields.contains(.filename) {
                    if itemID.isFolder {
                        let _: RemoteFolder = try await api.put(
                            "/folders/\(remoteID).json",
                            body: ["name": item.filename]
                        )
                    }
                    updated.name = item.filename
                    try? db.logActivity(action: .renamed, itemName: item.filename, itemType: tracked.itemType)
                }

                // Handle reparent (move)
                if changedFields.contains(.parentItemIdentifier), itemID.isFile {
                    let newParentID = resolveParentFolderID(item.parentItemIdentifier)
                    try await api.post(
                        "/files/\(remoteID)/move.json",
                        body: ["folder_id": newParentID]
                    )
                    updated.parentIdentifier = item.parentItemIdentifier.rawValue
                    try? db.logActivity(action: .moved, itemName: tracked.name, itemType: .file)
                }

                try db.upsertItem(updated)
                let resultItem = FileProviderItem(trackedItem: updated)
                completionHandler(resultItem, [], false, nil)
            } catch {
                logger.error("Modify failed: \(error.localizedDescription)")
                completionHandler(nil, [], false, mapToFileProviderError(error))
            }
        }
        return Progress()
    }

    // MARK: - Delete

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        Task {
            do {
                guard let itemID = ItemIdentifier(rawValue: identifier.rawValue),
                      let remoteID = itemID.numericID else {
                    completionHandler(NSFileProviderError(.noSuchItem))
                    return
                }

                let tracked = try db.item(for: identifier.rawValue)

                if itemID.isFile {
                    try await api.delete("/files/\(remoteID).json")
                } else {
                    try await api.delete("/folders/\(remoteID).json")
                }

                try db.deleteItem(identifier.rawValue)
                if let tracked {
                    try? db.logActivity(action: .deleted, itemName: tracked.name, itemType: tracked.itemType)
                }

                completionHandler(nil)
            } catch {
                logger.error("Delete failed: \(error.localizedDescription)")
                completionHandler(mapToFileProviderError(error))
            }
        }
        return Progress()
    }

    // MARK: - Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        Enumerator(
            containerIdentifier: containerItemIdentifier,
            api: api,
            db: db,
            config: config
        )
    }

    // MARK: - Helpers

    private func resolveParentFolderID(_ identifier: NSFileProviderItemIdentifier) -> Int {
        if identifier == .rootContainer {
            return config.remoteRootFolderID ?? 0
        }
        return ItemIdentifier(rawValue: identifier.rawValue)?.numericID ?? 0
    }

    private func mapToFileProviderError(_ error: Error) -> Error {
        guard let apiError = error as? APIError else { return error }
        switch apiError {
        case .notAuthenticated:
            return NSFileProviderError(.notAuthenticated)
        case .notFound:
            return NSFileProviderError(.noSuchItem)
        case .rateLimited, .serverError:
            return NSFileProviderError(.serverUnreachable)
        case .networkError:
            return NSFileProviderError(.serverUnreachable)
        default:
            return NSFileProviderError(.cannotSynchronize)
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: Build the FileProviderExtension target in Xcode.
Expected: Compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add FileProviderExtension/Extension.swift
git commit -m "feat: implement full File Provider extension (download, upload, create, modify, delete)"
```

---

## Task 13: File Provider — Remote Change Poller

**Files:**
- Create: `FileProviderExtension/RemoteChangePoller.swift`

Background polling that signals the enumerator when remote changes are detected.

- [ ] **Step 1: Implement RemoteChangePoller**

```swift
// FileProviderExtension/RemoteChangePoller.swift
import FileProvider
import ImageRelayKit
import os.log

actor RemoteChangePoller {
    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client.fileprovider", category: "Poller")
    private let domain: NSFileProviderDomain
    private let config: AppConfiguration
    private var pollingTask: Task<Void, Never>?

    init(domain: NSFileProviderDomain, config: AppConfiguration) {
        self.domain = domain
        self.config = config
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.pollLoop()
        }
        logger.info("Remote change polling started (interval: \(config.pollIntervalSeconds)s)")
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        logger.info("Remote change polling stopped")
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(config.pollIntervalSeconds))
            } catch {
                break // Cancelled
            }

            do {
                guard let manager = NSFileProviderManager(for: domain) else { continue }
                try await manager.signalEnumerator(for: .workingSet)
                try await manager.signalEnumerator(for: .rootContainer)
                logger.debug("Signaled enumerator for remote change check")
            } catch {
                logger.error("Failed to signal enumerator: \(error.localizedDescription)")
            }
        }
    }
}
```

- [ ] **Step 2: Wire poller into Extension.swift init**

Add to `Extension.swift` after the existing `init`:

```swift
// Add property at top of Extension class:
private var poller: RemoteChangePoller?

// Add to end of init(domain:):
Task {
    let poller = RemoteChangePoller(domain: domain, config: config)
    await poller.start()
    self.poller = poller
}

// Update invalidate():
func invalidate() {
    Task { await poller?.stop() }
    logger.info("File Provider extension invalidated")
}
```

- [ ] **Step 3: Verify it compiles**

Run: Build the FileProviderExtension target in Xcode.
Expected: Compiles without errors.

- [ ] **Step 4: Commit**

```bash
git add FileProviderExtension/RemoteChangePoller.swift FileProviderExtension/Extension.swift
git commit -m "feat: add remote change polling that signals enumerator on interval"
```

---

## Task 14: Host App — Menu Bar and Domain Manager

**Files:**
- Modify: `ImageRelayClient/App.swift`
- Create: `ImageRelayClient/MenuBarView.swift`
- Create: `ImageRelayClient/DomainManager.swift`

The menu bar UI and the domain lifecycle manager that registers/removes the File Provider domain.

- [ ] **Step 1: Implement DomainManager**

```swift
// ImageRelayClient/DomainManager.swift
import FileProvider
import ImageRelayKit
import os.log

@Observable
final class DomainManager {
    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client", category: "DomainManager")
    static let domainIdentifier = NSFileProviderDomainIdentifier("com.oliverames.imagerelay-client.domain")
    static let domainDisplayName = "Image Relay"

    var isDomainActive = false
    var lastError: String?

    @MainActor
    func setupDomain() async {
        let domain = NSFileProviderDomain(
            identifier: Self.domainIdentifier,
            displayName: Self.domainDisplayName
        )

        do {
            try await NSFileProviderManager.add(domain)
            isDomainActive = true
            lastError = nil
            logger.info("File Provider domain added successfully")
        } catch let error as NSError where error.code == NSFileWriteFileExistsError {
            // Domain already exists
            isDomainActive = true
            lastError = nil
            logger.info("File Provider domain already exists")
        } catch {
            isDomainActive = false
            lastError = error.localizedDescription
            logger.error("Failed to add domain: \(error.localizedDescription)")
        }
    }

    @MainActor
    func removeDomain() async {
        let domain = NSFileProviderDomain(
            identifier: Self.domainIdentifier,
            displayName: Self.domainDisplayName
        )

        do {
            try await NSFileProviderManager.remove(domain)
            isDomainActive = false
            logger.info("File Provider domain removed")
        } catch {
            logger.error("Failed to remove domain: \(error.localizedDescription)")
        }
    }

    func signalSync() async {
        let domain = NSFileProviderDomain(
            identifier: Self.domainIdentifier,
            displayName: Self.domainDisplayName
        )
        guard let manager = NSFileProviderManager(for: domain) else { return }
        do {
            try await manager.signalEnumerator(for: .workingSet)
            logger.info("Triggered manual sync signal")
        } catch {
            logger.error("Failed to signal sync: \(error.localizedDescription)")
        }
    }

    func openInFinder() {
        let domain = NSFileProviderDomain(
            identifier: Self.domainIdentifier,
            displayName: Self.domainDisplayName
        )
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.getUserVisibleURL(for: .rootContainer) { url, error in
            if let url {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
```

- [ ] **Step 2: Implement MenuBarView**

```swift
// ImageRelayClient/MenuBarView.swift
import SwiftUI
import ImageRelayKit

struct MenuBarView: View {
    @Environment(DomainManager.self) private var domainManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: domainManager.isDomainActive ? "cloud.fill" : "cloud.slash")
                    .foregroundStyle(domainManager.isDomainActive ? .green : .secondary)
                Text(domainManager.isDomainActive ? "Connected" : "Not Connected")
                    .font(.headline)
            }
            .padding(.horizontal)

            if let error = domainManager.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Divider()

            Button("Open in Finder") {
                domainManager.openInFinder()
            }
            .keyboardShortcut("o")

            Button("Sync Now") {
                Task { await domainManager.signalSync() }
            }
            .keyboardShortcut("r")

            Divider()

            SettingsLink {
                Text("Settings...")
            }
            .keyboardShortcut(",")

            Divider()

            Button("Quit ImageRelay Client") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.vertical, 8)
        .frame(width: 250)
    }
}
```

- [ ] **Step 3: Update App.swift**

```swift
// ImageRelayClient/App.swift
import SwiftUI
import ServiceManagement
import ImageRelayKit

@main
struct ImageRelayClientApp: App {
    @State private var domainManager = DomainManager()

    var body: some Scene {
        MenuBarExtra("ImageRelay", systemImage: "cloud") {
            MenuBarView()
                .environment(domainManager)
        }
        .menuBarExtraStyle(.window)

        Settings {
            Text("Settings tabs coming in next task")
                .frame(width: 500, height: 400)
        }
    }
}
```

- [ ] **Step 4: Verify it compiles and runs**

Run: Build and run the ImageRelayClient target in Xcode.
Expected: Menu bar icon appears with cloud icon, popover shows status.

- [ ] **Step 5: Commit**

```bash
git add ImageRelayClient/App.swift ImageRelayClient/MenuBarView.swift ImageRelayClient/DomainManager.swift
git commit -m "feat: add menu bar UI and File Provider domain manager"
```

---

## Task 15: Host App — Settings Window

**Files:**
- Create: `ImageRelayClient/Settings/GeneralSettingsView.swift`
- Create: `ImageRelayClient/Settings/FoldersSettingsView.swift`
- Create: `ImageRelayClient/Settings/ActivitySettingsView.swift`
- Create: `ImageRelayClient/Settings/AdvancedSettingsView.swift`
- Modify: `ImageRelayClient/App.swift` (replace Settings stub)

- [ ] **Step 1: Implement GeneralSettingsView**

```swift
// ImageRelayClient/Settings/GeneralSettingsView.swift
import SwiftUI
import ServiceManagement
import ImageRelayKit

struct GeneralSettingsView: View {
    @State private var config: AppConfiguration
    @State private var loginItemEnabled = false
    private let configURL: URL

    init() {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.oliverames.imagerelay-client"
        )!
        let url = AppConfiguration.fileURL(in: container)
        self.configURL = url
        self._config = State(initialValue: (try? AppConfiguration.load(from: url)) ?? .default)
    }

    var body: some View {
        Form {
            Section("Account") {
                SecureField("API Key", text: $config.apiKey)
                    .onChange(of: config.apiKey) { save() }

                TextField("Remote Root Folder ID", value: $config.remoteRootFolderID, format: .number)
                    .onChange(of: config.remoteRootFolderID) { save() }

                TextField("Default File Type ID", value: $config.defaultFileTypeID, format: .number)
                    .onChange(of: config.defaultFileTypeID) { save() }
            }

            Section("Startup") {
                Toggle("Open at Login", isOn: $loginItemEnabled)
                    .onChange(of: loginItemEnabled) { _, newValue in
                        toggleLoginItem(enabled: newValue)
                    }
            }

            Section {
                HStack {
                    Image(systemName: config.isConfigured ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(config.isConfigured ? .green : .orange)
                    Text(config.isConfigured ? "Configuration complete" : "API key and root folder ID required")
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loginItemEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    private func save() {
        try? config.save(to: configURL)
    }

    private func toggleLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemEnabled = SMAppService.mainApp.status == .enabled
        }
    }
}
```

- [ ] **Step 2: Implement FoldersSettingsView**

```swift
// ImageRelayClient/Settings/FoldersSettingsView.swift
import SwiftUI
import ImageRelayKit

struct FoldersSettingsView: View {
    @State private var folders: [TrackedItem] = []
    @State private var isLoading = true

    private let db: SyncDatabase?

    init() {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.oliverames.imagerelay-client"
        )!
        self.db = try? SyncDatabase(url: SyncDatabase.databaseURL(in: container))
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading folders...")
            } else if folders.isEmpty {
                ContentUnavailableView(
                    "No Folders",
                    systemImage: "folder",
                    description: Text("Folders will appear here after the first sync.")
                )
            } else {
                List(folders, id: \.identifier) { folder in
                    FolderRow(folder: folder, db: db)
                }
            }
        }
        .task { loadFolders() }
    }

    private func loadFolders() {
        guard let db else {
            isLoading = false
            return
        }
        do {
            folders = try db.allItems().filter { $0.itemType == .folder }
            isLoading = false
        } catch {
            isLoading = false
        }
    }
}

private struct FolderRow: View {
    let folder: TrackedItem
    let db: SyncDatabase?
    @State private var isPinned: Bool

    init(folder: TrackedItem, db: SyncDatabase?) {
        self.folder = folder
        self.db = db
        self._isPinned = State(initialValue: folder.isPinned)
    }

    var body: some View {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)
            Text(folder.name)
            Spacer()
            Toggle("Pin for Offline", isOn: $isPinned)
                .toggleStyle(.switch)
                .labelsHidden()
                .onChange(of: isPinned) { _, newValue in
                    var updated = folder
                    updated.isPinned = newValue
                    try? db?.upsertItem(updated)
                }
        }
    }
}
```

- [ ] **Step 3: Implement ActivitySettingsView**

```swift
// ImageRelayClient/Settings/ActivitySettingsView.swift
import SwiftUI
import ImageRelayKit

struct ActivitySettingsView: View {
    @State private var entries: [ActivityEntry] = []
    @State private var isLoading = true

    private let db: SyncDatabase?

    init() {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.oliverames.imagerelay-client"
        )!
        self.db = try? SyncDatabase(url: SyncDatabase.databaseURL(in: container))
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading activity...")
            } else if entries.isEmpty {
                ContentUnavailableView(
                    "No Activity",
                    systemImage: "clock",
                    description: Text("Sync activity will appear here.")
                )
            } else {
                List(entries, id: \.id) { entry in
                    HStack {
                        Image(systemName: iconName(for: entry.action))
                            .foregroundStyle(iconColor(for: entry.action))
                            .frame(width: 20)
                        VStack(alignment: .leading) {
                            Text(entry.itemName)
                                .font(.body)
                            Text(entry.action.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.timestamp, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task { loadActivity() }
        .refreshable { loadActivity() }
    }

    private func loadActivity() {
        guard let db else {
            isLoading = false
            return
        }
        do {
            entries = try db.recentActivity(limit: 50)
            isLoading = false
        } catch {
            isLoading = false
        }
    }

    private func iconName(for action: SyncAction) -> String {
        switch action {
        case .downloaded: return "arrow.down.circle.fill"
        case .uploaded: return "arrow.up.circle.fill"
        case .deleted: return "trash.fill"
        case .renamed: return "pencil.circle.fill"
        case .moved: return "arrow.right.circle.fill"
        case .conflicted: return "exclamationmark.triangle.fill"
        case .created: return "plus.circle.fill"
        }
    }

    private func iconColor(for action: SyncAction) -> Color {
        switch action {
        case .downloaded: return .blue
        case .uploaded: return .green
        case .deleted: return .red
        case .renamed, .moved: return .orange
        case .conflicted: return .yellow
        case .created: return .mint
        }
    }
}
```

- [ ] **Step 4: Implement AdvancedSettingsView**

```swift
// ImageRelayClient/Settings/AdvancedSettingsView.swift
import SwiftUI
import ImageRelayKit

struct AdvancedSettingsView: View {
    @State private var config: AppConfiguration
    private let configURL: URL

    init() {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.oliverames.imagerelay-client"
        )!
        let url = AppConfiguration.fileURL(in: container)
        self.configURL = url
        self._config = State(initialValue: (try? AppConfiguration.load(from: url)) ?? .default)
    }

    var body: some View {
        Form {
            Section("Sync Interval") {
                HStack {
                    Slider(value: pollIntervalBinding, in: 15...300, step: 15) {
                        Text("Poll every")
                    }
                    Text("\(config.pollIntervalSeconds)s")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Section("Sync Direction") {
                Toggle("Upload local changes", isOn: $config.syncUpload)
                    .onChange(of: config.syncUpload) { save() }
                Toggle("Download remote changes", isOn: $config.syncDownload)
                    .onChange(of: config.syncDownload) { save() }
            }

            Section("User Agent") {
                TextField("User-Agent header", text: $config.userAgent)
                    .onChange(of: config.userAgent) { save() }
                Text("Image Relay requires a User-Agent header. Include your project URL or contact email.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var pollIntervalBinding: Binding<Double> {
        Binding(
            get: { Double(config.pollIntervalSeconds) },
            set: {
                config.pollIntervalSeconds = Int($0)
                save()
            }
        )
    }

    private func save() {
        try? config.save(to: configURL)
    }
}
```

- [ ] **Step 5: Update App.swift with Settings tabs**

```swift
// ImageRelayClient/App.swift
import SwiftUI
import ServiceManagement
import ImageRelayKit

@main
struct ImageRelayClientApp: App {
    @State private var domainManager = DomainManager()

    var body: some Scene {
        MenuBarExtra("ImageRelay", systemImage: "cloud") {
            MenuBarView()
                .environment(domainManager)
        }
        .menuBarExtraStyle(.window)

        Settings {
            TabView {
                GeneralSettingsView()
                    .tabItem { Label("General", systemImage: "gear") }

                FoldersSettingsView()
                    .tabItem { Label("Folders", systemImage: "folder") }

                ActivitySettingsView()
                    .tabItem { Label("Activity", systemImage: "clock") }

                AdvancedSettingsView()
                    .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            }
            .frame(width: 500, height: 400)
        }
    }
}
```

- [ ] **Step 6: Verify it compiles and runs**

Run: Build and run the ImageRelayClient target in Xcode.
Expected: Menu bar icon appears; Settings window opens with 4 tabs.

- [ ] **Step 7: Commit**

```bash
git add ImageRelayClient/
git commit -m "feat: add Settings window with General, Folders, Activity, and Advanced tabs"
```

---

## Task 16: Host App — Domain Setup on Launch

**Files:**
- Modify: `ImageRelayClient/App.swift`

Register the File Provider domain when the app launches with valid configuration.

- [ ] **Step 1: Add domain setup to App.swift**

Add a `.task` modifier to the `MenuBarExtra` body and an init that sets up the domain:

```swift
// In ImageRelayClientApp, update MenuBarExtra:
MenuBarExtra("ImageRelay", systemImage: domainManager.isDomainActive ? "cloud.fill" : "cloud") {
    MenuBarView()
        .environment(domainManager)
        .task {
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.com.oliverames.imagerelay-client"
            )!
            let config = (try? AppConfiguration.load(from: AppConfiguration.fileURL(in: container))) ?? .default
            if config.isConfigured {
                await domainManager.setupDomain()
            }
        }
}
.menuBarExtraStyle(.window)
```

- [ ] **Step 2: Verify it compiles**

Run: Build the ImageRelayClient target in Xcode.
Expected: Compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add ImageRelayClient/App.swift
git commit -m "feat: auto-register File Provider domain on app launch when configured"
```

---

## Task 17: Integration — Build and Smoke Test

**Files:** No new files. This task verifies the full project builds and the extension loads.

- [ ] **Step 1: Clean build both targets**

Run: In Xcode, Product > Clean Build Folder, then build the ImageRelayClient scheme.
Expected: Both targets build successfully.

- [ ] **Step 2: Run the app**

Run: Product > Run in Xcode.
Expected:
- Menu bar cloud icon appears
- Settings window opens with Cmd+,
- No crashes in Console.app

- [ ] **Step 3: Verify extension loads**

Run: `pluginkit -m -i com.oliverames.imagerelay-client.fileprovider`
Expected: The extension is listed (may need valid config to register the domain).

- [ ] **Step 4: Commit any fixups**

```bash
git add -A
git commit -m "fix: integration fixups from smoke testing"
```

---

## Summary

| Task | Component | Description |
|------|-----------|-------------|
| 1 | ImageRelayKit | Swift Package scaffolding with GRDB |
| 2 | ImageRelayKit | Domain models (RemoteFolder, RemoteFile, QuickLink, UploadJob, ItemIdentifier) |
| 3 | ImageRelayKit | Rate limiter (actor-based token bucket) |
| 4 | ImageRelayKit | APIError types and pagination parsing |
| 5 | ImageRelayKit | Core APIClient (async/await, retry, rate limiting) |
| 6 | ImageRelayKit | AppConfiguration (shared JSON in app group) |
| 7 | ImageRelayKit | SyncDatabase (GRDB: tracked items, sync anchors, activity log) |
| 8 | ImageRelayKit | SyncAnchor and ConflictResolver |
| 9 | Project | XcodeGen project with host app + extension targets |
| 10 | Extension | FileProviderItem (NSFileProviderItemProtocol bridge) |
| 11 | Extension | Enumerator (folder/file listing from API) |
| 12 | Extension | Full extension implementation (download, upload, CRUD) |
| 13 | Extension | Remote change poller |
| 14 | Host App | Menu bar UI and domain manager |
| 15 | Host App | Settings window (4 tabs) |
| 16 | Host App | Domain registration on launch |
| 17 | Integration | Full build and smoke test |
