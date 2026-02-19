//
//  KeychainHelper.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Keychain helper for secure credential storage
//

import Foundation
import Security

// MARK: - Keychain Helper

enum KeychainHelper {
    // New single-entry vault (all credentials consolidated here)
    private static let vaultService = "dev.quotio.desktop.credentials"
    private static let vaultAccount = "credentials-v1"

    // Legacy per-feature services (read/migrate only)
    private static let remoteService = "dev.quotio.desktop.remote-management"
    private static let localService = "dev.quotio.desktop.local-management"
    private static let warpService = "dev.quotio.desktop.warp"
    private static let usageSourceService = "dev.quotio.desktop.usage-sources"
    private static let localManagementAccount = "local-management-key"
    private static let warpTokensAccount = "warp-tokens"
    private static let localManagementDefaultsKey = "managementKey"
    private static let warpTokensDefaultsKey = "warpTokens"

    // Legacy service names for keychain migration (newest first)
    private static let legacyRemoteServices = [
        "proseek.io.vn.Quotio.remote-management",
        "com.quotio.remote-management",
    ]
    private static let legacyLocalServices = [
        "proseek.io.vn.Quotio.local-management",
        "com.quotio.local-management",
    ]
    private static let legacyWarpServices = [
        "proseek.io.vn.Quotio.warp",
        "com.quotio.warp",
    ]

    private struct CredentialsVault: Codable, Equatable {
        var localManagementKey: String?
        var remoteManagementKeys: [String: String]
        var warpTokens: Data?
        var usageSourceTokens: [String: String]

        static let empty = CredentialsVault(
            localManagementKey: nil,
            remoteManagementKeys: [:],
            warpTokens: nil,
            usageSourceTokens: [:]
        )
    }

    private static let vaultLock = NSLock()
    private static var cachedVault = CredentialsVault.empty
    private static var hasLoadedVault = false

    /// Preload the single vault entry once at startup.
    /// This makes subsequent credential reads fully in-memory.
    static func primeCache() {
        vaultLock.lock()
        defer { vaultLock.unlock() }
        _ = loadVaultLocked()
    }

    static func saveManagementKey(_ key: String, for configId: String) {
        let saved = updateVault { vault in
            vault.remoteManagementKeys[configId] = key
        }
        if !saved {
            Log.keychain("Failed to save management key for config \(configId)")
        }
    }

    static func getManagementKey(for configId: String) -> String? {
        if let key = readVault({ $0.remoteManagementKeys[configId] }) {
            return key
        }

        let account = "management-key-\(configId)"
        if let migrated = migrateStringFromLegacy(
            account: account,
            primaryService: remoteService,
            legacyServices: legacyRemoteServices
        ) {
            _ = updateVault { vault in
                vault.remoteManagementKeys[configId] = migrated
            }
            return migrated
        }

        return nil
    }

    static func deleteManagementKey(for configId: String) {
        _ = updateVault { vault in
            vault.remoteManagementKeys.removeValue(forKey: configId)
        }

        let account = "management-key-\(configId)"
        deleteData(service: remoteService, account: account)
        for legacy in legacyRemoteServices {
            deleteData(service: legacy, account: account)
        }
    }

    static func hasManagementKey(for configId: String) -> Bool {
        getManagementKey(for: configId) != nil
    }

    static func saveLocalManagementKey(_ key: String) -> Bool {
        let saved = updateVault { vault in
            vault.localManagementKey = key
        }
        if !saved {
            Log.keychain("Failed to save local management key")
        }
        return saved
    }

    static func getLocalManagementKey() -> String? {
        if let key = readVault({ $0.localManagementKey }), !key.hasPrefix("$2a$") {
            return key
        }

        if let migrated = migrateStringFromLegacy(
            account: localManagementAccount,
            primaryService: localService,
            legacyServices: legacyLocalServices
        ), !migrated.hasPrefix("$2a$") {
            _ = updateVault { vault in
                vault.localManagementKey = migrated
            }
            return migrated
        }

        guard let legacyKey = UserDefaults.standard.string(forKey: localManagementDefaultsKey),
              !legacyKey.hasPrefix("$2a$") else {
            return nil
        }

        if saveLocalManagementKey(legacyKey) {
            UserDefaults.standard.removeObject(forKey: localManagementDefaultsKey)
        }

        return legacyKey
    }

    static func deleteLocalManagementKey() {
        _ = updateVault { vault in
            vault.localManagementKey = nil
        }

        deleteData(service: localService, account: localManagementAccount)
        for legacy in legacyLocalServices {
            deleteData(service: legacy, account: localManagementAccount)
        }
        UserDefaults.standard.removeObject(forKey: localManagementDefaultsKey)
    }

    static func saveWarpTokens(_ data: Data) -> Bool {
        let saved = updateVault { vault in
            vault.warpTokens = data
        }
        if !saved {
            Log.keychain("Failed to save Warp tokens")
        }
        return saved
    }

