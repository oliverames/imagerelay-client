import Testing
@testable import ImageRelayKit

@Suite("KeychainStore")
struct KeychainStoreTests {
    // Tests use accessGroup: nil so they run in the SPM test runner without entitlements.
    // The production path uses KeychainStore.sharedAccessGroup; that's covered by on-device builds.
    private let account = "test-api-key-\(UUID().uuidString)"

    @Test("Save and load roundtrip")
    func saveAndLoad() {
        defer { KeychainStore.delete(account: account, accessGroup: nil) }
        let saved = KeychainStore.save("secret-token", account: account, accessGroup: nil)
        #expect(saved == true)
        let loaded = KeychainStore.load(account: account, accessGroup: nil)
        #expect(loaded == "secret-token")
    }

    @Test("Save overwrites previous value")
    func overwrite() {
        defer { KeychainStore.delete(account: account, accessGroup: nil) }
        KeychainStore.save("first", account: account, accessGroup: nil)
        KeychainStore.save("second", account: account, accessGroup: nil)
        let loaded = KeychainStore.load(account: account, accessGroup: nil)
        #expect(loaded == "second")
    }

    @Test("Load returns nil for missing account")
    func missingAccount() {
        let loaded = KeychainStore.load(account: "no-such-account-\(UUID().uuidString)", accessGroup: nil)
        #expect(loaded == nil)
    }

    @Test("Delete returns true for existing item")
    func deleteExisting() {
        KeychainStore.save("value", account: account, accessGroup: nil)
        let deleted = KeychainStore.delete(account: account, accessGroup: nil)
        #expect(deleted == true)
        #expect(KeychainStore.load(account: account, accessGroup: nil) == nil)
    }

    @Test("Delete returns true for missing item (idempotent)")
    func deleteMissing() {
        let deleted = KeychainStore.delete(account: "ghost-\(UUID().uuidString)", accessGroup: nil)
        #expect(deleted == true)
    }

    @Test("Save empty string and load it back")
    func emptyString() {
        defer { KeychainStore.delete(account: account, accessGroup: nil) }
        KeychainStore.save("", account: account, accessGroup: nil)
        let loaded = KeychainStore.load(account: account, accessGroup: nil)
        #expect(loaded == "")
    }
}
