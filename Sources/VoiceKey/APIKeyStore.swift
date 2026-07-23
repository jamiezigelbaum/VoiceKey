import Foundation
import Security

enum APIKeyStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            return "Keychain returned status \(status)."
        }
    }
}

final class APIKeyStore {
    static let shared = APIKeyStore()

    private let service = "com.zigelbaum.VoiceKey"

    func hasAPIKey(for provider: VoiceProviderID) -> Bool {
        apiKey(for: provider) != nil
    }

    func apiKey(for provider: VoiceProviderID) -> String? {
        // ChatGPT Web authenticates through the provider's web sign-in and never uses a
        // stored key. Every other provider — including custom endpoints, where the key
        // is an optional bearer token — reads its key from the Keychain.
        guard provider != .chatGPTWeb else { return nil }

        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              value.isEmpty == false else {
            return nil
        }
        return value
    }

    func setAPIKey(_ apiKey: String, for provider: VoiceProviderID) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            try deleteAPIKey(for: provider)
            return
        }

        let data = Data(trimmed.utf8)
        let query = baseQuery(for: provider)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecSuccess { return }
        if status != errSecItemNotFound {
            throw APIKeyStoreError.unexpectedStatus(status)
        }

        var newItem = query
        newItem[kSecValueData as String] = data
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw APIKeyStoreError.unexpectedStatus(addStatus)
        }
    }

    func deleteAPIKey(for provider: VoiceProviderID) throws {
        let status = SecItemDelete(baseQuery(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.unexpectedStatus(status)
        }
    }

    func authorizationToken(forMCPServer id: UUID) -> String? {
        var query = baseQuery(account: mcpServerAccount(for: id))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              value.isEmpty == false else {
            return nil
        }
        return value
    }

    func setAuthorizationToken(_ token: String, forMCPServer id: UUID) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            try deleteAuthorizationToken(forMCPServer: id)
            return
        }

        let data = Data(trimmed.utf8)
        let query = baseQuery(account: mcpServerAccount(for: id))
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecSuccess { return }
        if status != errSecItemNotFound {
            throw APIKeyStoreError.unexpectedStatus(status)
        }

        var newItem = query
        newItem[kSecValueData as String] = data
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw APIKeyStoreError.unexpectedStatus(addStatus)
        }
    }

    func deleteAuthorizationToken(forMCPServer id: UUID) throws {
        let status = SecItemDelete(
            baseQuery(account: mcpServerAccount(for: id)) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for provider: VoiceProviderID) -> [String: Any] {
        baseQuery(account: provider.rawValue)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func mcpServerAccount(for id: UUID) -> String {
        "mcp-server.\(id.uuidString.lowercased())"
    }
}
