import Foundation
import SwiftUI
import Combine
import CryptoKit

// User-facing alerts (deduplicated, queued).
// Split out of AppState.swift; members are internal (not private) so the
// extensions in the sibling files can share state.
extension AppState {
    func showAlert(title: String, message: String) {
        showAlert(title: L(title), message: L(message), dedupKey: title + "|" + message)
    }

    /// Convenience overload — prefixes the alert title with "[Profile name]"
    /// so the user immediately knows which tunnel the error belongs to when
    /// running multiple profiles. Dedup key includes the tunnel ID so the
    /// same error from two different tunnels surfaces twice (once per
    /// tunnel) instead of being deduped together.
    func showAlert(title: String, message: String, for tunnelID: UUID) {
        let profile = tunnelTitle(for: tunnelID)
        let prefixed = "[\(profile)] \(L(title))"
        showAlert(title: prefixed, message: L(message),
                  dedupKey: "\(tunnelID.uuidString)|\(title)|\(message)")
    }

    /// Internal entry point. `dedupKey` is what we hash to decide
    /// whether this is a duplicate of an alert we just showed for the
    /// same situation (e.g. ngate spamming the same log line). Window
    /// is `alertDedupWindow` seconds.
    func showAlert(title: String, message: String, dedupKey: String) {
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
    func prunePastAlertKeys(now: Date) {
        let cutoff = now.addingTimeInterval(-alertDedupWindow)
        recentAlertKeys = recentAlertKeys.filter { $0.value >= cutoff }
    }
    
}
