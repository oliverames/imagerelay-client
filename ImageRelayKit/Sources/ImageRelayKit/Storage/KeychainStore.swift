import Foundation
import Security

/// Thin wrapper around SecItem for storing string secrets in the login Keychain.
/// The shared access group allows both the host app and File Provider extension
/// to read and write the same item.
public enum KeychainStore {
    public static let sharedAccessGroup = "PV3W52NDZ3.com.oliverames.imagerelay-client"
    private static let service = "com.oliverames.imagerelay-client"

    /// Saves or replaces `value` for `account`. Returns true on success.
    @discardableResult
    public static func save(_ value: String, account: String, accessGroup: String? = sharedAccessGroup) -> Bool {
        let data = Data(value.utf8)
        var query = baseQuery(account: account, accessGroup: accessGroup)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData] = data
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Returns the stored string for `account`, or nil if not found.
    public static func load(account: String, accessGroup: String? = sharedAccessGroup) -> String? {
        var query = baseQuery(account: account, accessGroup: accessGroup)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes the item for `account`. Returns true if deleted, false if not found.
    @discardableResult
    public static func delete(account: String, accessGroup: String? = sharedAccessGroup) -> Bool {
        let query = baseQuery(account: account, accessGroup: accessGroup)
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(account: String, accessGroup: String?) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }
}
