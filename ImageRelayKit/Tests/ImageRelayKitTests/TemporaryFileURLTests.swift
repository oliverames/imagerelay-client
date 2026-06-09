import Foundation
import Testing
@testable import ImageRelayKit

@Suite("TemporaryFileURL")
struct TemporaryFileURLTests {
    @Test("safeFilename replaces path separators and control characters")
    func safeFilenameReplacesUnsafeCharacters() {
        let name = "folder/name\\with:colon\nasset.jpg"

        #expect(TemporaryFileURL.safeFilename(from: name) == "folder_name_with_colon_asset.jpg")
    }

    @Test("safeFilename falls back for empty or dot-only names")
    func safeFilenameFallbacks() {
        #expect(TemporaryFileURL.safeFilename(from: "") == "download")
        #expect(TemporaryFileURL.safeFilename(from: "   ") == "download")
        #expect(TemporaryFileURL.safeFilename(from: ".") == "download")
        #expect(TemporaryFileURL.safeFilename(from: "..") == "download")
    }

    @Test("make keeps remote names inside the requested temp directory")
    func makeKeepsNamesInsideDirectory() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = TemporaryFileURL.make(
            originalName: "../../Library/Secrets/token.txt",
            directory: directory,
            uniquePrefix: "fixed"
        )

        #expect(url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(url.lastPathComponent == "fixed-.._.._Library_Secrets_token.txt")
    }

    @Test("safeFilename bounds long names by UTF-8 bytes")
    func safeFilenameBoundsLongNames() {
        let longName = String(repeating: "a", count: 300)

        #expect(TemporaryFileURL.safeFilename(from: longName).utf8.count <= TemporaryFileURL.maxFilenameBytes)
    }
}
