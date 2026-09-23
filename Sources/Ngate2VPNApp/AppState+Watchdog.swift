import Foundation
import SwiftUI
import Combine
import CryptoKit

// Wake handling and the watchdog loop that restarts tunnels.
// Split out of AppState.swift; members are internal (not private) so the
// extensions in the sibling files can share state.
extension AppState {
    func observeSystemWake() {
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
    func handleSystemWake() {
        // After sleep/wake, ngate processes may have exited or be stuck in
        // an internal retry loop that won't succeed (gateway may have dropped
        // the session). Clear stale isNgateReconnecting flags for any tunnel
        // whose process is already gone, then run an immediate watchdog pass
        // rather than waiting up to watchdogInterval seconds for the timer.
        for tunnel in tunnels {
            if processManager.state(for: tunnel.id) == nil {
                runtime[tunnel.id]?.isNgateReconnecting = false
                // The network is new after a wake: a tunnel that gave up before
                // sleeping deserves a fresh retry budget. Only auto-reconnect
                // tunnels — the others were paused by their own circuit breaker
                // and the user asked for a manual retry.
                if tunnel.autoReconnect, runtime[tunnel.id]?.watchdogPaused == true,
                   runtime[tunnel.id]?.lastError != .twoFactorTimeout {
                    runtime[tunnel.id]?.watchdogPaused = false
                    runtime[tunnel.id]?.consecutiveWatchdogFailures = 0
                    runtime[tunnel.id]?.lastWatchdogRestartAt = nil
                }
            }
        }
        appendBulkSystemLog("System woke from sleep — running watchdog pass")
        // Warm clients hold token/CSP state from before the sleep; rebuild them.
        processManager.discardAllWarm()
        schedulePrewarm(delay: 8)
        Task { [weak self] in
            await self?.runWatchdogPass()
        }
    }

    func startWatchdog() {
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

    func runWatchdogPass() async {
        refreshAgedWarmClients()
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
                // Measure from first process output, not from launch. Some
                // tunnels (certificate-based) have a silent initialisation
                // window (DNS, cert loading) of 20+ seconds before they
                // print anything. Counting from launch would fire the timeout
                // before the authentication even begins.
                // Fall back to lastStateChange if no output has arrived yet
                // so completely silent/hung processes are still killed.
                if WatchdogPolicy.isStartupTimedOut(
                    now: now, firstOutputAt: runtimeState.firstOutputAt,
                    lastStateChange: runtimeState.lastStateChange,
                    launchedAt: runtimeState.launchedAt, timeout: connectAllTimeout
                ) {
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

    func restartIfNeededAfterProcessExit(for id: UUID, runtimeState: TunnelRuntimeState, now: Date) async {
        guard deletingTunnelIDs.contains(id) == false else { return }
        guard disconnectRequested.contains(id) == false else { return }
        // isNgateReconnecting is NOT checked here: this function is only ever
        // called when processState == nil (process confirmed dead), and a dead
        // process cannot be reconnecting. runWatchdogPass clears the flag before
        // calling us precisely to avoid a stale-flag false-negative.
        guard activeStartupTunnelIDs.contains(id) == false else { return }
        guard watchdogRestartingTunnels.contains(id) == false else { return }

        let autoReconnect = tunnels.first(where: { $0.id == id })?.autoReconnect == true
        let decision = WatchdogPolicy.decide(.init(
            status: runtimeState.status,
            lastError: runtimeState.lastError,
            autoReconnect: autoReconnect,
            paused: runtimeState.watchdogPaused,
            consecutiveFailures: runtimeState.consecutiveWatchdogFailures,
            lastRestartAt: runtimeState.lastWatchdogRestartAt,
            now: now
        ))

        let failures = runtimeState.consecutiveWatchdogFailures
        let nextFailureCount: Int
        let failureLimit: Int
        let backoff: TimeInterval
        switch decision {
        case .skip:
            return
        case .pause(.twoFactor, _):
            runtime[id]?.watchdogPaused = true
            appendSystemLog(
                "Two-factor confirmation was not received after \(WatchdogPolicy.twoFactorMaxRetries + 1) attempts. Toggle the tunnel to try again.",
                to: id,
                level: .warning
            )
            showAlert(title: "Two-Factor Timeout", message: TunnelError.twoFactorTimeout.message, for: id)
            return
        case .pause(.tooManyFailures, let count):
            // Circuit breaker: give up after too many failures in a row.
            // Surface a note and stop until the user acts (or the machine
            // wakes from sleep — see handleSystemWake).
            runtime[id]?.watchdogPaused = true
            appendSystemLog(
                "Watchdog: auto-reconnect paused after \(count) failed attempts. Toggle the tunnel to retry.",
                to: id,
                level: .warning
            )
            if autoReconnect {
                showAlert(
                    title: "Auto-reconnect Paused",
                    message: "The tunnel could not be re-established after \(count) attempts. Check the network or proxy, then toggle it to try again.",
                    for: id
                )
            }
            return
        case .restart(let attempt, let limit, let waited):
            nextFailureCount = attempt
            failureLimit = limit
            backoff = waited
        }

        watchdogRestartingTunnels.insert(id)
        runtime[id]?.lastWatchdogRestartAt = now
        runtime[id]?.consecutiveWatchdogFailures = nextFailureCount

        let waited = Int(backoff)
        if failures == 0 {
            appendSystemLog("Watchdog restarting tunnel after unexpected exit", to: id)
        } else {
            let limitNote = "/\(failureLimit)"
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

}
