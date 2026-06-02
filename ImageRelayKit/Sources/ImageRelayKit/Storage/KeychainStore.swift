import Foundation
import Security

public struct KeychainStoreError: LocalizedError, Sendable {
    public let operation: String
    public let account: String
    public let status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String?
        return "Keychain \(operation) failed for \(account): \(message ?? "OSStatus \(status)")"
    }
}

/// Thin wrapper around SecItem for storing string secrets in the login Keychain.
/// The shared access group allows both the host app and File Provider extension
/// on a single platform to read and write the same item. iOS and macOS use
/// distinct groups because the iOS bundle IDs include `.ios` and the access
/// group must be a prefix of every bundle ID that declares it (Automatic
/// signing won't authorise an arbitrary group on device).
public enum KeychainStore {
    #if os(macOS)
    public static let sharedAccessGroup = "PV3W52NDZ3.com.oliverames.imagerelay-client"
    #else
    public static let sharedAccessGroup = "PV3W52NDZ3.com.oliverames.imagerelay-client.ios"
    #endif

    private static let service = "com.oliverames.imagerelay-client"

    // Thread-safe in-memory storage fallback for unit testing to prevent Keychain popup storms
    private static let testLock = NSRecursiveLock()
    private nonisolated(unsafe) static var testStore: [String: String] = [:]

    public static let isTesting: Bool = {
        if NSClassFromString("XCTest") != nil {
            return true
        }
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil {
            return true
        }
        let args = ProcessInfo.processInfo.arguments
        for arg in args {
            let lower = arg.lowercased()
            if lower.contains("test") || lower.contains("xctest") {
                return true
            }
        }
        return false
    }()

    /// Saves or replaces `value` for `account`. Returns true on success.
    /// Uses SecItemUpdate if the item already exists to preserve the Access Control List (ACL)
    /// and prevent macOS from losing the user's 'Always Allow' authorization across updates.
    @discardableResult
    public static func save(_ value: String, account: String, accessGroup: String? = sharedAccessGroup) -> Bool {
        (try? saveRequired(value, account: account, accessGroup: accessGroup)) != nil
    }

    /// Saves or replaces `value` for `account`, throwing when Keychain rejects
    /// the mutation. Use this from persistence paths that must not silently lose
    /// credentials.
    public static func saveRequired(_ value: String, account: String, accessGroup: String? = sharedAccessGroup) throws {
        if isTesting {
            testLock.lock()
            defer { testLock.unlock() }
            testStore["\(accessGroup ?? "nil"):\(account)"] = value
            return
        }

        let data = Data(value.utf8)
        let query = baseQuery(account: account, accessGroup: accessGroup)

        var checkQuery = query
        checkQuery[kSecReturnData] = false
        let status = SecItemCopyMatching(checkQuery as CFDictionary, nil)

        if status == errSecSuccess {
            let attributesToUpdate: [CFString: Any] = [
                kSecValueData: data
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainStoreError(operation: "update", account: account, status: updateStatus)
            }
            return
        }

        guard status == errSecItemNotFound else {
            throw KeychainStoreError(operation: "lookup", account: account, status: status)
        }

        var newQuery = query
        newQuery[kSecValueData] = data
        newQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(newQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError(operation: "add", account: account, status: addStatus)
        }
    }

    /// Returns the stored string for `account`, or nil if not found.
    public static func load(account: String, accessGroup: String? = sharedAccessGroup) -> String? {
        if isTesting {
            testLock.lock()
            defer { testLock.unlock() }
            return testStore["\(accessGroup ?? "nil"):\(account)"]
        }

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
        (try? deleteRequired(account: account, accessGroup: accessGroup)) != nil
    }

    /// Deletes `account`, throwing when Keychain rejects the mutation. Missing
    /// items are considered success so callers can clear optional secrets.
    public static func deleteRequired(account: String, accessGroup: String? = sharedAccessGroup) throws {
        if isTesting {
            testLock.lock()
            defer { testLock.unlock() }
            let key = "\(accessGroup ?? "nil"):\(account)"
            testStore.removeValue(forKey: key)
            return
        }

        let query = baseQuery(account: account, accessGroup: accessGroup)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError(operation: "delete", account: account, status: status)
        }
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
