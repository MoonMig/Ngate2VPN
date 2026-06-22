import Foundation
import SwiftUI
import Combine

enum SystemLogLevel: String {
    case info = "Info"
    case warning = "Warning"
    case error = "Error"
    case critical = "Critical"
}

enum TunnelAuthMethod: String, Codable, CaseIterable, Identifiable {
    case certificate, credentials
    var id: String { rawValue }
    var title: String { self == .certificate ? "Certificate" : "Login" }
}

struct TunnelConfiguration: Codable, Identifiable, Equatable {
    let id: UUID
    var title, endpointURL, serialNumber, pinCode, username, password: String
    var authMethod: TunnelAuthMethod
    /// When true, the watchdog will reconnect this tunnel automatically after
    /// any unexpected disconnect (network drop, process crash), regardless of
    /// how many consecutive failures occur. Manual disconnects (via the UI)
    /// are never retried — they always leave the tunnel in .stopped.
    var autoReconnect: Bool = false
    init(id: UUID = UUID(), title: String, endpointURL: String = "", authMethod: TunnelAuthMethod = .certificate, serialNumber: String = "", pinCode: String = "", username: String = "", password: String = "", autoReconnect: Bool = false) {
        self.id = id; self.title = title; self.endpointURL = endpointURL
        self.authMethod = authMethod; self.serialNumber = serialNumber
        self.pinCode = pinCode; self.username = username; self.password = password
        self.autoReconnect = autoReconnect
    }
}

/// Prevents sensitive fields from appearing in debug output, logs, or crash reports.
extension TunnelConfiguration: CustomDebugStringConvertible {
    var debugDescription: String {
        "TunnelConfiguration(id: \(id), title: \(title), endpoint: \(endpointURL), auth: \(authMethod))"
    }
}

extension TunnelState {
    var title: String { switch self {
        case .stopped: return "Disconnected"
        case .starting: return "Connecting"
        case .running: return "Connected"
        case .degraded: return "Degraded"
        case .stopping: return "Disconnecting"
        case .failed: return "Failed"
    }}
    var color: Color { switch self {
        case .stopped: return Color(red: 0.34, green: 0.40, blue: 0.47)
        case .starting, .stopping: return Color(red: 0.84, green: 0.56, blue: 0.16)
        case .running: return Color(red: 0.12, green: 0.62, blue: 0.41)
        case .degraded: return Color(red: 0.89, green: 0.62, blue: 0.14)
        case .failed: return Color(red: 0.78, green: 0.24, blue: 0.20)
    }}
}

enum TunnelError: String, Codable {
    case invalidCredentials
    case certificateNotFound
    case invalidCertificateHash
    case serverCertificateNameMismatch
    case networkUnreachable
    case connectionRefused
    case gatewayUnreachable
    case invalidEndpoint
    case sessionRefreshFailed
    case startupTimeout
    case processExited
    case launchFailed
    case unknown

    var isRetryable: Bool {
        switch self {
        case .networkUnreachable, .connectionRefused, .gatewayUnreachable, .startupTimeout, .sessionRefreshFailed:
            return true
        case .invalidCredentials, .certificateNotFound, .invalidCertificateHash,
             .serverCertificateNameMismatch, .processExited, .launchFailed,
             .unknown, .invalidEndpoint:
            return false
        }
    }

    var message: String {
        switch self {
        case .invalidCredentials: return "Invalid credentials"
        case .certificateNotFound: return "Certificate not found"
        case .invalidCertificateHash: return "Invalid certificate hash"
        case .serverCertificateNameMismatch:
            return "The server's TLS certificate does not match this gateway's host name. The administrator needs to fix the certificate, or the URL is wrong."
        case .networkUnreachable: return "Network unreachable"
        case .connectionRefused: return "Connection refused"
        case .gatewayUnreachable: return "Gateway unreachable"
        case .invalidEndpoint: return "Invalid server URL"
        case .sessionRefreshFailed: return "VPN session was closed by server. Reconnecting…"
        case .startupTimeout: return "Startup timed out"
        case .processExited: return "Tunnel process exited unexpectedly"
        case .launchFailed: return "Tunnel failed to start"
        case .unknown: return "Unknown tunnel error"
        }
    }
}

struct TunnelRuntimeState {
    var status: TunnelState = .stopped
    var logLines: [String] = []
    var launchedAt: Date?
    var lastStateChange: Date?
    var errorMessage: String?
    var lastError: TunnelError?
    var hasEstablishedConnection = false
    var isNgateReconnecting = false
    var lastWatchdogRestartAt: Date?
    var clientAddress: String?

    /// How many times in a row the watchdog has had to restart this tunnel
    /// without it ever reaching `.running` and going online. Drives
    /// exponential backoff and the auto-reconnect circuit breaker.
    /// Reset to 0 on a successful "vpn online".
    var consecutiveWatchdogFailures: Int = 0

    /// Once the watchdog has tried `watchdogMaxConsecutiveFailures` times
    /// and given up, this is set to true and auto-reconnect stops. The
    /// user has to take an explicit action (toggle off + on, click Connect)
    /// to clear this. Prevents infinite spam in the journal when a remote
    /// gateway is genuinely unreachable for hours.
    var watchdogPaused: Bool = false
}

struct TunnelSnapshot {
    let configuration: TunnelConfiguration
    let runtime: TunnelRuntimeState
}

@MainActor
final class AppState: ObservableObject {
    @Published var tunnels: [TunnelConfiguration]
    @Published private(set) var runtime: [UUID: TunnelRuntimeState]
    @Published private(set) var systemLogLines: [String] = []
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
    private var dnsParsers: [UUID: NgateGatewayResponseParser] = [:]
    @Published var selectedTunnelID: UUID?
    @Published var alertTitle: String?
    @Published var alertMessage: String?
    @Published var isAlertPresented: Bool = false
    
