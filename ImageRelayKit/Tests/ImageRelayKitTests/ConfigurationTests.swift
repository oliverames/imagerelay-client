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
        #expect(loaded.userAgent == AppConfiguration.currentMacUserAgent)
        #expect(loaded.maxConcurrentFiles == 10)
        #expect(loaded.showAdvancedInformation == false)
        #expect(loaded.fileProviderDisconnected == false)
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
        let json = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        #expect(json?["api_key"] == nil)
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
        #expect(KeychainStore.load(account: account, accessGroup: nil) == "legacy-secret")

        // After migration, api_key must be gone from JSON on disk.
        let rewritten = try String(contentsOf: url, encoding: .utf8)
        #expect(!rewritten.contains("legacy-secret"))
        let json = try JSONSerialization.jsonObject(with: Data(rewritten.utf8)) as? [String: Any]
        #expect(json?["api_key"] == nil)
    }

    @Test("Legacy api_key is scrubbed when Keychain already has a value")
    func legacyAPIKeyScrubbedWhenKeychainAlreadyConfigured() throws {
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
        }

        KeychainStore.save("stored-secret", account: account, accessGroup: nil)
        let legacyJSON = """
        {"api_key":"stale-plaintext-secret","remote_root_folder_id":99,"poll_interval_seconds":60,"sync_upload":true,"sync_download":true,"user_agent":"test","selected_folder_ids":[2907644]}
        """
        try legacyJSON.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try AppConfiguration.load(from: url, keychainAccount: account, keychainAccessGroup: nil)
        #expect(loaded.apiKey == "stored-secret")
        #expect(loaded.remoteRootFolderID == 99)
        #expect(loaded.selectedFolderIDs == [2907644])
        #expect(KeychainStore.load(account: account, accessGroup: nil) == "stored-secret")

        let rewritten = try String(contentsOf: url, encoding: .utf8)
        #expect(!rewritten.contains("stale-plaintext-secret"))
        #expect(!rewritten.contains("stored-secret"))
        let json = try JSONSerialization.jsonObject(with: Data(rewritten.utf8)) as? [String: Any]
        #expect(json?["api_key"] == nil)
    }

    @Test("Default configuration has sensible values")
    func defaults() {
        let config = AppConfiguration.default
        #expect(config.apiKey == "")
        #expect(config.pollIntervalSeconds == 60)
        #expect(config.syncUpload == true)
        #expect(config.syncDownload == true)
        #expect(config.userAgent == AppConfiguration.currentMacUserAgent)
        #expect(config.maxConcurrentFiles == 10)
        #expect(config.authMethod == .apiKey)
        #expect(config.credential == .apiKey(""))
    }

    @Test("Load returns default when file missing")
    func missingFile() throws {
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        let url = tempURL()
        let loaded = try AppConfiguration.load(from: url, keychainAccount: account, keychainAccessGroup: nil)
        #expect(loaded.apiKey == "")
        #expect(loaded.userAgent == AppConfiguration.currentMacUserAgent)
    }

    @Test("Legacy built-in User-Agent migrates to current release default")
    func legacyDefaultUserAgentMigrates() throws {
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
        }

        let previousBuiltInDefaults = [
            "ImageRelayClient/1.0 (macOS)",
            "ImageRelayClient/1.1 (macOS)",
            "ImageRelayClient/1.1.0",
            "ImageRelayClient/1.1.0 (macOS)",
            "ImageRelayClient/1.1.1",
            "ImageRelayClient/1.1.1 (macOS)",
            "ImageRelayClient/1.1.2",
            "ImageRelayClient/1.1.2 (macOS)",
            "ImageRelayClient/1.2.0-beta.1",
            "ImageRelayClient/1.2.0-beta.1 (macOS)",
            "ImageRelayClient/1.2.0-beta.2",
            "ImageRelayClient/1.2.0-beta.2 (macOS)",
            "ImageRelayClient/1.2.0-beta.3",
            "ImageRelayClient/1.2.0-beta.3 (macOS)",
            "ImageRelayClient/1.2.0-beta.4",
            "ImageRelayClient/1.2.0-beta.4 (macOS)",
            "ImageRelayClient/1.2.0",
            "ImageRelayClient/1.2.0 (macOS)",
            "ImageRelayClient/1.2.1",
            "ImageRelayClient/1.2.1 (macOS)",
            "ImageRelayClient/1.3.0-beta.1",
            "ImageRelayClient/1.3.0-beta.1 (macOS)",
            "ImageRelayClient/1.3.0-beta.2",
            "ImageRelayClient/1.3.0-beta.2 (macOS)",
            "ImageRelayClient/1.3.0-beta.3",
            "ImageRelayClient/1.3.0-beta.3 (macOS)"
        ]

        for userAgent in previousBuiltInDefaults {
            let legacyJSON = """
            {"remote_root_folder_id":99,"poll_interval_seconds":60,"sync_upload":true,"sync_download":true,"user_agent":"\(userAgent)","selected_folder_ids":[]}
            """
            try legacyJSON.write(to: url, atomically: true, encoding: .utf8)

            let loaded = try AppConfiguration.load(from: url, keychainAccount: account, keychainAccessGroup: nil)
            #expect(loaded.userAgent == AppConfiguration.currentMacUserAgent)

            let rewrittenData = try Data(contentsOf: url)
            let rewritten = try JSONSerialization.jsonObject(with: rewrittenData) as? [String: Any]
            #expect(rewritten?["user_agent"] as? String == AppConfiguration.currentMacUserAgent)
        }
    }

    @Test("Legacy iOS User-Agent migrates to current iOS default")
    func legacyIOSDefaultUserAgentMigrates() {
        #expect(AppConfiguration.normalizedIOSUserAgent("ImageRelayClient/1.1 (iOS)") == AppConfiguration.currentIOSUserAgent)
        #expect(AppConfiguration.normalizedIOSUserAgent("ImageRelayClient/1.1.0 (iOS)") == AppConfiguration.currentIOSUserAgent)
        #expect(AppConfiguration.normalizedIOSUserAgent("ImageRelayClient/1.1.1 (iOS)") == AppConfiguration.currentIOSUserAgent)
        #expect(AppConfiguration.normalizedIOSUserAgent("ImageRelayClient/1.1.2 (iOS)") == AppConfiguration.currentIOSUserAgent)
        #expect(AppConfiguration.normalizedIOSUserAgent("ImageRelayClient/1.2.0-beta.1 (iOS)") == AppConfiguration.currentIOSUserAgent)
        #expect(AppConfiguration.normalizedIOSUserAgent("ImageRelayClient/1.2.0-beta.2 (iOS)") == AppConfiguration.currentIOSUserAgent)
        #expect(AppConfiguration.normalizedIOSUserAgent("ImageRelayClient/1.2.0-beta.3 (iOS)") == AppConfiguration.currentIOSUserAgent)
        #expect(AppConfiguration.normalizedIOSUserAgent("ImageRelayClient/1.2.0-beta.4 (iOS)") == AppConfiguration.currentIOSUserAgent)
        #expect(AppConfiguration.normalizedIOSUserAgent("ImageRelayClient/1.2.0 (iOS)") == AppConfiguration.currentIOSUserAgent)
        #expect(AppConfiguration.normalizedIOSUserAgent("ImageRelayClient/1.2.1 (iOS)") == AppConfiguration.currentIOSUserAgent)
        #expect(AppConfiguration.normalizedIOSUserAgent("ImageRelayClient/1.3.0-beta.1 (iOS)") == AppConfiguration.currentIOSUserAgent)
        #expect(AppConfiguration.normalizedIOSUserAgent("ImageRelayClient/1.3.0-beta.2 (iOS)") == AppConfiguration.currentIOSUserAgent)
        #expect(AppConfiguration.normalizedIOSUserAgent("ImageRelayClient/1.3.0-beta.3 (iOS)") == AppConfiguration.currentIOSUserAgent)
        #expect(AppConfiguration.normalizedIOSUserAgent("ImageRelayClient/1.1.1 (macOS)") == AppConfiguration.currentIOSUserAgent)
    }

    @Test("Custom User-Agent is preserved")
    func customUserAgentIsPreserved() throws {
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
        }

        let customJSON = """
        {"remote_root_folder_id":99,"poll_interval_seconds":60,"sync_upload":true,"sync_download":true,"user_agent":"ImageRelayClient/Oliver-Test","selected_folder_ids":[]}
        """
        try customJSON.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try AppConfiguration.load(from: url, keychainAccount: account, keychainAccessGroup: nil)
        #expect(loaded.userAgent == "ImageRelayClient/Oliver-Test")
    }

    @Test("Legacy config without max_concurrent_files defaults to 10")
    func legacyMaxConcurrentFilesDefaultsToTen() throws {
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
        }

        let legacyJSON = """
        {"remote_root_folder_id":99,"poll_interval_seconds":60,"sync_upload":true,"sync_download":true,"user_agent":"ImageRelayClient/Oliver-Test","selected_folder_ids":[]}
        """
        try legacyJSON.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try AppConfiguration.load(from: url, keychainAccount: account, keychainAccessGroup: nil)
        #expect(loaded.maxConcurrentFiles == 10)
        #expect(loaded.showAdvancedInformation == false)
        #expect(loaded.fileProviderDisconnected == false)
    }

    @Test("OAuth tokens and client secret round trip through Keychain")
    func oauthSecretsRoundTrip() throws {
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        KeychainStore.delete(account: AppConfiguration.oauthTokensKeychainAccount, accessGroup: nil)
        KeychainStore.delete(account: AppConfiguration.oauthClientSecretKeychainAccount, accessGroup: nil)
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
            KeychainStore.delete(account: AppConfiguration.oauthTokensKeychainAccount, accessGroup: nil)
            KeychainStore.delete(account: AppConfiguration.oauthClientSecretKeychainAccount, accessGroup: nil)
        }

        var config = AppConfiguration.default
        config.authMethod = .oauth
        config.oauthTenant = "bluecrossvt.imagerelay.com"
        config.oauthClientID = "client-id"
        config.oauthClientSecret = "client-secret"
        config.oauthTokens = OAuthTokens(accessToken: "access-token", refreshToken: "refresh-token", tenant: "bluecrossvt")

        try config.save(to: url, keychainAccount: account, keychainAccessGroup: nil)

        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(!raw.contains("access-token"))
        #expect(!raw.contains("client-secret"))

        let loaded = try AppConfiguration.load(from: url, keychainAccount: account, keychainAccessGroup: nil)
        #expect(loaded.authMethod == .oauth)
        #expect(loaded.oauthTenant == "bluecrossvt")
        #expect(loaded.oauthClientSecret == "client-secret")
        #expect(loaded.oauthTokens?.accessToken == "access-token")
        #expect(loaded.credential == .oauth(OAuthTokens(accessToken: "access-token", refreshToken: "refresh-token", tenant: "bluecrossvt")))
    }

    @Test("isConfigured requires API key")
    func isConfigured() {
        var config = AppConfiguration.default
        #expect(config.isConfigured == false)

        config.apiKey = "key"
        #expect(config.isConfigured == true)

        config.remoteRootFolderID = 1
        #expect(config.isConfigured == true)
    }

    @Test("webBaseURL defaults to nil and round-trips through save/load")
    func webBaseURLRoundTrips() throws {
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
        }

        var config = AppConfiguration.default
        config.apiKey = "k"
        #expect(config.webBaseURL == nil)

        config.webBaseURL = URL(string: "https://bluecrossvt.imagerelay.com")
        try config.save(to: url, keychainAccount: account, keychainAccessGroup: nil)

        let loaded = try AppConfiguration.load(from: url, keychainAccount: account, keychainAccessGroup: nil)
        #expect(loaded.webBaseURL?.absoluteString == "https://bluecrossvt.imagerelay.com")
    }

    @Test("Legacy config.json without web_base_url decodes cleanly")
    func legacyConfigWithoutWebBaseURL() throws {
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
        }

        let legacyJSON = """
        {"remote_root_folder_id":99,"poll_interval_seconds":60,"sync_upload":true,"sync_download":true,"user_agent":"ImageRelayClient/1.2.0 (macOS)","selected_folder_ids":[]}
        """
        try legacyJSON.write(to: url, atomically: true, encoding: .utf8)
        let loaded = try AppConfiguration.load(from: url, keychainAccount: account, keychainAccessGroup: nil)
        #expect(loaded.webBaseURL == nil)
        #expect(loaded.remoteRootFolderID == 99)
    }

    @Test("filenamePresentationStyle defaults to serverCanonical and round-trips")
    func filenamePresentationStyleRoundTrips() throws {
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
        }

        var config = AppConfiguration.default
        config.apiKey = "k"
        #expect(config.filenamePresentationStyle == .serverCanonical)

        config.filenamePresentationStyle = .humanReadable
        try config.save(to: url, keychainAccount: account, keychainAccessGroup: nil)

        let loaded = try AppConfiguration.load(from: url, keychainAccount: account, keychainAccessGroup: nil)
        #expect(loaded.filenamePresentationStyle == .humanReadable)
    }

    @Test("Legacy config.json without filename_presentation_style decodes to serverCanonical")
    func legacyConfigWithoutFilenameStyle() throws {
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
        }

        let legacyJSON = """
        {"remote_root_folder_id":7,"poll_interval_seconds":60,"sync_upload":true,"sync_download":true,"user_agent":"ImageRelayClient/1.2.0 (macOS)","selected_folder_ids":[]}
        """
        try legacyJSON.write(to: url, atomically: true, encoding: .utf8)
        let loaded = try AppConfiguration.load(from: url, keychainAccount: account, keychainAccessGroup: nil)
        #expect(loaded.filenamePresentationStyle == .serverCanonical)
    }
}
