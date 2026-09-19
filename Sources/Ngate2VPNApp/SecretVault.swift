import Foundation

protocol SecretStoring {
    func saveSecret(account: String, value: String) throws
    func getSecret(account: String) throws -> String?
    func deleteSecret(account: String) throws
}

extension KeychainSecretStore: SecretStoring {}

/// Every tunnel's PIN/password in a **single** Keychain item.
///
/// macOS asks for Keychain access per item, and a rebuilt (re-signed) app has
/// to be re-approved for each one. One item means one prompt — for all
/// tunnels — instead of one per secret. The vault is read once and cached in
/// memory; every change rewrites the whole item.
///
/// Older versions stored one item per secret (`<tunnel-id>_pin` /
/// `<tunnel-id>_password`); those are migrated on first load and then deleted.
@MainActor
final class SecretVault {

    struct Entry: Codable, Equatable {
        var pin: String?
        var password: String?
    }

    static let account = "vault.v1"

    private let store: SecretStoring
    private let knownTunnelIDs: () -> [UUID]
    private var entries: [UUID: Entry]?

    init(store: SecretStoring, knownTunnelIDs: @escaping () -> [UUID]) {
        self.store = store
        self.knownTunnelIDs = knownTunnelIDs
    }

    func pin(for id: UUID) throws -> String? { try loaded()[id]?.pin }
    func password(for id: UUID) throws -> String? { try loaded()[id]?.password }

    /// Applies `change` to the tunnel's entry and saves. An entry left with
    /// neither secret is dropped.
    func update(_ id: UUID, _ change: (inout Entry) -> Void) throws {
        var all = try loaded()
        var entry = all[id] ?? Entry()
        change(&entry)
        if entry.pin == nil && entry.password == nil {
            all.removeValue(forKey: id)
        } else {
            all[id] = entry
        }
        try persist(all)
    }

    func remove(_ id: UUID) throws {
        var all = try loaded()
        guard all.removeValue(forKey: id) != nil else { return }
        try persist(all)
    }

    // MARK: - Loading

    private func loaded() throws -> [UUID: Entry] {
        if let entries { return entries }

        let result: [UUID: Entry]
        if let blob = try store.getSecret(account: Self.account) {
            guard let data = blob.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
                throw KeychainSecretStoreError.unexpectedData
            }
            result = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
        } else {
            result = try migrateLegacyItems()
        }
        entries = result
        return result
    }

    private func persist(_ all: [UUID: Entry]) throws {
        if all.isEmpty {
            try store.deleteSecret(account: Self.account)
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encodable = Dictionary(uniqueKeysWithValues: all.map { ($0.key.uuidString, $0.value) })
            let data = try encoder.encode(encodable)
            try store.saveSecret(account: Self.account, value: String(decoding: data, as: UTF8.self))
        }
        entries = all
    }

    // MARK: - Migration from per-secret items

    private static func legacyPinAccount(_ id: UUID) -> String { "\(id.uuidString)_pin" }
    private static func legacyPasswordAccount(_ id: UUID) -> String { "\(id.uuidString)_password" }

    /// Any read error aborts (and nothing is cached or written), so a denied
    /// Keychain prompt can simply be retried later instead of silently
    /// dropping that secret from the new vault.
    private func migrateLegacyItems() throws -> [UUID: Entry] {
        var migrated: [UUID: Entry] = [:]
        var legacyAccounts: [String] = []

        for id in knownTunnelIDs() {
            var entry = Entry()
            let pinAccount = Self.legacyPinAccount(id)
            if let pin = try store.getSecret(account: pinAccount), !pin.isEmpty {
                entry.pin = pin
                legacyAccounts.append(pinAccount)
            }
            let passwordAccount = Self.legacyPasswordAccount(id)
            if let password = try store.getSecret(account: passwordAccount), !password.isEmpty {
                entry.password = password
                legacyAccounts.append(passwordAccount)
            }
            if entry.pin != nil || entry.password != nil { migrated[id] = entry }
        }

        guard !migrated.isEmpty else { return [:] }

        try persist(migrated)
        for account in legacyAccounts { try? store.deleteSecret(account: account) }
        return migrated
    }
}