    var statusIconManager: StatusIconManager?
    private let keychain = KeychainSecretStore()
    private let processManager = TunnelProcessManager()
    private var fileLoggers: [UUID: FileLogger] = [:]
    private var disconnectRequested = Set<UUID>()
    private var cancellables = Set<AnyCancellable>()
    private var connectAllTask: Task<Void, Never>?
    private var activeStartupTunnelIDs = Set<UUID>()
    private var watchdogTask: Task<Void, Never>?

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
    private var pendingAlerts: [(key: String, title: String, message: String)] = []
    private var recentAlertKeys: [String: Date] = [:]
    private let alertDedupWindow: TimeInterval = 1.5
    private var watchdogRestartingTunnels = Set<UUID>()
    private var deletingTunnelIDs = Set<UUID>()
    let connectAllTimeout: TimeInterval = 30
    private let startupRetryLimit = 1
    private let watchdogInterval: TimeInterval = 5

    /// Base delay between watchdog restart attempts. Each consecutive
    /// failure doubles the delay (capped by `watchdogMaxBackoff`), so the
    /// app doesn't spam reconnect attempts when a remote gateway is down.
    private let watchdogBaseBackoff: TimeInterval = 5

    /// Upper bound on the per-attempt backoff delay. Reaching this means
    /// the app will keep retrying once every 15 minutes — slow enough not
    /// to flood the log, frequent enough that recovery happens within a
    /// reasonable window after the gateway is back.
    private let watchdogMaxBackoff: TimeInterval = 15 * 60

    /// Number of consecutive failed restart attempts after which the
    /// watchdog gives up and waits for the user to act. Prevents the
    /// journal from filling with restart noise during multi-hour outages.
    /// 8 attempts with 5s base ≈ 21 minutes of automatic retries.
    private let watchdogMaxConsecutiveFailures: Int = 8

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
    private let maxLogLinesPerTunnel: Int = 30_000

    /// Same idea as `maxLogLinesPerTunnel`, but for the app-wide
    /// `[SYSTEM]` event stream. System events are emitted much more
    /// rarely (helper status, watchdog actions), so a smaller cap is
    /// plenty.
    private let maxSystemLogLines: Int = 5_000

    /// Allowed overshoot before we run a trim pass. Larger values make
    /// trims rarer (cheaper amortised cost) at the price of a slightly
    /// fuzzier in-memory cap.
    private let logTrimSlack: Int = 1_000

    init() {
        self.binaryPath = "/opt/cprongate/ngateconsoleclient"
        self.runtime = [:]
        if let saved = TunnelPersistence.load() {
            self.tunnels = saved.tunnels.map(Self.sanitizedConfiguration)
            self.binaryPath = saved.binaryPath
            self.hideDockOnClose = saved.hideDockOnClose
        } else {
            self.tunnels = []
        }
        for t in tunnels { runtime[t.id] = TunnelRuntimeState() }
        selectedTunnelID = tunnels.first?.id
        
        $hideDockOnClose
            .sink { [weak self] _ in self?.persist() }
            .store(in: &cancellables)

        $binaryPath
            .sink { [weak self] _ in self?.persist() }
            .store(in: &cancellables)

        startWatchdog()
        migratePersistedSecretsToKeychainIfNeeded()
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
    }
    
    deinit {
        watchdogTask?.cancel()
        processManager.terminateAll()
    }
    
    func snapshot(for id: UUID) -> TunnelSnapshot? {
        guard let c = tunnels.first(where: { $0.id == id }), let r = runtime[id] else { return nil }
        return TunnelSnapshot(configuration: c, runtime: r)
    }
    
