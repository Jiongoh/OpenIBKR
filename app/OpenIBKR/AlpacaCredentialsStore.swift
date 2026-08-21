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
    // Do not reuse the legacy `com.openibkr.alpaca.marketdata` service. Its
    // items were created by ad-hoc-signed builds and carry per-build legacy
    // ACL partitions. Even a read can summon SecurityAgent before query-level
    // UI controls are honored. New items start clean with the stable Release
    // designated requirement applied by `trustedAccess()` below.
    static let service = "com.openibkr.alpaca.marketdata.v2"
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
            // v2 items should never need UI because they are created with the
            // stable Release requirement. Keep this guard for corrupt or
            // manually modified entries.
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
            // Existing login-keychain items created without an explicit
            // access object retain the legacy "confirm every new code hash"
            // ACL. Replace it on every write with a trusted-application ACL
            // tied to OpenIBKR's stable designated requirement instead of a
            // per-build CDHash.
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
