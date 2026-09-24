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
    @Test("Membership identifiers preserve the remote asset and separate folder appearances")
    func membershipIdentifiers() {
        let first = ItemIdentifier.membership(fileID: 77, folderID: 101)
        let second = ItemIdentifier.membership(fileID: 77, folderID: 202)
        #expect(first != second)
        #expect(first.rawValue == "file-77-in-101")
        #expect(ItemIdentifier(rawValue: first.rawValue) == first)
        #expect(first.numericID == 77)
        #expect(first.membershipFolderID == 101)
        #expect(first.isFile && !first.isFolder)
        #expect(ItemIdentifier.file(77).membershipFolderID == nil)
        #expect(ItemIdentifier(rawValue: "file-77")?.numericID == 77)
    }

    @Test("Malformed membership identifiers are rejected")
    func malformedMemberships() {
        for value in ["folder-77-in-101", "file-77-in-", "file-77-in-0", "file-77-in--1",
                      "file-77-in-101-in-202", "file-x-in-101", "file-77-in-x"] {
            #expect(ItemIdentifier(rawValue: value) == nil)
        }
    }

}