    func connectTunnel(_ id: UUID) {
        guard let s = snapshot(for: id) else { return }
        guard canStartTunnel(id) else { return }
        guard let configuration = resolvedConfigurationForStart(tunnelID: id, from: s.configuration) else { return }
        let v = validate(configuration)
        guard v.isEmpty else { appendSystemLog("Error: \(v.joined(separator: ", "))", to: id, level: .error); transitionState(id: id, newState: .failed); return }
        let url = URL(fileURLWithPath: binaryPath)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            let msg = "VPN client binary not found at:\n\(binaryPath)\n\nUpdate the path in Settings → Application → Binary."
            appendSystemLog("Binary not found", to: id, level: .error)
            transitionState(id: id, newState: .failed)
            showAlert(title: "Binary Not Found", message: msg, for: id)
            return
        }
        disconnectRequested.remove(id)
        runtime[id]?.hasEstablishedConnection = false
        runtime[id]?.isNgateReconnecting = false
        runtime[id]?.lastError = nil
        runtime[id]?.clientAddress = nil
        transitionState(id: id, newState: .starting)
        do {
            try processManager.launch(tunnelID: id, binaryPath: url.path, configuration: configuration,
                onOutput: { [weak self] t in Task { @MainActor in self?.appendLog(t, to: id) } },
                onStateChange: { [weak self] state in Task { @MainActor in self?.handleProcessStateChange(id, state: state) } },
                onExit: { [weak self] c in Task { @MainActor in self?.handleExit(id, code: c) } })
            runtime[id]?.launchedAt = Date()
        } catch {
            let launchError = TunnelError.launchFailed
            let errorMsg = "Failed to start: \(error.localizedDescription)"
            appendSystemLog(errorMsg, to: id, level: .error)
            applyConnectionError(launchError, to: id, alertMessage: errorMsg)
        }
    }
    
    func disconnectTunnel(_ id: UUID) {
        if activeStartupTunnelIDs.contains(id) {
            cancelConnectAllSequence()
        }
        guard canStopTunnel(id) else { return }
        disconnectRequested.insert(id)
        watchdogRestartingTunnels.remove(id)
        processManager.terminate(tunnelID: id)
        appendSystemLog("Disconnect requested", to: id)
    }
    
    func connectAll() {
        guard !tunnels.isEmpty else { return }
        guard connectAllTask == nil else {
            appendBulkSystemLog("Connect All ignored: startup sequence is already in progress")
            return
        }

        let tunnelIDs = tunnels.map(\.id)
        // User explicitly asked to start everything — clear any watchdog
        // suspensions / backoff so all tunnels get the full retry budget
        // on this attempt.
        for id in tunnelIDs {
            if runtime[id]?.watchdogPaused == true {
                appendSystemLog("Watchdog auto-reconnect resumed by user", to: id)
            }
            runtime[id]?.watchdogPaused = false
            runtime[id]?.consecutiveWatchdogFailures = 0
            runtime[id]?.lastWatchdogRestartAt = nil
        }
        connectAllTask = Task { [weak self] in
            guard let self else { return }
            await self.runConnectAllSequence(tunnelIDs)
        }
    }
    func disconnectAll() {
        cancelConnectAllSequence()
        tunnels.forEach { disconnectTunnel($0.id) }
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
    
    func showAlert(title: String, message: String) {
        showAlert(title: title, message: message, dedupKey: title + "|" + message)
    }

    /// Convenience overload — prefixes the alert title with "[Profile name]"
    /// so the user immediately knows which tunnel the error belongs to when
    /// running multiple profiles. Dedup key includes the tunnel ID so the
    /// same error from two different tunnels surfaces twice (once per
    /// tunnel) instead of being deduped together.
    func showAlert(title: String, message: String, for tunnelID: UUID) {
        let profile = tunnelTitle(for: tunnelID)
        let prefixed = "[\(profile)] \(title)"
        showAlert(title: prefixed, message: message,
                  dedupKey: "\(tunnelID.uuidString)|\(title)|\(message)")
    }

    /// Internal entry point. `dedupKey` is what we hash to decide
    /// whether this is a duplicate of an alert we just showed for the
    /// same situation (e.g. ngate spamming the same log line). Window
    /// is `alertDedupWindow` seconds.
    private func showAlert(title: String, message: String, dedupKey: String) {
        // User preference — when disabled, error popups are suppressed entirely.
        // The errors still appear in the Journal, just without an alert window.
        let alertsEnabled = UserDefaults.standard.object(forKey: "showErrorAlerts") as? Bool ?? true
        guard alertsEnabled else { return }

        // Drop true duplicates within the dedup window. Different tunnels
        // hit different keys (because we include tunnelID), so a cert
        // failure on tunnel A and tunnel B are not deduped together —
        // both surface separately.
        let now = Date()
        if let last = recentAlertKeys[dedupKey],
           now.timeIntervalSince(last) < alertDedupWindow {
            return
        }
        recentAlertKeys[dedupKey] = now
        prunePastAlertKeys(now: now)

        // Already showing one? Queue this for after dismissal.
        if isAlertPresented {
            // Avoid stacking the same alert twice in the queue.
            if !pendingAlerts.contains(where: { $0.key == dedupKey }) {
                pendingAlerts.append((key: dedupKey, title: title, message: message))
            }
            return
        }

        // No alert on screen — present this one immediately.
        alertTitle = title
        alertMessage = message
        isAlertPresented = true
    }

    func dismissAlert() {
        alertTitle = nil
        alertMessage = nil
        isAlertPresented = false

        // Pop the next pending alert, if any. Slight delay lets AppKit
        // tear down the previous NSAlert window before we open the
        // next one — without this, the system can briefly think two
        // alerts are stacked and refuse user clicks on the new one.
        guard !pendingAlerts.isEmpty else { return }
        let next = pendingAlerts.removeFirst()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self else { return }
            // Re-check; user might have triggered a new alert in the
            // meantime via some other code path.
            guard !isAlertPresented else {
                // Re-queue at the head — we'll get to it on next dismiss.
                pendingAlerts.insert(next, at: 0)
                return
            }
            alertTitle = next.title
            alertMessage = next.message
            isAlertPresented = true
        }
    }

    /// Drops dedup keys older than the dedup window. Called every time
    /// we record a new key, so the dictionary stays bounded by the
    /// number of unique alerts within `alertDedupWindow` seconds.
    private func prunePastAlertKeys(now: Date) {
        let cutoff = now.addingTimeInterval(-alertDedupWindow)
        recentAlertKeys = recentAlertKeys.filter { $0.value >= cutoff }
    }
    
    private func validate(_ t: TunnelConfiguration) -> [String] {
        var i: [String] = []
        if t.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { i.append("name") }
        if t.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { i.append("URL") }
        if containsControlCharacters(t.title) { i.append("name contains unsupported characters") }
        if containsControlCharacters(t.endpointURL) { i.append("URL contains unsupported characters") }
        if t.authMethod == .certificate {
            if t.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { i.append("cert") }
            if containsControlCharacters(t.serialNumber) { i.append("cert contains unsupported characters") }
            if containsControlCharacters(t.pinCode) { i.append("PIN contains unsupported characters") }
        } else {
            if t.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { i.append("user") }
            if containsControlCharacters(t.username) { i.append("user contains unsupported characters") }
            if containsControlCharacters(t.password) { i.append("pass contains unsupported characters") }
        }
        return i
    }

    private func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    
    private func handleExit(_ id: UUID, code: Int32) {
        guard deletingTunnelIDs.contains(id) == false else { return }
        if disconnectRequested.remove(id) != nil {
            appendSystemLog("Stopped", to: id)
            transitionState(id: id, newState: .stopped)
            return
        }

        // The ngate process is gone — there is no longer anything to reconnect.
        // isNgateReconnecting is set to true when ngate logs a retryable error
        // and starts its own internal reconnect loop. If the process then exits
        // before reaching "vpn online", the flag is left true. Without this
        // clear the watchdog guard (isNgateReconnecting == false) blocks every
        // subsequent restart attempt, making auto-reconnect effectively dead.
        runtime[id]?.isNgateReconnecting = false

        let exitError = runtime[id]?.lastError ?? .processExited
        let errorMsg = exitError == .processExited ? "Connection failed with exit code: \(code)" : exitError.message
        appendSystemLog(errorMsg, to: id, level: .error)

        transitionState(id: id, newState: .failed, errorMessage: errorMsg, tunnelError: exitError)

        // Показываем алерт только для нефиксируемых ошибок.
        // Если applyConnectionError уже выставил lastError — алерт уже был показан
        // из потока вывода, повторно не показываем.
        let alreadyAlerted = exitError != .processExited
        if !exitError.isRetryable && !alreadyAlerted {
            showAlert(title: "Connection Error", message: errorMsg, for: id)
        }
    }
    
    private func handleProcessStateChange(_ id: UUID, state: TunnelState) {
        guard deletingTunnelIDs.contains(id) == false else { return }
        switch state {
        case .starting:
            transitionState(id: id, newState: .starting)
        case .running:
            if runtime[id]?.hasEstablishedConnection == true {
                transitionState(id: id, newState: .running)
            }
        case .degraded:
            transitionState(id: id, newState: .degraded)
        case .stopping:
            transitionState(id: id, newState: .stopping)
        case .stopped:
            if disconnectRequested.contains(id) {
                transitionState(id: id, newState: .stopped)
            }
        case .failed:
            transitionState(id: id, newState: .failed)
        }
    }

    private func updateState(id: UUID, newState: TunnelState) -> Bool {
        guard var r = runtime[id] else { return false }
        guard r.status != newState else { return false }
        r.status = newState
        r.lastStateChange = Date()
        if newState == .stopped || newState == .failed {
            r.launchedAt = nil
            if newState == .stopped {
                r.hasEstablishedConnection = false
                r.isNgateReconnecting = false
            }
        }
        // launchedAt is preserved on .starting, .running, .degraded, .stopping
        // so uptime and watchdog timeout calculations stay accurate.
        runtime[id] = r
        updateTrayIcon()
        return true
    }

    private func transitionState(id: UUID, newState: TunnelState, errorMessage: String? = nil, tunnelError: TunnelError? = nil) {
        guard var r = runtime[id] else { return }
        r.errorMessage = errorMessage
        if let tunnelError {
            r.lastError = tunnelError
        } else if newState == .running || newState == .stopped {
            r.lastError = nil
        }
        runtime[id] = r
        let stateChanged = updateState(id: id, newState: newState)

        // DNS cleanup — remove this tunnel's contribution from the policy
        // when it stops or fails. The controller will recompute the policy
        // and DNSApplier will push the update to NEDNSSettingsManager.
        if newState == .stopped || newState == .failed {
            dnsParsers[id]?.reset()
            dnsParsers.removeValue(forKey: id)
            dnsPolicy.remove(tunnelID: id)
        }

        // When a tunnel *actually* transitions into .running, force a re-apply
        // of the current DNS policy. This covers the case where the tunnel
        // process survived a long sleep/wake cycle but macOS deleted the
        // /etc/resolver/ files; without this, the policy-subscription fires only
        // on changes and the missing files are never recreated.
        // Guard on stateChanged: ngate can emit "vpn online" multiple times
        // (internal reconnects), so transitionState(.running) may be called
        // while status is already .running — reapply must not fire then or
        // every such line would produce a spurious "policy applied" log entry.
        if newState == .running && stateChanged {
            dnsApplier.reapplyCurrentPolicy()
        }
    }

    /// Per-tunnel DNS parser. Feeds raw log lines through the parser and
    /// upserts any extracted DNS config into the global policy controller.
    private func feedDNSParser(pieces: [String], tunnelID: UUID) {
        // Lazily create one parser per tunnel.
        let parser = dnsParsers[tunnelID] ?? NgateGatewayResponseParser()
        if dnsParsers[tunnelID] == nil {
            dnsParsers[tunnelID] = parser
        }

        for piece in pieces {
            let wasCapturing = parser.capturing
            let extracted = parser.feed(piece)
            let isCapturing = parser.capturing

            // Diagnostic: log the moment the JSON block is first detected.
            if !wasCapturing && isCapturing {
                appendSystemLog("DNS: JSON block detected, reading…", to: tunnelID)
            }

            // Diagnostic: parse was triggered (capturing ended) but produced nothing.
            if wasCapturing && !isCapturing && extracted.isEmpty {
                let reason = parser.parseFailureReason
                let suffix = reason.isEmpty ? "" : " — \(reason)"
                appendSystemLog("DNS: JSON block parsed but no tunnel data found\(suffix)", to: tunnelID, level: .warning)
            }

            guard !extracted.isEmpty else { continue }

            // Gateway can return multiple IPTunnel entries in one JSON block.
            // Calling upsert() per-entry would overwrite the previous call for
            // the same tunnelID: if the last entry has empty SearchDomains the
            // split-DNS domains collected from earlier entries are lost, and if
            // it has empty DNSs the whole config is silently removed via
            // TunnelDNSConfig.isValid. Aggregate all entries into one upsert.
            let allServers = Array(Set(extracted.flatMap { $0.dnsServers }))
            let allDomains = Array(Set(extracted.flatMap { $0.searchDomains }))

            let srvStr = allServers.isEmpty ? "none" : allServers.joined(separator: ", ")
            let domStr = allDomains.isEmpty ? "none" : allDomains.joined(separator: ", ")
            appendSystemLog("DNS parsed from gateway — servers: \(srvStr); domains: \(domStr)", to: tunnelID)

            if allServers.isEmpty {
                appendSystemLog("DNS: no DNS servers in gateway response — split-DNS requires nameserver addresses; check gateway configuration", to: tunnelID, level: .warning)
            }

            dnsPolicy.upsert(
                tunnelID: tunnelID,
                dnsServers: allServers,
                matchDomains: allDomains
            )
        }
    }

    /// Application-level log (e.g. watchdog actions, error explanations,
    /// "Stopped" / "Disconnect requested" announcements). These lines get a
    /// Application-level log entry related to a specific tunnel. Format:
    ///     [SYSTEM] [TunnelName] message
    /// "[SYSTEM]" comes first because the Journal filters on it; the tunnel
    /// name lets the user know which profile the event belongs to.
    private func appendSystemLog(_ line: String, to id: UUID, level: SystemLogLevel = .info) {
        let title = tunnelTitle(for: id)
        let ts = Self.logTimestampFormatter.string(from: Date())
        // Format: "30.05.2026 11:08:52.123 [SYSTEM] Info    \t[profile] message"
        // Level word is padded to the width of the longest level ("Critical" = 8
        // chars) so all messages align in the same column in the monospaced journal.
        let levelField = level.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
        appendLog("\(ts) [SYSTEM] \(levelField)  [\(title)] " + line, to: id)
    }

    /// Application-level log entry NOT tied to a specific tunnel (e.g. DNS
    /// Helper status, app-wide diagnostics). Kept in a dedicated app-wide
    /// buffer so the Journal can show it once instead of duplicating it for
    /// every profile.
    private func appendBulkSystemLog(_ line: String, level: SystemLogLevel = .info) {
        let ts = Self.logTimestampFormatter.string(from: Date())
        let levelField = level.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
        let formattedLine = "\(ts) [SYSTEM] \(levelField)  " + line
        systemLogLines.append(formattedLine)
        Self.trimLogBuffer(&systemLogLines, target: maxSystemLogLines, slack: logTrimSlack)
        NSLog("%@", formattedLine)
    }

    private func appendLog(_ line: String, to id: UUID) {
        guard deletingTunnelIDs.contains(id) == false else { return }
        guard runtime[id] != nil else { return }

        // Process output can arrive as a multi-line chunk, especially with
        // -vvvv verbosity. Split on newlines and append each line separately
        // so every entry is correctly attributed to this tunnel.
        let pieces = line
            .split(whereSeparator: { $0.isNewline })
            .map { String($0) }

        let now = Date()
        let ts = Self.tf.string(from: now)
        let datePrefix = Self.datePrefixFormatter.string(from: now)

        // Feed each raw line into this tunnel's DNS parser. Lines that
        // contain the gateway's JSON response with "IPTunnels" / "DNSs" /
        // "SearchDomains" produce extracted configs which we hand to the
        // policy controller.
        // Guard: appendSystemLog also calls appendLog (to write [SYSTEM] entries
        // to the same journal). Without this guard those lines would re-enter
        // feedDNSParser while capturing==true and corrupt the JSON buffer.
        if !line.contains("[SYSTEM]") {
            feedDNSParser(pieces: pieces, tunnelID: id)
        }

        for piece in pieces {
            let t = piece.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, var r = runtime[id] else { continue }

            // Two parallel formats:
            //
            //   * **In-memory** (`formattedLine`) — what the Journal UI
            //     shows. Carries the full date so cross-midnight sorting
            //     stays chronological in the unified multi-tunnel view.
            //
            //   * **On-disk** (`diskLine`) — what FileLogger archives.
            //     Carries "yyyy-MM-dd " in front so log files retain
            //     the full timestamp and remain useful after they roll
            //     over a day boundary or get archived.
            //
            // The three branches mirror appendLog's normalization
            // logic above.
            let formattedLine: String
            if let stripped = Self.stripNgateDatePrefix(from: t) {
                formattedLine = "\(datePrefix) \(stripped)"
            } else if Self.lineCarriesFullTimestamp(t) {
                formattedLine = t
            } else if Self.lineCarriesOwnTimestamp(t) {
                formattedLine = "\(datePrefix) \(t)"
            } else {
                formattedLine = "\(datePrefix) \(ts) \(t)"
            }
            r.logLines.append(formattedLine)
            Self.trimLogBuffer(&r.logLines, target: maxLogLinesPerTunnel, slack: logTrimSlack)
            runtime[id] = r
            logger(for: id).append(line: formattedLine)

            let normalized = t.lowercased()
            if let clientAddress = NgateOutputParser.extractClientAddress(from: t) {
                runtime[id]?.clientAddress = clientAddress
            }

            if normalized.contains("vpn online") {
                runtime[id]?.hasEstablishedConnection = true
                runtime[id]?.isNgateReconnecting = false
                // Successful connection — reset auto-restart accounting.
                // If the tunnel later drops with a retryable error, the
                // watchdog starts the backoff sequence over from the base
                // delay rather than resuming wherever we left off.
                runtime[id]?.consecutiveWatchdogFailures = 0
                runtime[id]?.watchdogPaused = false
                transitionState(id: id, newState: .running)
                continue
            }

            if NgateOutputParser.indicatesNgateReconnect(from: normalized) {
                runtime[id]?.isNgateReconnecting = true
                continue
            }

            guard let classifiedError = NgateOutputParser.classifyError(from: normalized) else { continue }
            let isRuntimeIssue = runtime[id]?.hasEstablishedConnection == true

            if isRuntimeIssue && classifiedError.isRetryable {
                runtime[id]?.isNgateReconnecting = true
                transitionState(id: id, newState: .degraded, errorMessage: classifiedError.message, tunnelError: classifiedError)
                continue
            }

            if isRuntimeIssue {
                continue
            }

            applyConnectionError(classifiedError, to: id)
        }
    }
    
    
    private func updateTrayIcon() {
        let connectedCount = runtime.values.filter {
            $0.status == .running || $0.status == .degraded
        }.count
        statusIconManager?.updateIcon(connectedCount: connectedCount, totalTunnels: runtime.count)
    }

    private func canStartTunnel(_ id: UUID) -> Bool {
        guard let status = runtime[id]?.status else { return false }
        guard deletingTunnelIDs.contains(id) == false else { return false }
        // Parallel startup is allowed — no serialization between profiles.
        switch status {
        case .stopped, .failed:
            return true
        case .starting, .running, .degraded, .stopping:
            appendSystemLog("Start ignored: tunnel is \(status.title.lowercased())", to: id)
            return false
        }
    }

    private func canStopTunnel(_ id: UUID) -> Bool {
        guard let status = runtime[id]?.status else { return false }
        guard deletingTunnelIDs.contains(id) == false else { return false }
        if let processState = processManager.state(for: id), processState == .stopping {
            appendSystemLog("Stop ignored: tunnel is already \(processState.title.lowercased())", to: id)
            return false
        }
        switch status {
        case .starting, .running, .degraded, .failed:
            return true
        case .stopping, .stopped:
            appendSystemLog("Stop ignored: tunnel is already \(status.title.lowercased())", to: id)
            return false
        }
    }

    private func runConnectAllSequence(_ tunnelIDs: [UUID]) async {
        defer {
            activeStartupTunnelIDs.removeAll()
            connectAllTask = nil
        }

        // Launch every tunnel in parallel — they don't need to wait for
        // each other. Each task drives its own connect+wait flow and
        // reports whether it succeeded.
        let results: [(title: String, ok: Bool)] = await withTaskGroup(
            of: (String, Bool).self
        ) { group in
            for tunnelID in tunnelIDs {
                guard tunnels.contains(where: { $0.id == tunnelID }) else { continue }
                let title = tunnelTitle(for: tunnelID)
                group.addTask { [weak self] in
                    guard let self else { return (title, false) }
                    let state = await self.connectAndWait(tunnelID)
                    switch state {
                    case .running, .degraded:
                        return (title, true)
                    case .stopped, .starting, .stopping, .failed:
                        return (title, false)
                    }
                }
            }

            var collected: [(String, Bool)] = []
            for await result in group {
                if Task.isCancelled { break }
                collected.append(result)
            }
            return collected
        }

        if Task.isCancelled { return }

        var succeeded = 0
        var failed: [String] = []
        for r in results { if r.ok { succeeded += 1 } else { failed.append(r.title) } }

        if failed.isEmpty {
            appendBulkSystemLog("Connect All finished — \(succeeded) tunnel\(succeeded == 1 ? "" : "s") connected")
        } else {
            appendBulkSystemLog("Connect All finished — \(succeeded) connected, \(failed.count) failed: \(failed.joined(separator: ", "))", level: .warning)
        }
    }

    func connectAndWait(_ tunnelID: UUID, timeout: TimeInterval? = nil) async -> TunnelState {
        let startupTimeout = timeout ?? connectAllTimeout
        activeStartupTunnelIDs.insert(tunnelID)
        var attempts = 0
        defer {
            activeStartupTunnelIDs.remove(tunnelID)
        }

        let deadline = Date().addingTimeInterval(startupTimeout)
        outerLoop: while Date() < deadline {
            attempts += 1
            connectTunnel(tunnelID)
            guard runtime[tunnelID] != nil else { return .failed }

            while Date() < deadline {
                if Task.isCancelled {
                    appendSystemLog("Startup cancelled", to: tunnelID)
                    return .failed
                }

                let status = runtime[tunnelID]?.status ?? .stopped
                switch status {
                case .running:
                    return .running
                case .failed:
                    let lastError = runtime[tunnelID]?.lastError
                    let canRetry = (lastError?.isRetryable ?? false) && attempts <= startupRetryLimit
                    if canRetry {
                        appendSystemLog("Retrying after \(lastError?.message ?? "retryable error")", to: tunnelID, level: .warning)
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        continue outerLoop
                    }
                    return .failed
                case .degraded:
                    return .degraded
                case .stopped:
                    if processManager.state(for: tunnelID) == nil {
                        let lastError = runtime[tunnelID]?.lastError
                        let canRetry = (lastError?.isRetryable ?? false) && attempts <= startupRetryLimit
                        if canRetry {
                            appendSystemLog("Retrying after \(lastError?.message ?? "retryable error")", to: tunnelID, level: .warning)
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            continue outerLoop
                        }
                        return .failed
                    }
                case .starting, .stopping:
                    break
                }

                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        let timeoutError = TunnelError.startupTimeout
        appendSystemLog(timeoutError.message + " after \(Int(startupTimeout)) seconds", to: tunnelID, level: .error)
        transitionState(id: tunnelID, newState: .failed, errorMessage: timeoutError.message, tunnelError: timeoutError)
        processManager.forceKill(tunnelID: tunnelID)
        return .failed
    }

    private func applyConnectionError(_ error: TunnelError, to id: UUID, alertMessage: String? = nil) {
        let message = alertMessage ?? error.message

        // Dedupe: if this tunnel already has an active error of the same kind,
        // don't fire a second alert. The ngate client often emits the same
        // failure across two log lines (e.g. "no certificates acquired" and
        // "certificate not found" arrive in quick succession).
        let alreadyFailedWithSameError = runtime[id]?.lastError == error
            && runtime[id]?.status == .failed
        if alreadyFailedWithSameError {
            return
        }

        runtime[id]?.isNgateReconnecting = false
        transitionState(id: id, newState: .failed, errorMessage: message, tunnelError: error)
        if !error.isRetryable {
            showAlert(title: "Connection Error", message: message, for: id)
        }
        processManager.terminate(tunnelID: id)
    }

    private func cancelConnectAllSequence() {
        connectAllTask?.cancel()
        connectAllTask = nil
        activeStartupTunnelIDs.removeAll()
    }

    private func observeSystemWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemWake()
            }
        }
    }

    @MainActor
    private func handleSystemWake() {
        // After sleep/wake, ngate processes may have exited or be stuck in
        // an internal retry loop that won't succeed (gateway may have dropped
        // the session). Clear stale isNgateReconnecting flags for any tunnel
        // whose process is already gone, then run an immediate watchdog pass
        // rather than waiting up to watchdogInterval seconds for the timer.
        for tunnel in tunnels {
            if processManager.state(for: tunnel.id) == nil {
                runtime[tunnel.id]?.isNgateReconnecting = false
            }
        }
        appendBulkSystemLog("System woke from sleep — running watchdog pass")
        Task { [weak self] in
            await self?.runWatchdogPass()
        }
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        guard tunnels.isEmpty == false else {
            watchdogTask = nil
            return
        }
        watchdogTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                if self.tunnels.isEmpty {
                    self.watchdogTask = nil
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(watchdogInterval * 1_000_000_000))
                await self.runWatchdogPass()
            }
        }
    }

    private func runWatchdogPass() async {
        let now = Date()
        let tunnelIDs = tunnels.map(\.id)
        for tunnelID in tunnelIDs {
            guard tunnels.contains(where: { $0.id == tunnelID }) else { continue }
            guard deletingTunnelIDs.contains(tunnelID) == false else { continue }
            guard let runtimeState = runtime[tunnelID] else {
                // runtime entry missing for a known tunnel — transient inconsistency
                // during deletion; skip this tunnel, keep watching the others.
                continue
            }
            let processState = processManager.state(for: tunnelID)

            if runtimeState.status == .starting {
                guard runtimeState.isNgateReconnecting == false else { continue }
                let startedAt = runtimeState.lastStateChange ?? runtimeState.launchedAt ?? now
                if now.timeIntervalSince(startedAt) >= connectAllTimeout {
                    appendSystemLog("Watchdog detected connection timeout after \(Int(connectAllTimeout)) seconds", to: tunnelID, level: .warning)
                    transitionState(id: tunnelID, newState: .failed, errorMessage: TunnelError.startupTimeout.message, tunnelError: .startupTimeout)
                    processManager.forceKill(tunnelID: tunnelID)
                }
                continue
            }

            if processState == nil {
                // Process is gone. isNgateReconnecting may still be true if
                // the process exited before handleExit had a chance to run
                // (race: both are @MainActor tasks queued from different threads).
                // A dead process cannot be reconnecting — clear the flag here so
                // restartIfNeededAfterProcessExit always sees a consistent state.
                if runtime[tunnelID]?.isNgateReconnecting == true {
                    runtime[tunnelID]?.isNgateReconnecting = false
                }
                guard let freshState = runtime[tunnelID] else { continue }
                await restartIfNeededAfterProcessExit(for: tunnelID, runtimeState: freshState, now: now)
                continue
            }
        }
    }

    private func restartIfNeededAfterProcessExit(for id: UUID, runtimeState: TunnelRuntimeState, now: Date) async {
        guard deletingTunnelIDs.contains(id) == false else { return }
        guard disconnectRequested.contains(id) == false else { return }
        // isNgateReconnecting is NOT checked here: this function is only ever
        // called when processState == nil (process confirmed dead), and a dead
        // process cannot be reconnecting. runWatchdogPass clears the flag before
        // calling us precisely to avoid a stale-flag false-negative.
        guard activeStartupTunnelIDs.contains(id) == false else { return }
        guard watchdogRestartingTunnels.contains(id) == false else { return }

        // .stopped means the user manually disconnected (handleExit transitions
        // to .stopped only when disconnectRequested was set). Never reconnect.
        guard runtimeState.status != .stopped else { return }

        let autoReconnect = tunnels.first(where: { $0.id == id })?.autoReconnect == true

        if autoReconnect {
            // With autoreconnect, reconnect for any exit except config errors
            // that can't succeed regardless of network (wrong credentials, cert
            // not found, mismatched hostname). Retrying those would just loop
            // forever — the user must fix the config first.
            let isConfigError: Bool
            switch runtimeState.lastError {
            case .invalidCredentials, .certificateNotFound, .invalidCertificateHash,
                 .serverCertificateNameMismatch, .invalidEndpoint:
                isConfigError = true
            default:
                isConfigError = false
            }
            guard !isConfigError else { return }
        } else {
            // Default behaviour: only reconnect for errors ngate itself
            // classified as retryable, and honour the circuit breaker.
            guard runtimeState.lastError?.isRetryable == true else { return }
            guard runtimeState.status == .failed else { return }
            guard runtimeState.watchdogPaused == false else { return }
        }

        // Exponential backoff — keeps behaviour identical whether autoreconnect
        // is on or off. Goes 5s → 10s → 20s → … capped at watchdogMaxBackoff.
        let failures = runtimeState.consecutiveWatchdogFailures
        let backoff = computeBackoffDelay(failures: failures)
        if let lastRestartAt = runtimeState.lastWatchdogRestartAt,
           now.timeIntervalSince(lastRestartAt) < backoff {
            return
        }

        let nextFailureCount = failures + 1

        if !autoReconnect && nextFailureCount > watchdogMaxConsecutiveFailures {
            // Circuit breaker: give up after too many failures without autoreconnect.
            // Surface a note and stop until user acts.
            runtime[id]?.watchdogPaused = true
            appendSystemLog(
                "Watchdog: auto-reconnect paused after \(failures) failed attempts. Toggle the tunnel to retry.",
                to: id,
                level: .warning
            )
            return
        }

        watchdogRestartingTunnels.insert(id)
        runtime[id]?.lastWatchdogRestartAt = now
        runtime[id]?.consecutiveWatchdogFailures = nextFailureCount

        let waited = Int(backoff)
        if failures == 0 {
            appendSystemLog("Watchdog restarting tunnel after unexpected exit", to: id)
        } else {
            let limitNote = autoReconnect ? "" : "/\(watchdogMaxConsecutiveFailures)"
            appendSystemLog(
                "Watchdog restarting tunnel (attempt \(nextFailureCount)\(limitNote), waited \(waited)s)",
                to: id
            )
        }

        defer {
            watchdogRestartingTunnels.remove(id)
        }

        guard processManager.state(for: id) == nil else { return }
        guard runtime[id]?.isNgateReconnecting == false else { return }
        connectTunnel(id)
    }

    /// Returns the minimum wait time between the previous restart attempt
    /// and the next one, given how many failures have already happened.
    /// Failures = 0 means "this is the first restart" — we still wait the
    /// base backoff so we don't restart in the same tick where the process
    /// died.
    private func computeBackoffDelay(failures: Int) -> TimeInterval {
        let exponent = max(0, failures)
        // 5 * 2^n is fine for any reasonable n; cap before pow blows up.
        let raw = watchdogBaseBackoff * pow(2.0, Double(min(exponent, 16)))
        return min(raw, watchdogMaxBackoff)
    }

    private func saveSecretsIfNeeded(from configuration: TunnelConfiguration) {
        switch configuration.authMethod {
        case .certificate:
            do {
                try keychain.deleteSecret(account: passwordAccount(for: configuration.id))
            } catch {
                appendSystemLog("Failed to clear credentials from Keychain.", to: configuration.id, level: .warning)
            }
            if !configuration.pinCode.isEmpty {
                do {
                    try keychain.saveSecret(account: pinAccount(for: configuration.id), value: configuration.pinCode)
                } catch {
                    appendSystemLog("Failed to save credentials to Keychain.", to: configuration.id, level: .warning)
                }
            }
        case .credentials:
            do {
                try keychain.deleteSecret(account: pinAccount(for: configuration.id))
            } catch {
                appendSystemLog("Failed to clear credentials from Keychain.", to: configuration.id, level: .warning)
            }
            if !configuration.password.isEmpty {
                do {
                    try keychain.saveSecret(account: passwordAccount(for: configuration.id), value: configuration.password)
                } catch {
                    appendSystemLog("Failed to save credentials to Keychain.", to: configuration.id, level: .warning)
                }
            }
        }
    }

    private func deleteStoredSecrets(for tunnelID: UUID) {
        do {
            try keychain.deleteSecret(account: passwordAccount(for: tunnelID))
            try keychain.deleteSecret(account: pinAccount(for: tunnelID))
        } catch {
            appendSystemLog("Failed to delete credentials from Keychain.", to: tunnelID, level: .warning)
        }
    }

    private func resolvedConfigurationForStart(tunnelID: UUID, from configuration: TunnelConfiguration) -> TunnelConfiguration? {
        var resolved = Self.sanitizedConfiguration(configuration)
        do {
            switch resolved.authMethod {
            case .certificate:
                guard let pin = try keychain.getSecret(account: pinAccount(for: tunnelID)), !pin.isEmpty else {
                    let message = "PIN not found in Keychain. Open the profile and save your PIN first."
                    appendSystemLog(message, to: tunnelID, level: .error)
                    transitionState(id: tunnelID, newState: .failed, errorMessage: message, tunnelError: .launchFailed)
                    showAlert(title: "PIN Required", message: message, for: tunnelID)
                    return nil
                }
                resolved.pinCode = pin
            case .credentials:
                guard let password = try keychain.getSecret(account: passwordAccount(for: tunnelID)), !password.isEmpty else {
                    let message = "Password not found in Keychain. Open the profile and save your password first."
                    appendSystemLog(message, to: tunnelID, level: .error)
                    transitionState(id: tunnelID, newState: .failed, errorMessage: message, tunnelError: .launchFailed)
                    showAlert(title: "Password Required", message: message, for: tunnelID)
                    return nil
                }
                resolved.password = password
            }
        } catch {
            let message = "Failed to load credentials."
            appendSystemLog(message, to: tunnelID, level: .error)
            transitionState(id: tunnelID, newState: .failed, errorMessage: message, tunnelError: .launchFailed)
            showAlert(title: "Keychain Error", message: message, for: tunnelID)
            return nil
        }
        return resolved
    }

    private static func sanitizedConfiguration(_ configuration: TunnelConfiguration) -> TunnelConfiguration {
        var sanitized = configuration
        sanitized.pinCode = ""
        sanitized.password = ""
        return sanitized
    }

    private func migratePersistedSecretsToKeychainIfNeeded() {
        tunnels = tunnels.map { configuration in
            if !configuration.pinCode.isEmpty || !configuration.password.isEmpty {
                saveSecretsIfNeeded(from: configuration)
            }
            return Self.sanitizedConfiguration(configuration)
        }
    }

    private func passwordAccount(for tunnelID: UUID) -> String {
        "\(tunnelID.uuidString)_password"
    }

    private func pinAccount(for tunnelID: UUID) -> String {
        "\(tunnelID.uuidString)_pin"
    }

    private func logger(for tunnelID: UUID) -> FileLogger {
        if let existing = fileLoggers[tunnelID] {
            return existing
        }
        let created = FileLogger(tunnelID: tunnelID)
        fileLoggers[tunnelID] = created
        return created
    }

    private func removeTunnelAtomically(_ id: UUID) async {
        guard tunnels.contains(where: { $0.id == id }) else { return }

        if activeStartupTunnelIDs.contains(id) {
            cancelConnectAllSequence()
        }

        watchdogTask?.cancel()
        watchdogTask = nil
        deletingTunnelIDs.insert(id)
        watchdogRestartingTunnels.remove(id)
        disconnectRequested.insert(id)

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

    private func tunnelTitle(for id: UUID) -> String {
        tunnels.first(where: { $0.id == id })?.title ?? "Tunnel"
    }

    private static let tf: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    private static let logTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy HH:mm:ss.SSS"
        return f
    }()

    /// Date prefix used only for on-disk log files. The in-memory
    /// journal shows just the time of day for compactness; on disk
    /// we keep the full ISO date so log archives are still useful
    /// after they roll over a day boundary.
    private static let datePrefixFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    /// If `line` starts with ngate's full `<MonthAbbrev> <D> ` prefix
    /// (e.g. "May 7 00:42:00.722 Debug …"), returns the line with that
    /// prefix removed (e.g. "00:42:00.722 Debug …"). Returns nil if
    /// the line doesn't match — caller falls through to other paths.
    ///
    /// Why we strip rather than leave alone: keeping `May 7 ` in the
    /// in-memory journal duplicates information already encoded in
    /// the on-disk log filename, and makes the journal noisier than
    /// our own system entries. The full date is preserved on disk via
    /// `FileLogger`; the live view only needs wall-clock time.
    private static func stripNgateDatePrefix(from line: String) -> String? {
        let scalars = Array(line.unicodeScalars)
        guard scalars.count >= 16 else { return nil }
        let monthAbbrevs = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let firstThree = String(scalars[0..<3].map(Character.init))
        guard monthAbbrevs.contains(firstThree),
              scalars[3] == " " else { return nil }
        // Skip 1-2 day digits.
        var idx = 4
        while idx < scalars.count, scalars[idx].properties.numericType != nil {
            idx += 1
        }
        guard idx < scalars.count, scalars[idx] == " " else { return nil }
        idx += 1
        // Sanity-check the HH:mm:ss shape we expect right after.
        guard idx + 8 <= scalars.count,
              scalars[idx + 2] == ":",
              scalars[idx + 5] == ":" else { return nil }
        return String(scalars[idx...].map(Character.init))
    }

    /// True if `line` begins with bare `HH:mm:ss`, the timestamp shape ngate
    /// may emit after we strip its month/day prefix.
    private static func lineCarriesOwnTimestamp(_ line: String) -> Bool {
        let scalars = Array(line.unicodeScalars)
        guard scalars.count >= 8 else { return false }
        return scalars[2] == ":" && scalars[5] == ":"
    }

    /// True if `line` begins with `dd.MM.yyyy HH:mm:ss`.
    private static func lineCarriesFullTimestamp(_ line: String) -> Bool {
        let scalars = Array(line.unicodeScalars)
        guard scalars.count >= 19 else { return false }
        return scalars[2] == "."
            && scalars[5] == "."
            && scalars[10] == " "
            && scalars[13] == ":"
            && scalars[16] == ":"
    }

    /// Drops the oldest entries from a log buffer once it overshoots its
    /// allowed `target` size by more than `slack`. Inout so we modify the
    /// caller's array in place without copy-on-write churn from
    /// re-assigning a struct field round-trip.
    ///
    /// Why we don't trim every overflow: `Array.removeFirst(_:)` is
    /// O(N) — it has to slide the rest of the buffer left. By tolerating
    /// `slack` extra entries between trims we amortise that cost across
    /// many appends, so the per-append work stays roughly constant.
    private static func trimLogBuffer(_ buffer: inout [String], target: Int, slack: Int) {
        let currentCount = buffer.count
        guard currentCount > target + slack else { return }
        buffer.removeFirst(currentCount - target)
    }
}
