import SwiftUI
import AppKit

// MARK: - SETTINGS

struct AppSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("autoConnect")     private var autoConnect     = false
    @AppStorage("prewarmTunnels")  private var prewarmTunnels  = true
    @AppStorage("appTheme")        private var appTheme        = "System"
    @AppStorage("showErrorAlerts") private var showErrorAlerts = true

    private var binaryOK: Bool {
        FileManager.default.isExecutableFile(atPath: appState.binaryPath)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                FormBlock("Application") {
                    FieldRow(label: "Binary") {
                        HStack(spacing: 6) {
                            TextField("/path/to/client", text: $appState.binaryPath).plain()
                            if !binaryOK {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11)).foregroundStyle(DS.orange)
                            }
                        }
                    }
                    ToggleRow(label: "Hide from Dock on close", icon: "dock.rectangle", value: $appState.hideDockOnClose)
                    ToggleRow(label: "Auto-connect on launch",  icon: "bolt.fill",       value: $autoConnect)
                    ToggleRow(label: "Pre-warm tunnels (faster connect)", icon: "flame.fill", value: $prewarmTunnels)
                        .onChange(of: prewarmTunnels) { _ in appState.prewarmSettingChanged() }
                }

                FormBlock("Notifications") {
                    ToggleRow(label: "Show error alerts",
                              icon: "exclamationmark.bubble",
                              value: $showErrorAlerts)
                }

                DNSHelperSection()
                    .environmentObject(appState)

                FormBlock("Interface") {
                    FieldRow(label: "Theme") {
                        Picker("", selection: $appTheme) {
                            Text("Dark").tag("Dark")
                            Text("Light").tag("Light")
                            Text("System").tag("System")
                        }
                        .pickerStyle(.segmented).frame(maxWidth: 180)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Active tunnels are disconnected when the app closes.")
                    Text("Secrets are stored in macOS Keychain — never logged.")
                }
                .font(.system(size: 11)).foregroundStyle(DS.ter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(18)
        }
        .background(DS.bg)
        .overlay(alignment: .top) { TitlebarBackdrop() }
    }
}

/// The window's titlebar is transparent (full-size content view), so settings
/// that scroll up slide under the tab buttons and show through behind them.
/// This paints a 30%-transparent strip a little shorter than the titlebar (the top
/// safe-area inset) over the content. Settings tab only — the other tabs are
/// intentionally left as they were.
private struct TitlebarBackdrop: View {
    /// 30% transparent = 70% opaque.
    private let opacity = 0.7
    /// How much shorter than the titlebar the strip is, in points.
    private let shrink: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            DS.bg
                .opacity(opacity)
                .frame(height: max(0, geo.safeAreaInsets.top - shrink))
                .offset(y: -geo.safeAreaInsets.top)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - DNS Helper section

/// Settings UI for the DNS Helper feature. Shows install/uninstall button
/// based on the current DNSApplier state, and a Hold Default DNS toggle
/// that's only meaningful while the helper is installed.
struct DNSHelperSection: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("holdDefaultDNS") private var holdDefaultDNS: Bool = true
    /// Bumps when DNSApplier publishes a new state — keeps the View in sync.
    @State private var stateRevision: Int = 0

    private var helperState: DNSHelperState { appState.dnsApplier.state }

    private var statusText: String {
        switch helperState {
        case .uninstalled:           return "Not installed"
        case .applying:              return "Working…"
        case .installed:             return "Active"
        case .error(let message):    return "Error: \(message)"
        }
    }

    private var statusColor: Color {
        switch helperState {
        case .uninstalled:            return DS.sec
        case .applying:               return DS.orange
        case .installed:              return DS.green
        case .error:                  return DS.red
        }
    }

    private var actionLabel: String {
        switch helperState {
        case .uninstalled, .error:   return "Install"
        case .applying:              return "Working…"
        case .installed:             return "Uninstall"
        }
    }

    private var actionIsDestructive: Bool {
        if case .installed = helperState { return true }
        return false
    }

    var body: some View {
        FormBlock("DNS Helper") {
            FieldRow(label: "Status") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(DS.sec)
                    Spacer()
                    SmallButton(actionLabel,
                                primary: true,
                                tintColor: actionIsDestructive ? DS.red : nil,
                                enabled: !isApplying) {
                        toggleHelper()
                    }
                }
            }

            // Hold Default DNS — only meaningful when helper is active
            if case .installed = helperState {
                ToggleRow(label: "Hold Default DNS",
                          icon: "lock.fill",
                          value: $holdDefaultDNS)
                    .onChange(of: holdDefaultDNS) { newValue in
                        appState.dnsPolicy.holdDefaultDNS = newValue
                    }
            }
        }
        .onAppear {
            // Sync the toggle to the policy controller's current setting.
            appState.dnsPolicy.holdDefaultDNS = holdDefaultDNS
        }
        .onReceive(appState.dnsApplier.$state) { _ in
            stateRevision &+= 1
        }
    }

    private var isApplying: Bool {
        if case .applying = helperState { return true }
        return false
    }

    private func toggleHelper() {
        Task { @MainActor in
            switch helperState {
            case .installed:
                await appState.dnsApplier.uninstall()
            case .uninstalled, .error:
                await appState.dnsApplier.install()
            case .applying:
                break
            }
        }
    }
}
