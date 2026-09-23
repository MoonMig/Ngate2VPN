import Foundation
import SwiftUI
import Combine
import CryptoKit

// Pre-warming of gated ngateconsoleclient processes (see CLAUDE.md).
// Split out of AppState.swift; members are internal (not private) so the
// extensions in the sibling files can share state.
extension AppState {
    // MARK: - Pre-warming
    //
    // ngateconsoleclient spends ~12 s per process reading every token
    // container before it connects. We start clients ahead of time, held just
    // before their first network connect (see Support/ngategate.c), and on
    // Connect hand the live one to the tunnel state machine and release it.
    // Warm processes are kept in `processManager.warm`, invisible to the
    // watchdog and status logic until adopted.

    var prewarmEnabled: Bool {
        (UserDefaults.standard.object(forKey: "prewarmTunnels") as? Bool ?? true)
            && GateSupport.libraryURL != nil
    }

    func startPrewarmSupport() {
        tokenMonitor.start { [weak self] present in
            Task { @MainActor in self?.handleTokenChange(present) }
        }
    }

    /// Called from Settings when the "Pre-warm tunnels" switch flips.
    func prewarmSettingChanged() {
        if prewarmEnabled {
            schedulePrewarm()
        } else {
            processManager.discardAllWarm()
        }
    }

    func handleTokenChange(_ present: Bool) {
        let isInitial = !tokenStateKnown
        let wasPresent = tokenPresent
        tokenStateKnown = true
        tokenPresent = present

        if !isInitial && present != wasPresent {
            appendBulkSystemLog(present ? "Smartcard token detected" : "Smartcard token removed")
        }
        if !present {
            // Certificate clients that were warmed against this token are stale.
            for tunnel in tunnels where tunnel.authMethod == .certificate {
                processManager.discardWarm(tunnelID: tunnel.id)
            }
        }
        // With auto-connect the tunnels are about to be started anyway.
        if isInitial && UserDefaults.standard.bool(forKey: "autoConnect") && !tunnels.isEmpty { return }
        if isInitial || present != wasPresent {
            schedulePrewarm(delay: isInitial ? 1 : 3)
        }
    }

    /// - Parameter duringDisconnect: warm the replacement while the old
    ///   client is still shutting down after a user Disconnect, so its slow
    ///   token read overlaps the shutdown instead of following it.
    func schedulePrewarm(only ids: [UUID]? = nil, delay: TimeInterval = 0, duringDisconnect: Bool = false) {
        guard prewarmEnabled else { return }
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self else { return }
            var launchedAny = false
            for id in ids ?? self.tunnels.map(\.id) {
                guard self.shouldPrewarm(id, duringDisconnect: duringDisconnect) else { continue }
                // Stagger launches: they contend for the same token.
                if launchedAny { try? await Task.sleep(nanoseconds: 3_000_000_000) }
                if self.prewarmTunnel(id, duringDisconnect: duringDisconnect) { launchedAny = true }
            }
        }
    }

    /// Replaces warm clients that have been held too long (see
    /// `GateSupport.maxWarmAge`). Discard + relaunch happen in the same
    /// main-actor turn, so a Connect never sees a gap.
    func refreshAgedWarmClients() {
        guard prewarmEnabled else { return }
        for id in processManager.warmTunnelIDs(olderThan: GateSupport.maxWarmAge) {
            processManager.discardWarm(tunnelID: id)
            if prewarmTunnel(id) {
                appendSystemLog("Pre-warmed client refreshed (held longer than \(Int(GateSupport.maxWarmAge / 60)) min)", to: id)
            }
        }
    }

    func shouldPrewarm(_ id: UUID, duringDisconnect: Bool = false) -> Bool {
        guard prewarmEnabled, tunnelsContain(id) else { return false }
        guard deletingTunnelIDs.contains(id) == false,
              processManager.hasWarm(tunnelID: id) == false else { return false }
        if duringDisconnect {
            guard disconnectRequested.contains(id) else { return false }
        } else {
            guard disconnectRequested.contains(id) == false,
                  activeStartupTunnelIDs.contains(id) == false,
                  runtime[id]?.status == .stopped,
                  processManager.state(for: id) == nil else { return false }
        }
        guard let tunnel = tunnels.first(where: { $0.id == id }) else { return false }
        guard needsToken(tunnel) else { return false }
        if tunnel.authMethod == .certificate && !tokenPresent { return false }
        return true
    }

    /// Whether this tunnel's client spends ~12 s reading the token at start.
    /// Password tunnels run in the no-token sandbox (0.3 s init), so warming
    /// them would only keep an idle process and its credential file around.
    func needsToken(_ tunnel: TunnelConfiguration) -> Bool {
        tunnel.authMethod == .certificate || !TunnelProcess.tokenSandboxEnabled
    }

    func tunnelsContain(_ id: UUID) -> Bool {
        tunnels.contains(where: { $0.id == id })
    }

    /// Returns true if a warm client was actually started.
    @discardableResult
    func prewarmTunnel(_ id: UUID, duringDisconnect: Bool = false) -> Bool {
        guard shouldPrewarm(id, duringDisconnect: duringDisconnect), let snapshot = snapshot(for: id) else { return false }
        guard let configuration = resolvedConfigurationForStart(tunnelID: id, from: snapshot.configuration, quiet: true),
              validate(configuration).isEmpty,
              FileManager.default.isExecutableFile(atPath: binaryPath) else { return false }
        do {
            let started = try processManager.prewarm(
                tunnelID: id,
                binaryPath: binaryPath,
                configuration: configuration,
                signature: Self.warmSignature(of: configuration),
                onExit: { [weak self] code, intentional in
                    Task { @MainActor in self?.handleWarmExit(id, code: code, intentional: intentional) }
                })
            if started { appendSystemLog("Client pre-warmed — Connect will be fast", to: id) }
            return started
        } catch {
            appendSystemLog("Pre-warm failed: \(error.localizedDescription)", to: id, level: .warning)
            return false
        }
    }

    func handleWarmExit(_ id: UUID, code: Int32, intentional: Bool) {
        guard !intentional, tunnelsContain(id), deletingTunnelIDs.contains(id) == false else { return }
        appendSystemLog("Pre-warmed client exited (code \(code)); Connect will start a fresh one", to: id, level: .warning)
    }

    /// Identifies the exact settings a warm client was built from, so a
    /// stale one (profile edited, password changed) is never reused.
    static func warmSignature(of c: TunnelConfiguration) -> String {
        let material = [c.title, c.endpointURL, c.authMethod.rawValue, c.serialNumber,
                        c.pinCode, c.username, c.password].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

}
