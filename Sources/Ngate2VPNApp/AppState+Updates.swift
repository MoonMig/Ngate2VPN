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
    /// On success this function does not return to its caller in any
    /// meaningful sense — `NSApp.terminate` tears the app down through the
    /// normal quit handshake once the new copy has launched.
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
            try await AppUpdateInstaller.installAndRelaunch(dmgPath: dmgPath)
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
