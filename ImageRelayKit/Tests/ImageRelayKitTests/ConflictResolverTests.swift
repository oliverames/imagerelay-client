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
