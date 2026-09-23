import Foundation
import SwiftUI
import Combine
import CryptoKit

// Connecting, disconnecting, state transitions and Connect All.
// Split out of AppState.swift; members are internal (not private) so the
// extensions in the sibling files can share state.
extension AppState {
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
        runtime[id]?.firstOutputAt = nil
        runtime[id]?.lastLoginTransactionSeconds = nil
        transitionState(id: id, newState: .starting)
        runProxyPreflight(for: id, endpoint: configuration.endpointURL)
        let onOutput: @Sendable (String) -> Void = { [weak self] t in Task { @MainActor in self?.appendLog(t, to: id) } }
        let onStateChange: @Sendable (TunnelState) -> Void = { [weak self] state in Task { @MainActor in self?.handleProcessStateChange(id, state: state) } }
        let onExit: @Sendable (Int32) -> Void = { [weak self] c in Task { @MainActor in self?.handleExit(id, code: c) } }

        warmAdoptedAt.removeValue(forKey: id)
        switch processManager.adoptWarm(tunnelID: id, signature: Self.warmSignature(of: configuration),
                                        onOutput: onOutput, onStateChange: onStateChange, onExit: onExit) {
        case .adopted:
            runtime[id]?.launchedAt = Date()
            warmAdoptedAt[id] = Date()
            appendSystemLog("Using pre-warmed client", to: id)
            return
        case .stale:
            appendSystemLog("Pre-warmed client was built from older settings — starting a fresh one", to: id)
        case .unavailable:
            break
        }

        do {
            try processManager.launch(tunnelID: id, binaryPath: url.path, configuration: configuration,
                onOutput: onOutput, onStateChange: onStateChange, onExit: onExit)
            runtime[id]?.launchedAt = Date()
        } catch {
            let launchError = TunnelError.launchFailed
            let errorMsg = "Failed to start: \(error.localizedDescription)"
            appendSystemLog(errorMsg, to: id, level: .error)
            applyConnectionError(launchError, to: id, alertMessage: errorMsg)
        }
    }
    
    /// Background check of the system proxy on the path to this tunnel's
    /// gateway. Never blocks or fails the connect — the client may still
    /// succeed — it only puts the likely culprit in the journal.
    func runProxyPreflight(for id: UUID, endpoint: String) {
        guard let url = URL(string: endpoint), let host = url.host,
              let proxy = ProxyPreflight.proxy(for: url) else { return }
        let port = url.port ?? 443
        Task { [weak self] in
            let outcome = await ProxyPreflight.probe(proxy, targetHost: host, targetPort: port)
            guard let self, let warning = ProxyPreflight.warning(for: outcome, host: host) else { return }
            // Only while this attempt is still in progress; a late verdict for
            // a tunnel that has since connected or been stopped is noise.
            guard self.runtime[id]?.status == .starting else { return }
            self.appendSystemLog(warning, to: id, level: .warning)
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
        schedulePrewarm(only: [id], duringDisconnect: true)
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
            await self.runConnectAllStaggered(tunnelIDs)
        }
    }
    func disconnectAll() {
        cancelConnectAllSequence()
        tunnels.forEach { disconnectTunnel($0.id) }
    }

    func validate(_ t: TunnelConfiguration) -> [String] {
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

    func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    
    func handleExit(_ id: UUID, code: Int32) {
        guard deletingTunnelIDs.contains(id) == false else { return }
        if disconnectRequested.remove(id) != nil {
            warmAdoptedAt.removeValue(forKey: id)
            appendSystemLog("Stopped", to: id)
            transitionState(id: id, newState: .stopped)
            schedulePrewarm(only: [id], delay: 2)
            return
        }

        // A pre-warmed client that dies within seconds of being released —
        // typically the client's own login timer expiring because it sat at
        // the gate too long — is not a real connection failure. Start a fresh
        // client once instead of surfacing an error the user has to retry.
        if let adoptedAt = warmAdoptedAt.removeValue(forKey: id),
           Date().timeIntervalSince(adoptedAt) < 30,
           runtime[id]?.hasEstablishedConnection != true,
           runtime[id]?.lastError == nil || runtime[id]?.lastError == .startupTimeout {
            appendSystemLog("Pre-warmed client was rejected by the gateway login timer — starting a fresh one", to: id, level: .warning)
            runtime[id]?.isNgateReconnecting = false
            runtime[id]?.lastError = nil
            transitionState(id: id, newState: .stopped)
            connectTunnel(id)
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
    
    func handleProcessStateChange(_ id: UUID, state: TunnelState) {
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

    func updateState(id: UUID, newState: TunnelState) -> Bool {
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

    func transitionState(id: UUID, newState: TunnelState, errorMessage: String? = nil, tunnelError: TunnelError? = nil) {
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
        // and DNSApplier will write the matching /etc/resolver files.
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

    func canStartTunnel(_ id: UUID) -> Bool {
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

    func canStopTunnel(_ id: UUID) -> Bool {
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

    func runConnectAllStaggered(_ tunnelIDs: [UUID]) async {
        defer {
            activeStartupTunnelIDs.removeAll()
            connectAllTask = nil
        }

        // Start tunnels in parallel, staggered by a few seconds. Fully
        // sequential startup waits for each tunnel to finish (~30 s each with
        // CryptoPro cert-storage init), while a burst start makes the
        // processes contend for the CSP/token. A short stagger overlaps the
        // slow initialisation but avoids the burst. Each tunnel has its own
        // connectAndWait deadline.
        let staggerNanos: UInt64 = 3_000_000_000
        var succeeded = 0
        var failed: [String] = []

        // Pre-warmed tunnels have already done the slow token work, so they
        // start at once; only cold ones are staggered against each other.
        // Tunnels that don't touch the token (password, sandboxed) have
        // nothing to contend for and start immediately too.
        var coldCount = 0
        var entries: [(offset: Int, id: UUID, title: String)] = []
        for id in tunnelIDs {
            guard let tunnel = tunnels.first(where: { $0.id == id }) else { continue }
            if processManager.hasWarm(tunnelID: id) || !needsToken(tunnel) {
                entries.append((offset: 0, id: id, title: tunnelTitle(for: id)))
            } else {
                entries.append((offset: coldCount, id: id, title: tunnelTitle(for: id)))
                coldCount += 1
            }
        }

        await withTaskGroup(of: (String, TunnelState)?.self) { group in
            for entry in entries {
                group.addTask { [weak self] in
                    if entry.offset > 0 {
                        try? await Task.sleep(nanoseconds: staggerNanos * UInt64(entry.offset))
                    }
                    if Task.isCancelled { return nil }
                    guard let self else { return nil }
                    let state = await self.connectAndWait(entry.id)
                    return (entry.title, state)
                }
            }
            for await result in group {
                guard let (title, state) = result else { continue }
                switch state {
                case .running, .degraded:
                    succeeded += 1
                case .stopped, .starting, .stopping, .failed:
                    failed.append(title)
                }
            }
        }

        if Task.isCancelled { return }

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
                    let canRetry = WatchdogPolicy.canRetryDuringStartup(lastError: lastError, attempts: attempts, limit: startupRetryLimit)
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
                        let canRetry = WatchdogPolicy.canRetryDuringStartup(lastError: lastError, attempts: attempts, limit: startupRetryLimit)
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

    func applyConnectionError(_ error: TunnelError, to id: UUID, alertMessage: String? = nil) {
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

    func cancelConnectAllSequence() {
        connectAllTask?.cancel()
        connectAllTask = nil
        activeStartupTunnelIDs.removeAll()
    }

}
