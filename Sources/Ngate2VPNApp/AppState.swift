import Foundation
import SwiftUI
import Combine
import CryptoKit

@MainActor
final class AppState: ObservableObject {
    @Published var tunnels: [TunnelConfiguration]
    @Published var runtime: [UUID: TunnelRuntimeState]
    @Published var systemLogLines: [String] = []
    @Published var binaryPath: String
    @Published var hideDockOnClose = false
    @Published var selectedTab: AppTab = .home

    /// DNS Helper — aggregates DNS config from all active tunnels and applies
    /// a unified split-DNS policy. Optional feature, opt-in from Settings.
    let dnsPolicy = DNSPolicyController()
    lazy var dnsApplier: DNSApplier = {
        let applier = DNSApplier(policyController: dnsPolicy)
        applier.onDiagnostic = { [weak self] message, level in
            // DNS Helper events are app-wide, not tied to any single tunnel.
            // The diagnostic message already starts with "[SYSTEM] DNS Helper:"
            // so we strip that prefix and let appendBulkSystemLog re-add a
            // single "[SYSTEM]" tag with the correct level.
            let cleaned = message.hasPrefix("[SYSTEM] ")
                ? String(message.dropFirst("[SYSTEM] ".count))
                : message
            Task(priority: nil) { @MainActor [weak self] in
                self?.appendBulkSystemLog(cleaned, level: level)
            }
        }
        return applier
    }()

    /// Per-tunnel parsers that watch the log stream for the gateway response
    /// JSON containing DNSs / SearchDomains. Created lazily on first log
    /// line, dropped when the tunnel disconnects.
    var dnsParsers: [UUID: NgateGatewayResponseParser] = [:]
    @Published var selectedTunnelID: UUID?
    @Published var alertTitle: String?
    @Published var alertMessage: String?
    @Published var isAlertPresented: Bool = false
    
    var statusIconManager: StatusIconManager?
    let keychain = KeychainSecretStore()
    lazy var vault = SecretVault(store: keychain, knownTunnelIDs: { [weak self] in self?.tunnels.map(\.id) ?? [] })
    let processManager = TunnelProcessManager()
    var fileLoggers: [UUID: FileLogger] = [:]
    var disconnectRequested = Set<UUID>()
    /// When a pre-warmed client was handed to each tunnel; used to spot a warm client that the gateway/client rejects right away.
    var warmAdoptedAt: [UUID: Date] = [:]
    var cancellables = Set<AnyCancellable>()
    var connectAllTask: Task<Void, Never>?
    var activeStartupTunnelIDs = Set<UUID>()
    var watchdogTask: Task<Void, Never>?
    let tokenMonitor = TokenMonitor()
    var tokenStateKnown = false
    var tokenPresent = false

    /// Queue of alerts waiting to be shown. When an alert is already on
    /// screen, additional alerts go here instead of being dropped, so
    /// e.g. two tunnels failing at the same time both surface their
    /// own error to the user. After the current alert is dismissed, we
    /// pop the head of this queue and present it.
    ///
    /// Each entry carries a `key` so we can deduplicate identical
    /// alerts within a short window — typically the same error
    /// produces several log lines from ngate, but the user only wants
    /// one popup per failure per tunnel.
    var pendingAlerts: [(key: String, title: String, message: String)] = []
    var recentAlertKeys: [String: Date] = [:]
    let alertDedupWindow: TimeInterval = 1.5
    var watchdogRestartingTunnels = Set<UUID>()
    var deletingTunnelIDs = Set<UUID>()
    // Certificate-based tunnels using a hardware token (Jacarta/CryptoPro CSP)
    // can spend 60+ seconds initialising the certificate storage before the
    // first VPN session is created, especially when multiple tunnels contend
    // for the same reader simultaneously. 120 s gives a comfortable margin.
    let connectAllTimeout: TimeInterval = 120
    let startupRetryLimit = 1
    let watchdogInterval: TimeInterval = 5

