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

protocol VoiceCredentialStoring: AnyObject {
    func hasAPIKey(for profile: VoiceProfile) -> Bool
    func apiKey(for profile: VoiceProfile) -> String?
    func setAPIKey(_ apiKey: String, for profile: VoiceProfile) throws
    func deleteAPIKey(for profile: VoiceProfile) throws
    func initializeCredentialScope(for profile: VoiceProfile) throws
    func authorizationToken(forMCPServer id: UUID) -> String?
    func setAuthorizationToken(_ token: String, forMCPServer id: UUID) throws
    func deleteAuthorizationToken(forMCPServer id: UUID) throws
}

extension VoiceCredentialStoring {
    func initializeCredentialScope(
        for profile: VoiceProfile
    ) throws {}
}

protocol KeychainAccountStoring: AnyObject {
    func value(service: String, account: String) -> String?
    func setValue(
        _ value: String,
        service: String,
        account: String
    ) throws
    func deleteValue(service: String, account: String) throws
}

final class SecurityKeychainAccountStore: KeychainAccountStoring {
    func value(service: String, account: String) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &item
        )
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              value.isEmpty == false else {
            return nil
        }
        return value
    }

    func setValue(
        _ value: String,
        service: String,
        account: String
    ) throws {
        let data = Data(value.utf8)
        let query = baseQuery(service: service, account: account)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )

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

    func deleteValue(service: String, account: String) throws {
        let status = SecItemDelete(
            baseQuery(service: service, account: account)
                as CFDictionary
        )
        guard status == errSecSuccess
                || status == errSecItemNotFound else {
            throw APIKeyStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(
        service: String,
        account: String
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

final class APIKeyStore: VoiceCredentialStoring {
    static let shared = APIKeyStore()

    private let service = "com.zigelbaum.VoiceKey"
    private let accountStore: KeychainAccountStoring

    init(
        accountStore: KeychainAccountStoring =
            SecurityKeychainAccountStore()
    ) {
        self.accountStore = accountStore
    }

    func hasAPIKey(for provider: VoiceProviderID) -> Bool {
        apiKey(for: provider) != nil
    }

    func apiKey(for provider: VoiceProviderID) -> String? {
        // ChatGPT Web authenticates through the provider's web sign-in and never uses a
        // stored key. Every other provider — including custom endpoints, where the key
        // is an optional bearer token — reads its key from the Keychain.
        guard provider != .chatGPTWeb else { return nil }

        return accountStore.value(
            service: service,
            account: provider.rawValue
        )
    }

    func setAPIKey(_ apiKey: String, for provider: VoiceProviderID) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            try deleteAPIKey(for: provider)
            return
        }

        try accountStore.setValue(
            trimmed,
            service: service,
            account: provider.rawValue
        )
    }

    func deleteAPIKey(for provider: VoiceProviderID) throws {
        try accountStore.deleteValue(
            service: service,
            account: provider.rawValue
        )
    }

    func hasAPIKey(for profile: VoiceProfile) -> Bool {
        apiKey(for: profile) != nil
    }

    func apiKey(for profile: VoiceProfile) -> String? {
        apiKey(
            for: profile.providerID,
            profileID: profile.id
        )
    }

    func setAPIKey(_ apiKey: String, for profile: VoiceProfile) throws {
        let trimmed = apiKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed.isEmpty == false else {
            try deleteAPIKey(for: profile)
            return
        }
        try accountStore.setValue(
            trimmed,
            service: service,
            account: account(
                for: profile.providerID,
                profileID: profile.id
            )
        )
        if profile.providerID == .custom {
            try accountStore.setValue(
                "1",
                service: service,
                account: customMigrationMarkerAccount(
                    for: profile.id
                )
            )
        }
    }

    func deleteAPIKey(for profile: VoiceProfile) throws {
        if profile.providerID == .custom {
            try accountStore.setValue(
                "1",
                service: service,
                account: customMigrationMarkerAccount(
                    for: profile.id
                )
            )
        }
        try accountStore.deleteValue(
            service: service,
            account: account(
                for: profile.providerID,
                profileID: profile.id
            )
        )
    }

    func initializeCredentialScope(
        for profile: VoiceProfile
    ) throws {
        guard profile.providerID == .custom else { return }
        // New custom channels must start with an empty, isolated account.
        // Existing persisted custom channels have no marker, so their first
        // read can still perform the one-time legacy migration below.
        try accountStore.setValue(
            "1",
            service: service,
            account: customMigrationMarkerAccount(
                for: profile.id
            )
        )
    }

    func apiKey(
        for provider: VoiceProviderID,
        profileID: UUID?
    ) -> String? {
        guard provider != .chatGPTWeb else { return nil }
        guard provider == .custom, let profileID else {
            return apiKey(for: provider)
        }

        let scopedAccount = account(
            for: provider,
            profileID: profileID
        )
        if let scoped = accountStore.value(
            service: service,
            account: scopedAccount
        ) {
            return scoped
        }
        if accountStore.value(
            service: service,
            account: customMigrationMarkerAccount(
                for: profileID
            )
        ) != nil {
            return nil
        }
        guard let legacy = accountStore.value(
            service: service,
            account: provider.rawValue
        ) else {
            return nil
        }
        // Keep the legacy item so every pre-existing custom channel can
        // silently migrate on its own first read.
        do {
            try accountStore.setValue(
                legacy,
                service: service,
                account: scopedAccount
            )
            try? accountStore.setValue(
                "1",
                service: service,
                account: customMigrationMarkerAccount(
                    for: profileID
                )
            )
        } catch {
            // Reading remains non-destructive; a later read can retry the
            // migration if Keychain was temporarily unavailable.
        }
        return legacy
    }

    func authorizationToken(forMCPServer id: UUID) -> String? {
        accountStore.value(
            service: service,
            account: mcpServerAccount(for: id)
        )
    }

    func setAuthorizationToken(_ token: String, forMCPServer id: UUID) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            try deleteAuthorizationToken(forMCPServer: id)
            return
        }

        try accountStore.setValue(
            trimmed,
            service: service,
            account: mcpServerAccount(for: id)
        )
    }

    func deleteAuthorizationToken(forMCPServer id: UUID) throws {
        try accountStore.deleteValue(
            service: service,
            account: mcpServerAccount(for: id)
        )
    }

    private func account(
        for provider: VoiceProviderID,
        profileID: UUID
    ) -> String {
        if provider == .custom {
            return "custom.\(profileID.uuidString.lowercased())"
        }
        return provider.rawValue
    }

    private func mcpServerAccount(for id: UUID) -> String {
        "mcp-server.\(id.uuidString.lowercased())"
    }

    private func customMigrationMarkerAccount(
        for profileID: UUID
    ) -> String {
        "custom.\(profileID.uuidString.lowercased()).migrated"
    }
}
