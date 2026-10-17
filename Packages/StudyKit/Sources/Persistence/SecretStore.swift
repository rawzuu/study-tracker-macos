import Foundation
import Security
import Synchronization

/// Úložiště tajných údajů (token ke GitHubu). V aplikaci Klíčenka, v testech paměť.
public protocol SecretStore: Sendable {
    func secret(for account: String) throws -> String?
    /// `nil` údaj smaže.
    func setSecret(_ value: String?, for account: String) throws
}

public struct KeychainError: Error, Sendable, Hashable, LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "\(status)"
        return "Klíčenka: \(detail)"
    }
}

/// Token v Klíčence macOS (obecné heslo). Položka patří jen této aplikaci – jiné aplikace
/// k ní bez svolení nemají přístup – a nesynchronizuje se přes iCloud.
public struct KeychainStore: SecretStore {
    public let service: String

    /// Služba podle identifikátoru aplikace: vývojové sestavení (`….dev`) nikdy nevidí token ostré aplikace.
    public init(service: String = Bundle.main.bundleIdentifier ?? "cz.rawzuu.studytracker") {
        self.service = service
    }

    public func secret(for account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func setSecret(_ value: String?, for account: String) throws {
        guard let value else {
            let status = SecItemDelete(baseQuery(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Study Tracker – \(account)"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// Tajné údaje jen v paměti – pro testy, náhledy a UI testy (nikdy nesahají na skutečnou Klíčenku).
public final class InMemorySecretStore: SecretStore {
    private let values: Mutex<[String: String]>

    public init(_ values: [String: String] = [:]) {
        self.values = Mutex(values)
    }

    public func secret(for account: String) throws -> String? {
        values.withLock { $0[account] }
    }

    public func setSecret(_ value: String?, for account: String) throws {
        values.withLock { $0[account] = value }
    }
}
