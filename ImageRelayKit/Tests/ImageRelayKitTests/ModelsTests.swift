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

    @Test("Decode live RemoteFolder payload")
    func decodeLiveFolderPayload() throws {
        let json = """
        {
            "id": 1909821,
            "name": "5050",
            "parent_id": null,
            "full_catalog_path": "",
            "updated_on": "2026-04-29T12:47:47.000Z",
            "child_count": 13
        }
        """.data(using: .utf8)!

        let folder = try JSONDecoder.imageRelay.decode(RemoteFolder.self, from: json)
        #expect(folder.id == 1909821)
        #expect(folder.name == "5050")
        #expect(folder.parentID == nil)
        #expect(folder.path == "")
        #expect(folder.childCount == 13)
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
        #expect(file.contentModifiedAt != nil)
    }

    @Test("Decode live RemoteFile payload")
    func decodeLiveFilePayload() throws {
        let json = """
        {
            "id": 205636740,
            "filename": "Green-Up-Day.PNG",
            "size": 668335,
            "updated_on": "2026-04-28T19:55:58.000Z",
            "content_type": "image/png",
            "file_type_id": 6096,
            "folder_ids": [2910316],
            "deleted": null
        }
        """.data(using: .utf8)!

        let file = try JSONDecoder.imageRelay.decode(RemoteFile.self, from: json)
        #expect(file.id == 205636740)
        #expect(file.name == "Green-Up-Day.PNG")
        #expect(file.size == 668335)
        #expect(file.folderIDs == [2910316])
        #expect(file.isDeleted == false)
        #expect(file.contentModifiedAt != nil)
    }

    @Test("Parse Image Relay date metadata")
    func parseImageRelayDateMetadata() throws {
        let withFractionalSeconds = try #require(ImageRelayDateParser.date(from: "2026-04-28T19:55:58.000Z"))
        let withoutFractionalSeconds = try #require(ImageRelayDateParser.date(from: "2026-04-01T12:00:00Z"))

        #expect(withFractionalSeconds.timeIntervalSince1970 == 1_777_406_158)
        #expect(withoutFractionalSeconds.timeIntervalSince1970 == 1_775_044_800)
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

    @Test("Decode live UploadJob create and final chunk payloads")
    func decodeLiveUploadJobPayloads() throws {
        let createJSON = """
        {
            "id": 36305650,
            "created_at": "2026-04-29T19:54:09.000Z",
            "files": [
                {
                    "id": 32119192,
                    "name": "Codex-Chunk-Probe-155407.txt",
                    "size": 1
                }
            ]
        }
        """.data(using: .utf8)!

        let createdJob = try JSONDecoder.imageRelay.decode(UploadJob.self, from: createJSON)
        #expect(createdJob.id == 36305650)
        #expect(createdJob.status == nil)
        #expect(createdJob.files?.first?.id == 32119192)
        #expect(createdJob.files?.first?.name == "Codex-Chunk-Probe-155407.txt")
        #expect(createdJob.files?.first?.size == 1)

        let chunkJSON = """
        {
            "id": 36305650,
            "user_id": 274329,
            "metagroup_id": 6096,
            "catalog_id": 2907644,
            "prefix": "/",
            "finished": true,
            "created_at": "2026-04-29T19:54:09.000Z",
            "updated_at": "2026-04-29T19:54:12.000Z",
            "retries": 0,
            "unique_id": "88e63a280f5043f2a9127418acd4fd86",
            "asset_id": 205729632
        }
        """.data(using: .utf8)!

        let completedJob = try JSONDecoder.imageRelay.decode(UploadJob.self, from: chunkJSON)
        #expect(completedJob.finished == true)
        #expect(completedJob.assetID == 205729632)
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
