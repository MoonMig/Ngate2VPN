import XCTest
@testable import Ngate2VPNApp

private final class FakeStore: SecretStoring, @unchecked Sendable {
    struct Denied: Error {}

    var items: [String: String] = [:]
    var failReads: Set<String> = []
    private(set) var reads: [String] = []

    func saveSecret(account: String, value: String) throws { items[account] = value }
    func getSecret(account: String) throws -> String? {
        reads.append(account)
        if failReads.contains(account) { throw Denied() }
        return items[account]
    }
    func deleteSecret(account: String) throws { items.removeValue(forKey: account) }
}

@MainActor
final class SecretVaultTests: XCTestCase {

    private let a = UUID()
    private let b = UUID()

    func testAllSecretsLiveInOneKeychainItem() throws {
        let store = FakeStore()
        let vault = SecretVault(store: store, knownTunnelIDs: { [] })

        try vault.update(a) { $0.pin = "1111" }
        try vault.update(b) { $0.password = "hunter2" }

        XCTAssertEqual(Array(store.items.keys), [SecretVault.account], "one item, not one per secret")
        XCTAssertEqual(try vault.pin(for: a), "1111")
        XCTAssertEqual(try vault.password(for: b), "hunter2")
        XCTAssertNil(try vault.password(for: a))
    }

    func testValuesSurviveAFreshInstance() throws {
        let store = FakeStore()
        try SecretVault(store: store, knownTunnelIDs: { [] }).update(a) { $0.pin = "1111" }

        let reloaded = SecretVault(store: store, knownTunnelIDs: { [] })
        XCTAssertEqual(try reloaded.pin(for: a), "1111")
    }

    func testVaultIsReadOnlyOnce() throws {
        let store = FakeStore()
        try SecretVault(store: store, knownTunnelIDs: { [] }).update(a) { $0.pin = "1111" }

        let readsBefore = store.reads.count
        let vault = SecretVault(store: store, knownTunnelIDs: { [] })
        _ = try vault.pin(for: a)
        _ = try vault.pin(for: a)
        _ = try vault.password(for: b)
        XCTAssertEqual(store.reads.count - readsBefore, 1, "cached after the first read")
    }

    func testEntryWithNoSecretsIsDroppedAndEmptyVaultDeleted() throws {
        let store = FakeStore()
        let vault = SecretVault(store: store, knownTunnelIDs: { [] })
        try vault.update(a) { $0.pin = "1111" }
        try vault.update(a) { $0.pin = nil }

        XCTAssertNil(try vault.pin(for: a))
        XCTAssertTrue(store.items.isEmpty, "an empty vault must not linger in the Keychain")
    }

    func testRemoveOnlyAffectsThatTunnel() throws {
        let store = FakeStore()
        let vault = SecretVault(store: store, knownTunnelIDs: { [] })
        try vault.update(a) { $0.pin = "1111" }
        try vault.update(b) { $0.password = "pw" }

        try vault.remove(a)
        XCTAssertNil(try vault.pin(for: a))
        XCTAssertEqual(try vault.password(for: b), "pw")
    }

    func testLegacyPerSecretItemsAreMigratedAndDeleted() throws {
        let store = FakeStore()
        store.items["\(a.uuidString)_pin"] = "1111"
        store.items["\(b.uuidString)_password"] = "hunter2"
        let vault = SecretVault(store: store, knownTunnelIDs: { [self.a, self.b] })

        XCTAssertEqual(try vault.pin(for: a), "1111")
        XCTAssertEqual(try vault.password(for: b), "hunter2")
        XCTAssertEqual(Array(store.items.keys), [SecretVault.account], "legacy items replaced by the single vault item")
    }

    func testExistingVaultIsNotOverwrittenByLegacyMigration() throws {
        let store = FakeStore()
        try SecretVault(store: store, knownTunnelIDs: { [] }).update(a) { $0.pin = "new" }
        store.items["\(a.uuidString)_pin"] = "stale-legacy"

        let vault = SecretVault(store: store, knownTunnelIDs: { [self.a] })
        XCTAssertEqual(try vault.pin(for: a), "new")
        XCTAssertFalse(store.reads.contains("\(a.uuidString)_pin"), "legacy items are not touched once a vault exists")
    }

    func testDeniedLegacyReadAbortsWithoutLosingSecretsAndCanBeRetried() throws {
        let store = FakeStore()
        store.items["\(a.uuidString)_pin"] = "1111"
        store.items["\(b.uuidString)_password"] = "hunter2"
        store.failReads = ["\(b.uuidString)_password"]
        let vault = SecretVault(store: store, knownTunnelIDs: { [self.a, self.b] })

        XCTAssertThrowsError(try vault.pin(for: a))
        XCTAssertNil(store.items[SecretVault.account], "nothing is written after a partial read")
        XCTAssertEqual(store.items["\(a.uuidString)_pin"], "1111", "legacy items stay until migration fully succeeds")

        store.failReads = []
        XCTAssertEqual(try vault.pin(for: a), "1111")
        XCTAssertEqual(try vault.password(for: b), "hunter2")
    }

    func testCorruptVaultIsReportedNotOverwritten() throws {
        let store = FakeStore()
        store.items[SecretVault.account] = "not json"
        let vault = SecretVault(store: store, knownTunnelIDs: { [] })

        XCTAssertThrowsError(try vault.pin(for: a))
        XCTAssertThrowsError(try vault.update(a) { $0.pin = "x" })
        XCTAssertEqual(store.items[SecretVault.account], "not json")
    }
}