    /// In-memory cap on `runtime[id].logLines`, per tunnel. Older entries
    /// are dropped once the buffer overshoots `maxLogLinesPerTunnel +
    /// logTrimSlack`, which amortises the cost of `removeFirst(_:)` —
    /// trimming N elements at a time off an Array is O(buffer-size), so
    /// doing it once every K appends instead of on every overflow keeps
    /// the per-line cost roughly constant.
    ///
    /// Older lines remain available on disk via `FileLogger`'s rotated
    /// log files (5 MB each, kept for 30 days). The journal UI shows only
    /// what's in memory.
    ///
    /// 30 k entries ≈ 3 MB at typical line lengths, ≈ 1–3 hours of
    /// `-vvvv` ngate output. Cap is per-tunnel — five active tunnels
    /// peak at ≈ 15 MB total, well within reason for a desktop app.
    let maxLogLinesPerTunnel: Int = 30_000

    /// Same idea as `maxLogLinesPerTunnel`, but for the app-wide
    /// `[SYSTEM]` event stream. System events are emitted much more
    /// rarely (helper status, watchdog actions), so a smaller cap is
    /// plenty.
    let maxSystemLogLines: Int = 5_000

    /// Allowed overshoot before we run a trim pass. Larger values make
    /// trims rarer (cheaper amortised cost) at the price of a slightly
    /// fuzzier in-memory cap.
    let logTrimSlack: Int = 1_000

    init() {
        self.binaryPath = "/opt/cprongate/ngateconsoleclient"
        self.runtime = [:]
        if let saved = TunnelPersistence.load() {
            // Deliberately NOT sanitized yet: a profile saved by a very old build
            // may still carry its PIN/password, and the migration below must see
            // it to move it into the Keychain before stripping it.
            self.tunnels = saved.tunnels
            self.binaryPath = saved.binaryPath
            self.hideDockOnClose = saved.hideDockOnClose
        } else {
            self.tunnels = []
        }
        for t in tunnels { runtime[t.id] = TunnelRuntimeState() }
        selectedTunnelID = tunnels.first?.id
        // Before any persist() (the sinks below fire one immediately): moves
        // legacy in-JSON secrets to the Keychain and strips them from memory.
        migratePersistedSecretsToKeychainIfNeeded()
        
        $hideDockOnClose
            .sink { [weak self] _ in self?.persist() }
            .store(in: &cancellables)

        $binaryPath
            .sink { [weak self] _ in self?.persist() }
            .store(in: &cancellables)

        startWatchdog()
        persist()
        observeSystemWake()

        Task.detached(priority: .background) {
            await LogWriterActor.deleteOldLogs(olderThanDays: 30)
        }

        // Sync holdDefaultDNS from storage before the first policy application
        // so the correct value is used even if the Settings tab is never opened.
        dnsPolicy.holdDefaultDNS = UserDefaults.standard.object(forKey: "holdDefaultDNS") as? Bool ?? true

        // Force-initialize dnsApplier so it subscribes to policy changes immediately.
        // Without this, DNSApplier is only created when the Settings tab is visited
        // or on app quit — meaning DNS Helper is completely inert after a restart
        // if the user never opens Settings.
        _ = dnsApplier

        startPrewarmSupport()
    }

    deinit {
        watchdogTask?.cancel()
        processManager.terminateAll()
    }
    
    func snapshot(for id: UUID) -> TunnelSnapshot? {
        guard let c = tunnels.first(where: { $0.id == id }), let r = runtime[id] else { return nil }
        return TunnelSnapshot(configuration: c, runtime: r)
    }
    
    /// True if at least one tunnel is connecting, connected, or disconnecting.
    /// Used by Disconnect All to know whether there is anything to act on.
    var anyTunnelActive: Bool {
        tunnels.contains { tunnel in
            switch runtime[tunnel.id]?.status {
            case .running, .degraded, .starting, .stopping: return true
            default: return false
            }
        }
    }

