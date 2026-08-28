import Foundation
import Security

struct AlpacaCredentials: Equatable {
    let keyID: String
    let secretKey: String
}

enum AlpacaCredentialsStoreError: LocalizedError {
    case invalidValue
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidValue:
            "Both Alpaca Paper API credentials are required"
        case let .keychain(status):
            if status == errSecInteractionNotAllowed {
                "Keychain access needs one-time repair. Re-enter the Alpaca credentials in Settings."
            } else {
                SecCopyErrorMessageString(status, nil) as String?
                    ?? "macOS Keychain error \(status)"
            }
        }
    }
}

struct AlpacaCredentialsStore: Sendable {
    // Do not query the v1 or v2 services. Those items were created by builds
    // without a stable Team ID and contain per-build cdhash partitions. Even a
    // read can summon SecurityAgent before query-level UI controls are honored.
    // v3 is created only by the Apple Development signed Release, whose stable
    // Team ID allows Keychain access to survive binary updates.
    static let service = "com.openibkr.alpaca.marketdata.v3"
    private static let keyIDAccount = "api-key-id"
    private static let secretAccount = "api-secret-key"
    private static let installedAppPath = "/Applications/OpenIBKR.app"

    func load() throws -> AlpacaCredentials? {
        let keyID = try read(account: Self.keyIDAccount)
        let secret = try read(account: Self.secretAccount)
        guard keyID != nil || secret != nil else { return nil }
        guard let keyID, let secret, !keyID.isEmpty, !secret.isEmpty else {
            throw AlpacaCredentialsStoreError.invalidValue
        }
        return AlpacaCredentials(keyID: keyID, secretKey: secret)
    }

    func save(_ credentials: AlpacaCredentials) throws {
        guard
            credentials.keyID == credentials.keyID.trimmingCharacters(in: .whitespacesAndNewlines),
            credentials.secretKey
                == credentials.secretKey.trimmingCharacters(in: .whitespacesAndNewlines),
            credentials.keyID.count >= 8,
            credentials.secretKey.count >= 16
        else { throw AlpacaCredentialsStoreError.invalidValue }
        try write(credentials.keyID, account: Self.keyIDAccount)
        do {
            try write(credentials.secretKey, account: Self.secretAccount)
        } catch {
            try? delete(account: Self.keyIDAccount)
            throw error
        }
    }

    func delete() throws {
        try delete(account: Self.keyIDAccount)
        try delete(account: Self.secretAccount)
    }

    private func read(account: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            // v3 items should never need UI because they are created by a
            // Team-ID-signed Release. Keep this guard for corrupt or manually
            // modified entries.
            kSecUseAuthenticationUI: kSecUseAuthenticationUISkip,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { throw AlpacaCredentialsStoreError.keychain(status) }
        return value
    }

    private func write(_ value: String, account: String) throws {
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            // Keep the restricted ACL tied to the installed Release. The
            // Apple-issued signing identity also supplies the stable Team ID
            // used by macOS's partition ACL.
            kSecAttrAccess: try trustedAccess(),
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AlpacaCredentialsStoreError.keychain(updateStatus)
        }
        var addition = identity
        attributes.forEach { addition[$0.key] = $0.value }
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AlpacaCredentialsStoreError.keychain(addStatus)
        }
    }

    private func trustedAccess() throws -> SecAccess {
        let appPath = FileManager.default.fileExists(atPath: Self.installedAppPath)
            ? Self.installedAppPath
            : Bundle.main.bundlePath
        var trustedApplication: SecTrustedApplication?
        let trustedStatus = appPath.withCString {
            SecTrustedApplicationCreateFromPath($0, &trustedApplication)
        }
        guard trustedStatus == errSecSuccess, let trustedApplication else {
            throw AlpacaCredentialsStoreError.keychain(trustedStatus)
        }

        var access: SecAccess?
        let accessStatus = SecAccessCreate(
            Self.service as CFString,
            [trustedApplication] as CFArray,
            &access
        )
        guard accessStatus == errSecSuccess, let access else {
            throw AlpacaCredentialsStoreError.keychain(accessStatus)
        }
        return access
    }

    private func delete(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AlpacaCredentialsStoreError.keychain(status)
        }
    }
}

