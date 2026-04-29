import Testing
@testable import ImageRelayKit

// Serialized so tests don't race on the shared Keychain account "api-key".
@Suite("Configuration", .serialized)
struct ConfigurationTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }

    func testKeychainAccount() -> String {
        "test-config-api-key-\(UUID().uuidString)"
    }

    func cleanKeychain(account: String) {
        KeychainStore.delete(account: account, accessGroup: nil)
    }

    @Test("Save and load configuration")
    func saveAndLoad() throws {
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
        }

        var config = AppConfiguration.default
        config.apiKey = "my-key"
        config.remoteRootFolderID = 123
        config.defaultFileTypeID = 456

        try config.save(to: url, keychainAccount: account, keychainAccessGroup: nil)

        let loaded = try AppConfiguration.load(from: url, keychainAccount: account, keychainAccessGroup: nil)
        #expect(loaded.apiKey == "my-key")
        #expect(loaded.remoteRootFolderID == 123)
        #expect(loaded.defaultFileTypeID == 456)
        #expect(loaded.pollIntervalSeconds == 60)
    }

    @Test("apiKey is absent from the saved JSON file")
    func apiKeyNotInJSON() throws {
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
        }

        var config = AppConfiguration.default
        config.apiKey = "secret-token"
        try config.save(to: url, keychainAccount: account, keychainAccessGroup: nil)

        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(!raw.contains("secret-token"))
        #expect(!raw.contains("api_key"))
    }

    @Test("Legacy config.json with api_key migrates to Keychain")
    func legacyMigration() throws {
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
        }

        // Write a legacy JSON that still contains api_key.
        let legacyJSON = """
        {"api_key":"legacy-secret","remote_root_folder_id":99,"poll_interval_seconds":60,"sync_upload":true,"sync_download":true,"user_agent":"test","selected_folder_ids":[]}
        """
        try legacyJSON.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try AppConfiguration.load(from: url, keychainAccount: account, keychainAccessGroup: nil)
        #expect(loaded.apiKey == "legacy-secret")
        #expect(loaded.remoteRootFolderID == 99)

        // After migration, api_key must be gone from JSON on disk.
        let rewritten = try String(contentsOf: url, encoding: .utf8)
        #expect(!rewritten.contains("legacy-secret"))
        #expect(!rewritten.contains("api_key"))
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
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        let url = tempURL()
        let loaded = try AppConfiguration.load(from: url, keychainAccount: account, keychainAccessGroup: nil)
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
