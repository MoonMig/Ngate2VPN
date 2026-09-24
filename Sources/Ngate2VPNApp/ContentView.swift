import SwiftUI
import AppKit

// MARK: - Tab

enum AppTab: String, CaseIterable, Identifiable {
    case home     = "Home"
    case journal  = "Journal"
    case settings = "Settings"
    var id: String { rawValue }
    /// Localized tab title (the raw value is the English key).
    var title: String { L(rawValue) }
    var icon: String {
        switch self {
        case .home:     return "shield.fill"
        case .journal:  return "text.alignleft"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("appTheme") private var appTheme: String = "System"
    @AppStorage(AppLanguage.storageKey) private var appLanguage: String = AppLanguage.system.rawValue

    var body: some View {
        Group {
            switch appState.selectedTab {
            case .home:     HomeView()
            case .journal:  JournalView()
            case .settings: AppSettingsView()
            }
        }
        // A new identity per language rebuilds the whole tab tree, so every
        // `L(...)` is re-evaluated (SwiftUI would otherwise skip children whose
        // inputs did not change).
        .id(appLanguage)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.bg)
        // No implicit animation on tab switches: the incoming tab is laid out from
        // a zero-size state inside the animation transaction, which flashed an
        // empty rectangle in the middle of the window on first display.
        .transaction { $0.animation = nil }
        .onChange(of: appTheme) { _ in applyAppearance() }
        .onAppear { applyAppearance() }
    }

    /// Maps the user-chosen theme string to NSAppearance and applies it
    /// app-wide. Setting NSApp.appearance propagates to every window and
    /// every NSColor(name:dynamicProvider:) — including our DS tokens.
    private func applyAppearance() {
        let appearance: NSAppearance? = {
            switch appTheme {
            case "Light":  return NSAppearance(named: .aqua)
            case "Dark":   return NSAppearance(named: .darkAqua)
            default:       return nil       // "System" — follow system setting
            }
        }()
        NSApp.appearance = appearance
        // Also force-update the main window so live views repaint
        // immediately, not only on next event.
        NSApp.windows.forEach { $0.appearance = appearance }
    }
}

// MARK: - Titlebar Tab View (embedded via NSToolbar)

struct TitlebarTabView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage(AppLanguage.storageKey) private var appLanguage: String = AppLanguage.system.rawValue

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { t in
                TitleTabButton(t, selected: appState.selectedTab == t) {
                    appState.selectedTab = t
                }
            }
        }
        .fixedSize()
        .padding(.horizontal, 6)
        .id(appLanguage)
        .onChange(of: appLanguage) { _ in
            // Tab titles change width with the language; let the window
            // recompute its minimum width once the toolbar has re-laid out.
            NotificationCenter.default.post(name: .appLanguageChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let appLanguageChanged = Notification.Name("ngate2vpn.appLanguageChanged")
}

struct TitleTabButton: View {
    let tab: AppTab
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    init(_ tab: AppTab, selected: Bool, action: @escaping () -> Void) {
        self.tab = tab; self.selected = selected; self.action = action
    }

    var body: some View {
        // ZStack guarantees content is centered on both axes inside the pill.
        // Using onTapGesture (not Button) means no NSButton is created at all,
        // which eliminates the macOS focus ring at the source.
        ZStack {
            Capsule()
                .fill(hovered ? DS.surfaceHi.opacity(0.5) : Color.clear)

            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11, weight: .medium))
                Text(tab.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? DS.pri : (hovered ? DS.sec.opacity(0.8) : DS.sec))
            .padding(.horizontal, 12)
        }
        .frame(height: 26)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}