struct CloudflareAccessCredentials: Equatable {
    let baseURL: String
    let clientID: String
    let clientSecret: String
}

enum CloudflareCredentialsStoreError: LocalizedError {
    case invalidValue
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidValue:
            "A valid HTTPS Wealth URL, Client ID, and Client Secret are required"
        case let .keychain(status):
            if status == errSecInteractionNotAllowed {
                "Keychain access needs one-time repair. Re-enter the Cloudflare credentials in Settings."
            } else {
                SecCopyErrorMessageString(status, nil) as String?
                    ?? "macOS Keychain error \(status)"
            }
        }
    }
}

struct CloudflareCredentialsStore: Sendable {
    static let service = "com.openibkr.cloudflare.wealth.v1"
    private static let baseURLAccount = "wealth-base-url"
    private static let clientIDAccount = "access-client-id"
    private static let clientSecretAccount = "access-client-secret"
    private static let installedAppPath = "/Applications/OpenIBKR.app"

    func load() throws -> CloudflareAccessCredentials? {
        let baseURL = try read(account: Self.baseURLAccount)
        let clientID = try read(account: Self.clientIDAccount)
        let clientSecret = try read(account: Self.clientSecretAccount)
        guard baseURL != nil || clientID != nil || clientSecret != nil else { return nil }
        guard let baseURL, let clientID, let clientSecret,
              Self.isValidBaseURL(baseURL), clientID.count >= 8, clientSecret.count >= 16
        else { throw CloudflareCredentialsStoreError.invalidValue }
        return CloudflareAccessCredentials(
            baseURL: baseURL,
            clientID: clientID,
            clientSecret: clientSecret
        )
    }

    func save(_ credentials: CloudflareAccessCredentials) throws {
        guard Self.isValidBaseURL(credentials.baseURL),
              credentials.clientID == credentials.clientID.trimmingCharacters(in: .whitespacesAndNewlines),
              credentials.clientSecret == credentials.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
              credentials.clientID.count >= 8,
              credentials.clientSecret.count >= 16
        else { throw CloudflareCredentialsStoreError.invalidValue }
        do {
            try write(credentials.baseURL, account: Self.baseURLAccount)
            try write(credentials.clientID, account: Self.clientIDAccount)
            try write(credentials.clientSecret, account: Self.clientSecretAccount)
        } catch {
            try? delete()
            throw error
        }
    }

    func delete() throws {
        try delete(account: Self.baseURLAccount)
        try delete(account: Self.clientIDAccount)
        try delete(account: Self.clientSecretAccount)
    }

    private static func isValidBaseURL(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let components = URLComponents(string: value),
              components.scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil
        else { return false }
        return true
    }

    private func read(account: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationUI: kSecUseAuthenticationUISkip,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { throw CloudflareCredentialsStoreError.keychain(status) }
        return value
    }

    private func write(_ value: String, account: String) throws {
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrAccess: try trustedAccess(),
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CloudflareCredentialsStoreError.keychain(updateStatus)
        }
        var addition = identity
        attributes.forEach { addition[$0.key] = $0.value }
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CloudflareCredentialsStoreError.keychain(addStatus)
        }
    }

    private func trustedAccess() throws -> SecAccess {
        let appPath = FileManager.default.fileExists(atPath: Self.installedAppPath)
            ? Self.installedAppPath
            : Bundle.main.bundlePath
        var trustedApplication: SecTrustedApplication?
        let trustedStatus = appPath.withCString {
            SecTrustedApplicationCreateFromPath($0, &trustedApplication)
        }
        guard trustedStatus == errSecSuccess, let trustedApplication else {
            throw CloudflareCredentialsStoreError.keychain(trustedStatus)
        }
        var access: SecAccess?
        let accessStatus = SecAccessCreate(
            Self.service as CFString,
            [trustedApplication] as CFArray,
            &access
        )
        guard accessStatus == errSecSuccess, let access else {
            throw CloudflareCredentialsStoreError.keychain(accessStatus)
        }
        return access
    }

    private func delete(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudflareCredentialsStoreError.keychain(status)
        }
    }
}
