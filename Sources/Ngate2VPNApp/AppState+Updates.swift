import Foundation
import AppKit

// Checking GitHub Releases for a newer version — the Settings "Check for
// Updates" button and the periodic automatic check. See `AppUpdateChecker.swift`
// for why this never downloads or installs anything itself.
extension AppState {
    static let autoUpdateCheckKey = "autoUpdateCheck"
    static let autoUpdateCheckInterval: UInt64 = 24 * 60 * 60 * 1_000_000_000

    /// Not cached on `AppState` — read fresh each time so toggling the
    /// Settings switch takes effect immediately, the same as other plain
    /// `UserDefaults` settings (`prewarmTunnels`, `holdDefaultDNS`, …).
    var autoUpdateCheckEnabled: Bool {
        (UserDefaults.standard.object(forKey: Self.autoUpdateCheckKey) as? Bool) ?? true
    }

    /// Starts (or restarts) the periodic background check: once shortly after
    /// launch, then every 24 h. Called once from `init()` and again whenever
    /// the Settings toggle changes.
    func startAutoUpdateChecking() {
        updateCheckTask?.cancel()
        guard autoUpdateCheckEnabled else { return }
        updateCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            while let self, !Task.isCancelled {
                await self.checkForUpdates(manual: false)
                try? await Task.sleep(nanoseconds: AppState.autoUpdateCheckInterval)
            }
        }
    }

    /// Settings toggle changed — mirrors `prewarmSettingChanged()`.
    func autoUpdateCheckSettingChanged() {
        startAutoUpdateChecking()
    }

    /// `manual` distinguishes the Settings button (failures are shown in the
    /// status row) from the periodic background check (a flaky network call
    /// once a day is not worth a journal line unless it actually finds
    /// something — only a found update is logged).
    func checkForUpdates(manual: Bool) async {
        updateCheckStatus = .checking
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        do {
            let release = try await AppUpdateChecker.fetchLatestRelease()
            switch AppUpdateChecker.availability(for: release, currentVersion: currentVersion) {
            case .upToDate:
                updateCheckStatus = .upToDate(checkedAt: Date())
            case .available(let version, let url):
                let wasAlreadyKnown = updateCheckStatus == .available(version: version, url: url)
                updateCheckStatus = .available(version: version, url: url)
                if !wasAlreadyKnown {
                    appendBulkSystemLog("Update available: \(version)")
                }
            }
        } catch {
            let message = String(describing: error as? AppUpdateChecker.CheckError ?? .network(error.localizedDescription))
            updateCheckStatus = .failed(message)
            if manual {
                appendBulkSystemLog("Update check failed: \(message)", level: .warning)
            }
        }
    }

    func openLatestReleasePage() {
        guard case .available(_, let url) = updateCheckStatus else { return }
        NSWorkspace.shared.open(url)
    }
}
