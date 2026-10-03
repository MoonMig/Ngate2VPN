import Foundation
import AppKit

// Checking GitHub Releases for a newer version — the Settings "Check for
// Updates" button and the periodic automatic check. See `AppUpdateChecker.swift`
// for why this never downloads or installs anything itself.
extension AppState {
    static let autoUpdateCheckKey = "autoUpdateCheck"
    static let lastUpdateCheckAtKey = "lastUpdateCheckAt"
    static let autoUpdateCheckIntervalSeconds: TimeInterval = 24 * 60 * 60

    /// Not cached on `AppState` — read fresh each time so toggling the
    /// Settings switch takes effect immediately, the same as other plain
    /// `UserDefaults` settings (`prewarmTunnels`, `holdDefaultDNS`, …).
    var autoUpdateCheckEnabled: Bool {
        (UserDefaults.standard.object(forKey: Self.autoUpdateCheckKey) as? Bool) ?? true
    }

    /// When any check (automatic *or* manual) last actually hit the network.
    /// Persisted so relaunching the app — including several times a day —
    /// doesn't re-hit GitHub each time; only wall-clock time since this
    /// moment counts toward the next automatic check.
    private var lastUpdateCheckDate: Date? {
        get { UserDefaults.standard.object(forKey: Self.lastUpdateCheckAtKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastUpdateCheckAtKey) }
    }

    /// Starts (or restarts) the periodic background check. Each iteration
    /// sleeps until 24 h have actually elapsed since `lastUpdateCheckDate`
    /// (computed fresh from the persisted timestamp, not a fixed delay), so
    /// restarting the app shortly after a check — automatic or manual — does
    /// not trigger another one; a 10 s floor just keeps a well-overdue check
    /// (app was quit for days) from firing the instant launch finishes.
    /// Called once from `init()` and again whenever the Settings toggle changes.
    func startAutoUpdateChecking() {
        updateCheckTask?.cancel()
        guard autoUpdateCheckEnabled else { return }
        updateCheckTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(self.lastUpdateCheckDate ?? .distantPast)
                let delay = max(10, AppState.autoUpdateCheckIntervalSeconds - elapsed)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self.checkForUpdates(manual: false)
            }
        }
    }

    /// Settings toggle changed — mirrors `prewarmSettingChanged()`.
    func autoUpdateCheckSettingChanged() {
        startAutoUpdateChecking()
    }

    /// `manual` distinguishes the Settings/menu-triggered check (failures are
    /// shown directly) from the periodic background one (a flaky network
    /// call once a day is not worth a journal line unless it actually finds
    /// something — only a found update is logged). Every check, regardless
    /// of `manual`, updates `lastUpdateCheckDate` — a manual check also
    /// pushes back the next automatic one, so the two don't fire back to back.
    func checkForUpdates(manual: Bool) async {
        updateCheckStatus = .checking
        defer { lastUpdateCheckDate = Date() }
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        do {
            let release = try await AppUpdateChecker.fetchLatestRelease()
            switch AppUpdateChecker.availability(for: release, currentVersion: currentVersion) {
            case .upToDate:
                updateCheckStatus = .upToDate(checkedAt: Date())
            case .available(let version, let releaseURL, let downloadURL):
                let wasAlreadyKnown = updateCheckStatus.availableVersion == version
                updateCheckStatus = .available(version: version, releaseURL: releaseURL, downloadURL: downloadURL)
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

    /// Tunnels that would be dropped by restarting right now — the UI uses
    /// this to ask for confirmation before `installUpdateAndRelaunch()`.
    var activeTunnelCount: Int {
        runtime.values.filter { [.starting, .running, .degraded].contains($0.status) }.count
    }

    /// Downloads the release's DMG, verifies the app inside it is signed by
    /// this same build's identity, replaces the running app with it, and
    /// relaunches — see `AppUpdateInstaller` for why each of those steps
    /// matters. Falls back to simply opening the release page if the release
    /// has no DMG asset (should not happen with this project's release
    /// workflow, but must not dead-end the button if it ever does).
    ///
    /// On success this function does not return — it exits the process
    /// itself after `performQuitCleanup()`, once the new copy has launched.
    /// A real test showed `NSApp.terminate(nil)` reaching
    /// `applicationShouldTerminate` (confirmed by its own entry log) but the
    /// cleanup `Task` spawned inside it then never getting scheduled —
    /// apparently specific to the moment a second instance of this same app
    /// has just been launched via `NSWorkspace.openApplication`. Awaiting
    /// `performQuitCleanup()` directly, in this already-running task, and
    /// calling `exit(0)` ourselves sidesteps that without skipping any
    /// cleanup: it is the exact same cleanup `applicationShouldTerminate`
    /// uses for a normal Cmd+Q, just invoked synchronously in this call
    /// chain instead of from a newly-spawned, apparently-starved `Task`.
    func installUpdateAndRelaunch() async {
        guard case .available(let version, let releaseURL, let downloadURL) = updateCheckStatus else { return }
        guard let downloadURL else {
            NSWorkspace.shared.open(releaseURL)
            return
        }
        updateCheckStatus = .downloading(version: version)
        do {
            let dmgPath = try await AppUpdateChecker.downloadAsset(
                from: downloadURL, suggestedName: downloadURL.lastPathComponent
            )
            appendBulkSystemLog("Update downloaded: \(dmgPath.lastPathComponent)")
            updateCheckStatus = .installing(version: version)
            appendBulkSystemLog("Installing update \(version) and restarting…")
            try await AppUpdateInstaller.installAndRelaunch(dmgPath: dmgPath) { [weak self] message in
                self?.appendBulkSystemLog(message)
            }
            appendBulkSystemLog("Cleaning up before exiting…")
            await performQuitCleanup()
            appendBulkSystemLog("Exiting old process")
            exit(0)
        } catch {
            let message: String
            if let checkError = error as? AppUpdateChecker.CheckError {
                message = String(describing: checkError)
            } else if let installError = error as? AppUpdateInstaller.InstallError {
                message = installError.description
            } else {
                message = error.localizedDescription
            }
            appendBulkSystemLog("Update install failed: \(message)", level: .warning)
            updateCheckStatus = .available(version: version, releaseURL: releaseURL, downloadURL: downloadURL)
            showAlert(title: "Update Failed", message: message)
        }
    }
}