    /// True only if every tunnel is currently active (connected or transitioning).
    /// Used by Connect All to disable when nothing more can be connected.
    var allTunnelsActive: Bool {
        guard !tunnels.isEmpty else { return false }
        return tunnels.allSatisfy { tunnel in
            switch runtime[tunnel.id]?.status {
            case .running, .degraded, .starting, .stopping: return true
            default: return false
            }
        }
    }
    func clearLog(for id: UUID) { runtime[id]?.logLines = [] }
    func clearSystemLog() { systemLogLines = [] }
    func addTunnel() {
        let shouldStartWatchdog = tunnels.isEmpty
        let t = TunnelConfiguration(title: "Profile \(tunnels.count + 1)")
        tunnels.append(t); runtime[t.id] = TunnelRuntimeState()
        selectedTunnelID = t.id; persist()
        if shouldStartWatchdog {
            startWatchdog()
        }
    }
    func removeTunnel(_ id: UUID) {
        guard deletingTunnelIDs.contains(id) == false else { return }
        Task { [weak self] in
            await self?.removeTunnelAtomically(id)
        }
    }
    func toggleConnection(for id: UUID) {
        guard let st = runtime[id]?.status else { return }
        switch st {
        case .stopped, .failed:
            // Manual user action — clear any watchdog suspension and
            // reset the backoff counter so we get the full attempt
            // budget on this fresh connection.
            if runtime[id]?.watchdogPaused == true {
                appendSystemLog("Watchdog auto-reconnect resumed by user", to: id)
            }
            runtime[id]?.watchdogPaused = false
            runtime[id]?.consecutiveWatchdogFailures = 0
            runtime[id]?.lastWatchdogRestartAt = nil
            connectTunnel(id)
        case .starting, .running, .degraded, .stopping:
            disconnectTunnel(id)
        }
    }
    func updateTunnel(_ configuration: TunnelConfiguration) {
        if let idx = tunnels.firstIndex(where: { $0.id == configuration.id }) {
            saveSecretsIfNeeded(from: configuration)
            tunnels[idx] = Self.sanitizedConfiguration(configuration)
            persist()
            processManager.discardWarm(tunnelID: configuration.id)
            schedulePrewarm(only: [configuration.id], delay: 2)
        }
    }
    
    func persist() {
        let state = PersistedState(
            binaryPath: binaryPath,
            hideDockOnClose: hideDockOnClose,
            tunnels: tunnels
        )
        TunnelPersistence.save(state)
    }
    func shutdown() {
        cancelConnectAllSequence()
        watchdogTask?.cancel()
        processManager.terminateAll()
    }
    
    func removeTunnelAtomically(_ id: UUID) async {
        guard tunnels.contains(where: { $0.id == id }) else { return }

        if activeStartupTunnelIDs.contains(id) {
            cancelConnectAllSequence()
        }

        watchdogTask?.cancel()
        watchdogTask = nil
        deletingTunnelIDs.insert(id)
        watchdogRestartingTunnels.remove(id)
        disconnectRequested.insert(id)
        processManager.discardWarm(tunnelID: id)

        let stopped = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.processManager.terminateAndWait(tunnelID: id)
                continuation.resume(returning: result)
            }
        }

        if stopped == false {
            appendSystemLog("Forced tunnel deletion after stop timeout", to: id, level: .warning)
            processManager.forceKill(tunnelID: id)
            let forceStopped = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = self.processManager.terminateAndWait(tunnelID: id, timeout: 2)
                    continuation.resume(returning: result)
                }
            }
            if forceStopped == false {
                deletingTunnelIDs.remove(id)
                disconnectRequested.remove(id)
                let message = "Failed to stop tunnel before deletion"
                transitionState(id: id, newState: .failed, errorMessage: message, tunnelError: .processExited)
                showAlert(title: "Delete Error", message: message, for: id)
                return
            }
        }

        fileLoggers.removeValue(forKey: id)
        runtime.removeValue(forKey: id)
        tunnels.removeAll { $0.id == id }
        if selectedTunnelID == id { selectedTunnelID = tunnels.first?.id }
        persist()
        deleteStoredSecrets(for: id)
        disconnectRequested.remove(id)
        deletingTunnelIDs.remove(id)
        startWatchdog()
    }

}