    static func getWarpTokens() -> Data? {
        if let data = readVault({ $0.warpTokens }) {
            return data
        }

        if let migrated = migrateDataFromLegacy(
            account: warpTokensAccount,
            primaryService: warpService,
            legacyServices: legacyWarpServices
        ) {
            _ = updateVault { vault in
                vault.warpTokens = migrated
            }
            return migrated
        }

        guard let legacyData = UserDefaults.standard.data(forKey: warpTokensDefaultsKey) else {
            return nil
        }

        if saveWarpTokens(legacyData) {
            UserDefaults.standard.removeObject(forKey: warpTokensDefaultsKey)
        }

        return legacyData
    }

    static func deleteWarpTokens() {
        _ = updateVault { vault in
            vault.warpTokens = nil
        }

        deleteData(service: warpService, account: warpTokensAccount)
        for legacy in legacyWarpServices {
            deleteData(service: legacy, account: warpTokensAccount)
        }
        UserDefaults.standard.removeObject(forKey: warpTokensDefaultsKey)
    }

    static func saveUsageSourceToken(_ token: String, for sourceID: UUID) -> Bool {
        let key = sourceID.uuidString.lowercased()
        return updateVault { vault in
            vault.usageSourceTokens[key] = token
        }
    }

    static func getUsageSourceToken(for sourceID: UUID) -> String? {
        let key = sourceID.uuidString.lowercased()
        if let token = readVault({ $0.usageSourceTokens[key] }) {
            return token
        }

        let legacyAccount = "usage-source-token-\(sourceID.uuidString)"
        if let migrated = readString(service: usageSourceService, account: legacyAccount) {
            _ = updateVault { vault in
                vault.usageSourceTokens[key] = migrated
            }
            return migrated
        }

        return nil
    }

    static func deleteUsageSourceToken(for sourceID: UUID) {
        let key = sourceID.uuidString.lowercased()
        _ = updateVault { vault in
            vault.usageSourceTokens.removeValue(forKey: key)
        }

        let legacyAccount = "usage-source-token-\(sourceID.uuidString)"
        deleteData(service: usageSourceService, account: legacyAccount)
    }

    private static func readVault<T>(_ body: (CredentialsVault) -> T) -> T {
        vaultLock.lock()
        defer { vaultLock.unlock() }
        let vault = loadVaultLocked()
        return body(vault)
    }

    private static func updateVault(_ mutate: (inout CredentialsVault) -> Void) -> Bool {
        vaultLock.lock()
        defer { vaultLock.unlock() }

        var vault = loadVaultLocked()
        let before = vault
        mutate(&vault)

        // Avoid unnecessary keychain writes (and extra auth prompts).
        if vault == before {
            return true
        }

        return persistVaultLocked(vault)
    }

    private static func loadVaultLocked() -> CredentialsVault {
        if hasLoadedVault {
            return cachedVault
        }

        hasLoadedVault = true

        guard let data = readData(service: vaultService, account: vaultAccount) else {
            cachedVault = .empty
            return cachedVault
        }

        guard let decoded = try? JSONDecoder().decode(CredentialsVault.self, from: data) else {
            cachedVault = .empty
            return cachedVault
        }

        cachedVault = decoded
        return decoded
    }

    private static func persistVaultLocked(_ vault: CredentialsVault) -> Bool {
        guard let data = try? JSONEncoder().encode(vault) else {
            Log.keychain("Failed to encode credential vault")
            return false
        }

        let saved = saveData(data, service: vaultService, account: vaultAccount)
        if saved {
            cachedVault = vault
            hasLoadedVault = true
        }
        return saved
    }

    private static func migrateDataFromLegacy(
        account: String,
        primaryService: String,
        legacyServices: [String]
    ) -> Data? {
        let services = [primaryService] + legacyServices
        for service in services {
            guard let data = readData(service: service, account: account) else { continue }
            // Keep old entries for safety; new versions read from vault first.
            return data
        }
        return nil
    }

    private static func migrateStringFromLegacy(
        account: String,
        primaryService: String,
        legacyServices: [String]
    ) -> String? {
        guard let data = migrateDataFromLegacy(
            account: account,
            primaryService: primaryService,
            legacyServices: legacyServices
        ) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Upsert keychain item without delete+add churn.
    /// This avoids repeatedly re-creating items and reduces authorization prompts.
    private static func saveData(_ data: Data, service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        if updateStatus != errSecItemNotFound {
            Log.keychain("Keychain update failed (service: \(service), account: \(account)): \(updateStatus)")
            return false
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return true
        }

        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if retryStatus == errSecSuccess {
                return true
            }
            Log.keychain("Keychain retry update failed (service: \(service), account: \(account)): \(retryStatus)")
            return false
        }

        Log.keychain("Keychain save failed (service: \(service), account: \(account)): \(addStatus)")
        return false
    }

    private static func readData(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess {
            return result as? Data
        }

        if status != errSecItemNotFound {
            Log.keychain("Keychain read failed (service: \(service), account: \(account)): \(status)")
        }

        return nil
    }

    private static func readString(service: String, account: String) -> String? {
        guard let data = readData(service: service, account: account) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private static func deleteData(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.keychain("Keychain delete failed (service: \(service), account: \(account)): \(status)")
        }
    }
}
