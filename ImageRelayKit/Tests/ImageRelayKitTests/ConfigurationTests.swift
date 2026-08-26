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

    func cleanOAuthKeychain() {
        KeychainStore.delete(account: AppConfiguration.oauthTokensKeychainAccount, accessGroup: nil)
        KeychainStore.delete(account: AppConfiguration.oauthClientSecretKeychainAccount, accessGroup: nil)
        KeychainStore.delete(account: AppConfiguration.oauthCodeVerifierKeychainAccount, accessGroup: nil)
        KeychainStore.delete(account: AppConfiguration.oauthStateKeychainAccount, accessGroup: nil)
    }

    @Test("Default OAuth redirect uses Cloudflare callback bridge")
    func defaultOAuthRedirectUsesCloudflareBridge() {
        #expect(AppConfiguration.default.oauthRedirectURI == "https://imagerelay-oauth.amesvt.com/callback")
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

    @Test("Saving API key auth with an empty in-memory key deletes the Keychain item")
    func emptyAPIKeySaveDeletesKeychainItem() throws {
        // An empty apiKey means "no credential" regardless of authMethod, so
        // sign-out actually signs out (the old preserve-branch let iOS sign-out
        // resurrect the stored key on next launch).
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
        }

        KeychainStore.save("stored-secret", account: account, accessGroup: nil)
        var config = AppConfiguration.default
        config.authMethod = .apiKey
        config.apiKey = ""
        config.defaultFileTypeID = 456

        try config.save(to: url, keychainAccount: account, keychainAccessGroup: nil)

        #expect(KeychainStore.load(account: account, accessGroup: nil) == nil)
        let loaded = try AppConfiguration.load(from: url, keychainAccount: account, keychainAccessGroup: nil)
        #expect(loaded.apiKey == "")
        #expect(loaded.defaultFileTypeID == 456)
    }

    @Test("Saving OAuth auth clears stale API key")
    func oauthSaveClearsStaleAPIKey() throws {
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        cleanOAuthKeychain()
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
            cleanOAuthKeychain()
        }

        KeychainStore.save("stored-secret", account: account, accessGroup: nil)
        var config = AppConfiguration.default
        config.authMethod = .oauth
        config.apiKey = ""
        config.oauthTenant = "tenant"
        config.oauthClientID = "client"
        config.oauthClientSecret = "secret"

        try config.save(to: url, keychainAccount: account, keychainAccessGroup: nil)

        #expect(KeychainStore.load(account: account, accessGroup: nil) == nil)
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

    @Test("Legacy native OAuth redirect migrates to Cloudflare bridge")
    func legacyNativeOAuthRedirectMigratesToCloudflareBridge() throws {
        let legacyJSON = """
        {"auth_method":"oauth","oauth_redirect_uri":"imagerelay-client://oauth/callback","poll_interval_seconds":60,"sync_upload":true,"sync_download":true,"user_agent":"test","selected_folder_ids":[]}
        """

        let config = try JSONDecoder.imageRelay.decode(AppConfiguration.self, from: Data(legacyJSON.utf8))

        #expect(config.oauthRedirectURI == AppConfiguration.defaultOAuthRedirectURI)
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
        {"api_key":"stale-plaintext-secret","remote_root_folder_id":99,"poll_interval_seconds":60,"sync_upload":true,"sync_download":true,"user_agent":"test","selected_folder_ids":[12345]}
        """
        try legacyJSON.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try AppConfiguration.load(from: url, keychainAccount: account, keychainAccessGroup: nil)
        #expect(loaded.apiKey == "stored-secret")
        #expect(loaded.remoteRootFolderID == 99)
        #expect(loaded.selectedFolderIDs == [12345])
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
        #expect(config.userAgent.contains(AppConfiguration.userAgentContactURL))
        #expect(config.maxConcurrentFiles == 10)
        #expect(config.webhookRelayURL == nil)
        #expect(config.webhookRelayIntervalSeconds == 15)
        #expect(config.authMethod == .apiKey)
        #expect(config.credential == .apiKey(""))
    }

    @Test("Built-in User-Agent values include a contact URL")
    func builtInUserAgentsIncludeContactURL() {
        #expect(AppConfiguration.currentServiceUserAgent.contains(AppConfiguration.userAgentContactURL))
        #expect(AppConfiguration.currentMacUserAgent.contains(AppConfiguration.userAgentContactURL))
        #expect(AppConfiguration.currentIOSUserAgent.contains(AppConfiguration.userAgentContactURL))
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
            "ImageRelayClient/1.3.0-beta.3 (macOS)",
            "ImageRelayClient/1.3.0",
            "ImageRelayClient/1.3.0 (macOS)",
            "ImageRelayClient/1.3.1",
            "ImageRelayClient/1.3.1 (macOS)",
            "ImageRelayClient/1.3.2",
            "ImageRelayClient/1.3.2 (macOS)",
            "ImageRelayClient/1.4.0-beta.1",
            "ImageRelayClient/1.4.0-beta.1 (macOS)",
            "ImageRelayClient/1.4.0",
            "ImageRelayClient/1.4.0 (macOS)",
            "ImageRelayClient/1.4.2 (macOS; https://github.com/oliverames/imagerelay-client)",
            "ImageRelayClient/1.4.2 (https://github.com/oliverames/imagerelay-client)"
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
        #expect(AppConfiguration.normalizedIOSUserAgent("ImageRelayClient/1.3.0 (iOS)") == AppConfiguration.currentIOSUserAgent)
        #expect(AppConfiguration.normalizedIOSUserAgent("ImageRelayClient/1.3.1 (iOS)") == AppConfiguration.currentIOSUserAgent)
        #expect(AppConfiguration.normalizedIOSUserAgent("ImageRelayClient/1.3.2 (iOS)") == AppConfiguration.currentIOSUserAgent)
        #expect(AppConfiguration.normalizedIOSUserAgent("ImageRelayClient/1.4.0-beta.1 (iOS)") == AppConfiguration.currentIOSUserAgent)
        #expect(AppConfiguration.normalizedIOSUserAgent("ImageRelayClient/1.4.0 (iOS)") == AppConfiguration.currentIOSUserAgent)
        #expect(AppConfiguration.normalizedIOSUserAgent("ImageRelayClient/1.1.1 (macOS)") == AppConfiguration.currentIOSUserAgent)
    }

    @Test("Blank User-Agent falls back to current defaults")
    func blankUserAgentFallsBackToCurrentDefaults() throws {
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
        }

        let blankJSON = """
        {"remote_root_folder_id":99,"poll_interval_seconds":60,"sync_upload":true,"sync_download":true,"user_agent":"   ","selected_folder_ids":[]}
        """
        try blankJSON.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try AppConfiguration.load(from: url, keychainAccount: account, keychainAccessGroup: nil)
        #expect(loaded.userAgent == AppConfiguration.currentMacUserAgent)
        #expect(AppConfiguration.normalizedIOSUserAgent("   ") == AppConfiguration.currentIOSUserAgent)
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

    @Test("Webhook relay settings default and round trip")
    func webhookRelaySettingsRoundTrip() throws {
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
        }

        var config = AppConfiguration.default
        config.webhookRelayURL = URL(string: "https://relay.example.com/imagerelay")
        config.webhookRelayIntervalSeconds = 20

        try config.save(to: url, keychainAccount: account, keychainAccessGroup: nil)

        let loaded = try AppConfiguration.load(from: url, keychainAccount: account, keychainAccessGroup: nil)
        #expect(loaded.webhookRelayURL?.absoluteString == "https://relay.example.com/imagerelay")
        #expect(loaded.webhookRelayIntervalSeconds == 20)

        let legacyJSON = """
        {"remote_root_folder_id":99,"poll_interval_seconds":60,"sync_upload":true,"sync_download":true,"user_agent":"ImageRelayClient/Oliver-Test","selected_folder_ids":[]}
        """
        try legacyJSON.write(to: url, atomically: true, encoding: .utf8)

        let legacy = try AppConfiguration.load(from: url, keychainAccount: account, keychainAccessGroup: nil)
        #expect(legacy.webhookRelayURL == nil)
        #expect(legacy.webhookRelayIntervalSeconds == 15)
    }

    @Test("Webhook relay URL validation allows HTTPS and local HTTP only")
    func webhookRelayURLValidation() {
        #expect(AppConfiguration.isAllowedWebhookRelayURL(URL(string: "https://relay.example.com/imagerelay")!))
        #expect(AppConfiguration.isAllowedWebhookRelayURL(URL(string: "http://localhost:8787/imagerelay")!))
        #expect(!AppConfiguration.isAllowedWebhookRelayURL(URL(string: "http://relay.example.com/imagerelay")!))
        #expect(!AppConfiguration.isAllowedWebhookRelayURL(URL(string: "file:///tmp/relay.json")!))
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
        cleanOAuthKeychain()
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
            cleanOAuthKeychain()
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

    @Test("OAuth transient verifier and state round trip through Keychain only")
    func oauthTransientsRoundTripThroughKeychainOnly() throws {
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        cleanOAuthKeychain()
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
            cleanOAuthKeychain()
        }

        var config = AppConfiguration.default
        config.authMethod = .oauth
        config.oauthCodeVerifier = "verifier-secret"
        config.oauthState = "state-secret"

        try config.save(to: url, keychainAccount: account, keychainAccessGroup: nil)

        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(!raw.contains("verifier-secret"))
        #expect(!raw.contains("state-secret"))
        let json = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        #expect(json?["oauth_code_verifier"] == nil)
        #expect(json?["oauth_state"] == nil)

        let loaded = try AppConfiguration.load(from: url, keychainAccount: account, keychainAccessGroup: nil)
        #expect(loaded.oauthCodeVerifier == "verifier-secret")
        #expect(loaded.oauthState == "state-secret")
    }

    @Test("Legacy OAuth transient fields migrate to Keychain and are scrubbed")
    func legacyOAuthTransientsMigrateToKeychain() throws {
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        cleanOAuthKeychain()
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
            cleanOAuthKeychain()
        }

        let legacyJSON = """
        {"auth_method":"oauth","oauth_code_verifier":"legacy-verifier","oauth_state":"legacy-state","poll_interval_seconds":60,"sync_upload":true,"sync_download":true,"user_agent":"ImageRelayClient/Oliver-Test","selected_folder_ids":[]}
        """
        try legacyJSON.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try AppConfiguration.load(from: url, keychainAccount: account, keychainAccessGroup: nil)
        #expect(loaded.oauthCodeVerifier == "legacy-verifier")
        #expect(loaded.oauthState == "legacy-state")

        let rewritten = try String(contentsOf: url, encoding: .utf8)
        #expect(!rewritten.contains("legacy-verifier"))
        #expect(!rewritten.contains("legacy-state"))
        let json = try JSONSerialization.jsonObject(with: Data(rewritten.utf8)) as? [String: Any]
        #expect(json?["oauth_code_verifier"] == nil)
        #expect(json?["oauth_state"] == nil)
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

    @Test("loadAndRefresh does not refresh still-valid OAuth tokens")
    func loadAndRefreshOAuthTokenStillValid() async throws {
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
        }

        var config = AppConfiguration.default
        config.authMethod = .oauth
        config.oauthTenant = "test-tenant"
        config.oauthClientID = "cid"
        config.oauthClientSecret = "csec"
        config.oauthTokens = OAuthTokens(
            accessToken: "valid-access",
            refreshToken: "valid-refresh",
            expiresAt: Date().addingTimeInterval(3600),
            tenant: "test-tenant"
        )
        try config.save(to: url, keychainAccount: account, keychainAccessGroup: nil)

        MockURLProtocol.requestHandler = { _ in
            throw NSError(domain: "test", code: -1)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let result = try await AppConfiguration.loadAndRefresh(
            from: url,
            keychainAccount: account,
            keychainAccessGroup: nil
        )

        #expect(result.oauthTokens?.accessToken == "valid-access")
    }

    @Test("loadAndRefresh refreshes expiring OAuth tokens")
    func loadAndRefreshOAuthTokenExpiring() async throws {
        let account = testKeychainAccount()
        cleanKeychain(account: account)
        let url = tempURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            cleanKeychain(account: account)
        }

        var config = AppConfiguration.default
        config.authMethod = .oauth
        config.oauthTenant = "test-tenant"
        config.oauthClientID = "cid"
        config.oauthClientSecret = "csec"
        config.oauthTokens = OAuthTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            expiresAt: Date().addingTimeInterval(-300),
            tenant: "test-tenant"
        )
        try config.save(to: url, keychainAccount: account, keychainAccessGroup: nil)

        let mockResponseData = """
        {
            "access_token": "new-access-token",
            "refresh_token": "new-refresh-token",
            "expires_in": 3600,
            "token_type": "Bearer"
        }
        """.data(using: .utf8)!

        var capturedRequestBody: Data?
        var capturedRequestURL: URL?
        MockURLProtocol.requestHandler = { request in
            capturedRequestURL = request.url
            if let body = request.httpBody {
                capturedRequestBody = body
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                capturedRequestBody = data
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, mockResponseData)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let testConfig = URLSessionConfiguration.ephemeral
        testConfig.protocolClasses = [MockURLProtocol.self]

        let result = try await AppConfiguration.loadAndRefresh(
            from: url,
            keychainAccount: account,
            keychainAccessGroup: nil,
            sessionConfiguration: testConfig
        )

        #expect(result.oauthTokens?.accessToken == "new-access-token")
        #expect(result.oauthTokens?.refreshToken == "new-refresh-token")
        #expect(result.oauthTokens?.expiresAt != nil)

        // RFC 6749 §2.3.1: credentials travel in the form-encoded request body,
        // never in the URI.
        let body = try #require(capturedRequestBody)
        let pairs = try #require(try? URLComponents(
            string: "https://token.invalid/?\(String(decoding: body, as: UTF8.self))"
        )?.queryItems)
        func value(_ name: String) -> String? {
            pairs.first { $0.name == name }?.value
        }
        #expect(value("grant_type") == "refresh_token")
        #expect(value("refresh_token") == "old-refresh")
        #expect(value("client_id") == "cid")
        #expect(value("client_secret") == "csec")

        let query = try #require(capturedRequestURL.map { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems })
        // No credentials (or anything else) may ride along in the URI.
        #expect((query ?? []).isEmpty)
    }
}
