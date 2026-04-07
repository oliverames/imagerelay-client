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
