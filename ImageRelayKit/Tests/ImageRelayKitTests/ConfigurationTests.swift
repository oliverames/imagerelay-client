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
