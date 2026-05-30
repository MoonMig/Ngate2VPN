import Foundation

// MARK: - PersistedState

/// On-disk shape of the user's app configuration. Lives in UserDefaults
/// under a single key, encoded as JSON. Anything kept here survives
/// quit/relaunch.
///
/// **Out of scope.** Per-tunnel runtime state (status, log lines, last
/// error) is *not* persisted — it's reconstructed from scratch on every
/// launch. Credentials are *not* persisted here either; they live in
/// the macOS Keychain and are referenced by tunnel UUID.
struct PersistedState: Codable {
    var binaryPath: String
    var hideDockOnClose: Bool
    var tunnels: [TunnelConfiguration]

    init(binaryPath: String,
         hideDockOnClose: Bool,
         tunnels: [TunnelConfiguration]) {
        self.binaryPath = binaryPath
        self.hideDockOnClose = hideDockOnClose
        self.tunnels = tunnels
    }

    private enum CodingKeys: String, CodingKey {
        case binaryPath
        case hideDockOnClose
        case tunnels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        binaryPath = try c.decode(String.self, forKey: .binaryPath)
        hideDockOnClose = try c.decode(Bool.self, forKey: .hideDockOnClose)
        tunnels = try c.decode([TunnelConfiguration].self, forKey: .tunnels)
    }
}

// MARK: - TunnelPersistence

/// Single source of truth for "where do user-level app settings go".
///
/// Pulling this out of `AppState` removes a small but persistent source
/// of confusion: every reader of `AppState` had to know that there was
/// also a separate `loadDefaults()` static at the bottom of the file
/// that reached into UserDefaults with a magic string key. The same key
/// was repeated in two places, which is exactly the kind of duplication
/// that silently rots when the schema changes.
///
/// **Why a struct, not free functions.** Lets us centralise the
/// `JSONEncoder` / `JSONDecoder` instances (they're cheap to make but
/// nicer to share) and eventually plug in versioning if needed.
enum TunnelPersistence {

    /// UserDefaults key under which `PersistedState` is stored. Treat
    /// this as a permanent identifier — changing it migrates everyone
    /// to a clean state on next launch.
    private static let storageKey = "ngate2vpn.saved.state"

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Loads the persisted state, or `nil` if there's nothing stored
    /// yet (first launch) or the stored data fails to decode (schema
    /// mismatch — we treat that as "start fresh", same as the previous
    /// implementation did via `try?`).
    static func load() -> PersistedState? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? decoder.decode(PersistedState.self, from: data)
    }

    /// Writes `state` to UserDefaults. Failures are silently ignored,
    /// matching the prior behaviour — encoding can't fail for our
    /// schema, and UserDefaults `set` doesn't surface I/O errors.
    static func save(_ state: PersistedState) {
        guard let data = try? encoder.encode(state) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
