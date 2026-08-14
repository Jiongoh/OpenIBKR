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
            SecCopyErrorMessageString(status, nil) as String?
                ?? "macOS Keychain error \(status)"
        }
    }
}

struct AlpacaCredentialsStore {
    static let service = "com.openibkr.alpaca.marketdata"
    private static let keyIDAccount = "api-key-id"
    private static let secretAccount = "api-secret-key"

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
