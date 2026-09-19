import SwiftUI
import AppKit

// MARK: - Theme

/// Builds an NSColor that picks between two RGBA values based on the active
/// NSAppearance. Wrapping it in Color(...) makes it a SwiftUI dynamic colour,
/// so views automatically restyle when the user toggles theme.
private func dyn(
    _ darkR: Double, _ darkG: Double, _ darkB: Double, _ darkA: Double,
    _ lightR: Double, _ lightG: Double, _ lightB: Double, _ lightA: Double
) -> Color {
    Color(NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
        if isDark {
            return NSColor(red: darkR, green: darkG, blue: darkB, alpha: darkA)
        } else {
            return NSColor(red: lightR, green: lightG, blue: lightB, alpha: lightA)
        }
    })
}

// MARK: - Design Tokens
// Each token has a dark and a light variant. The light palette mimics OS X
// system gray windows: warm-white surfaces, subtle borders, dark text.

private enum DS {
    // Surfaces
    static let bg        = dyn(0.07, 0.07, 0.10, 1,   0.96, 0.96, 0.97, 1)
    static let surface   = dyn(0.12, 0.12, 0.16, 1,   1.00, 1.00, 1.00, 1)
    static let surfaceHi = dyn(0.18, 0.18, 0.23, 1,   0.92, 0.92, 0.94, 1)
    static let border    = dyn(1, 1, 1, 0.08,         0, 0, 0, 0.10)

    // Accent — same blue both modes (Apple-style system blue)
    static let accent    = dyn(0.20, 0.60, 1.00, 1,   0.00, 0.48, 1.00, 1)
    static let accentDim = dyn(0.20, 0.60, 1.00, 0.15,  0.00, 0.48, 1.00, 0.10)

    // Status colours
    static let green     = dyn(0.13, 0.85, 0.55, 1,   0.20, 0.72, 0.42, 1)
    static let orange    = dyn(1.00, 0.62, 0.18, 1,   0.95, 0.55, 0.10, 1)
    static let red       = dyn(1.00, 0.33, 0.33, 1,   0.85, 0.20, 0.20, 1)
    static let muted     = dyn(0.40, 0.40, 0.48, 1,   0.60, 0.60, 0.65, 1)

    // Text — primary, secondary, tertiary
    static let pri  = dyn(1, 1, 1, 1.00,    0, 0, 0, 0.92)
    static let sec  = dyn(1, 1, 1, 0.50,    0, 0, 0, 0.55)
    static let ter  = dyn(1, 1, 1, 0.25,    0, 0, 0, 0.30)

    static let r: CGFloat  = 10
    static let rL: CGFloat = 14
}


// MARK: - Tab

enum AppTab: String, CaseIterable, Identifiable {
    case home     = "Главная"
    case journal  = "Журнал"
    case settings = "Настройки"
    var id: String { rawValue }
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

    var body: some View {
        Group {
            switch appState.selectedTab {
            case .home:     HomeView()
            case .journal:  JournalView()
            case .settings: AppSettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.bg)
        .animation(.easeInOut(duration: 0.15), value: appState.selectedTab)
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
    }
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
                .fill(selected ? DS.surfaceHi : (hovered ? DS.surfaceHi.opacity(0.5) : Color.clear))

            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11, weight: .medium))
                Text(tab.rawValue)
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

// MARK: - HOME

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var editingID: UUID?
    @State private var deletingID: UUID?
    @State private var showDeleteAlert = false

    var body: some View {
        VStack(spacing: 0) {
            // Sub-header — fixed height keeps everything vertically centered
            HStack(alignment: .center, spacing: 10) {
                Text("Ngate2VPN")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.pri)
                Spacer()
                SmallButton("Connect All",
                            primary: true,
                            enabled: !appState.allTunnelsActive) { appState.connectAll() }
                SmallButton("Disconnect All",
                            primary: true,
                            tintColor: DS.red,
                            enabled: appState.anyTunnelActive) { appState.disconnectAll() }
                Divider().frame(height: 16).background(DS.border)
                Button { appState.addTunnel() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.accent)
                        .frame(width: 24, height: 24)
                        .background(DS.accentDim, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("New profile")
            }
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(DS.surface)


            if appState.tunnels.isEmpty {
                EmptyProfiles { appState.addTunnel() }
            } else {
                // List supports .onMove (drag-to-reorder); we strip its native
                // chrome to keep the look consistent with the rest of the app.
                List {
                    ForEach(appState.tunnels) { tunnel in
                        ProfileRow(
                            tunnelID: tunnel.id,
                            onEdit:   { editingID = tunnel.id },
                            onDelete: { deletingID = tunnel.id; showDeleteAlert = true }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(DS.bg)
                        .listRowSeparator(.visible)
                        .listRowSeparatorTint(DS.border)
                        .alignmentGuide(.listRowSeparatorLeading)  { _ in 9 }
                        .alignmentGuide(.listRowSeparatorTrailing) { d in d.width - 9 }
                    }
                    .onMove { source, destination in
                        appState.tunnels.move(fromOffsets: source, toOffset: destination)
                        appState.persist()
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(DS.bg)
            }
        }
        // Edit sheet
        .sheet(item: Binding<ID?>(
            get: {
                guard let id = editingID else { return nil }
                return ID(value: id)
            },
            set: { editingID = $0?.value }
        )) { w in
            EditSheet(tunnelID: w.value).environmentObject(appState)
        }
        // Delete confirmation
        .confirmationDialog("Delete Profile?", isPresented: $showDeleteAlert, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                deletingID.map { appState.removeTunnel($0) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }
}

private struct ID: Identifiable { let value: UUID; var id: UUID { value } }

struct EmptyProfiles: View {
    let onAdd: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shield.slash").font(.system(size: 36, weight: .thin)).foregroundStyle(DS.ter)
            Text("No profiles").font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.sec)
            SmallButton("Add Profile", primary: true, action: onAdd)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Profile Row

struct ProfileRow: View {
    @EnvironmentObject private var appState: AppState
    let tunnelID: UUID
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    private func dotColor(_ s: TunnelState) -> Color {
        switch s {
        case .running:            return DS.green
        case .degraded:           return DS.orange
        case .starting,.stopping: return DS.orange
        case .failed:             return DS.red
        case .stopped:            return DS.muted
        }
    }

    var body: some View {
        if let snap = appState.snapshot(for: tunnelID) {
            let st = snap.runtime.status
            let active = st == .running || st == .degraded
            let busy   = st == .starting || st == .stopping

            HStack(spacing: 14) {
                // Icon bubble
                ZStack {
                    Circle().fill(dotColor(st).opacity(0.14)).frame(width: 38, height: 38)
                    Image(systemName: "shield.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(dotColor(st))
                }

                // Text
                VStack(alignment: .leading, spacing: 3) {
                    Text(snap.configuration.title.isEmpty ? "Untitled" : snap.configuration.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.pri)
                        .lineLimit(1)
                    Text(snap.configuration.endpointURL.isEmpty ? st.title : snap.configuration.endpointURL)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.sec)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                // Status/IP badge
                if busy || (active && snap.runtime.clientAddress != nil) {
                    let badgeText = busy ? st.title : (snap.runtime.clientAddress ?? "")
                    let badgeColor = busy ? DS.orange : DS.green
                    Text(badgeText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(badgeColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(badgeColor.opacity(0.12), in: Capsule())
                }

                // Toggle
                RoundedToggle(isOn: active || busy, color: dotColor(st), busy: busy) {
                    appState.toggleConnection(for: tunnelID)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: DS.r)
                    .fill(hovered ? DS.surfaceHi.opacity(0.6) : Color.clear)
            )
            .animation(.easeOut(duration: 0.1), value: hovered)
            .onHover { hovered = $0 }
            .onTapGesture { onEdit() }
            .contextMenu {
                Button { onEdit() } label: { Label("Edit Profile", systemImage: "pencil") }
                Divider()
                // Reorder — alternative to drag-and-drop
                if let idx = appState.tunnels.firstIndex(where: { $0.id == tunnelID }) {
                    Button {
                        moveUp(currentIndex: idx)
                    } label: {
                        Label("Move Up", systemImage: "arrow.up")
                    }
                    .disabled(idx == 0)

                    Button {
                        moveDown(currentIndex: idx)
                    } label: {
                        Label("Move Down", systemImage: "arrow.down")
                    }
                    .disabled(idx >= appState.tunnels.count - 1)

                    Divider()
                }
                Button(role: .destructive) { onDelete() } label: {
                    // Inside a context menu, .foregroundStyle on Label has no effect.
                    // Composing the row by hand lets us tint both glyph and text red.
                    HStack {
                        Text("Delete Profile")
                        Image(systemName: "trash")
                    }
                    .foregroundStyle(DS.red)
                }
            }
        }
    }

    private func moveUp(currentIndex idx: Int) {
        guard idx > 0 else { return }
        appState.tunnels.swapAt(idx, idx - 1)
        appState.persist()
    }

    private func moveDown(currentIndex idx: Int) {
        guard idx < appState.tunnels.count - 1 else { return }
        appState.tunnels.swapAt(idx, idx + 1)
        appState.persist()
    }
}

// MARK: - Rounded Toggle

struct RoundedToggle: View {
    let isOn: Bool
    let color: Color
    let busy: Bool
    let onTap: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(isOn ? color : DS.surfaceHi)
                .frame(width: 44, height: 26)
            Circle()
                .fill(Color.white)
                .frame(width: 20, height: 20)
                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                .offset(x: isOn ? 9 : -9)
                .animation(.spring(response: 0.22, dampingFraction: 0.75), value: isOn)
            if busy {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.4)
                    .offset(x: isOn ? 9 : -9)
            }
        }
        .frame(width: 44, height: 26)
        .onTapGesture { onTap() }
        .opacity(busy ? 0.7 : 1)
    }
}

// MARK: - Edit Sheet

struct EditSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let tunnelID: UUID
    @State private var draft = TunnelConfiguration(title: "")

    private var hasChanges: Bool {
        guard let saved = appState.snapshot(for: tunnelID)?.configuration else { return false }
        return draft.title != saved.title
            || draft.endpointURL != saved.endpointURL
            || draft.authMethod != saved.authMethod
            || draft.serialNumber != saved.serialNumber
            || draft.username != saved.username
            || !draft.pinCode.isEmpty
            || !draft.password.isEmpty
            || draft.autoReconnect != saved.autoReconnect
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                SheetTextButton("Cancel", color: DS.red) { dismiss() }
                Spacer()
                Text("Edit Profile").font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.pri)
                Spacer()
                SheetTextButton("Save",
                                color: hasChanges ? DS.accent : DS.ter,
                                bold: true,
                                enabled: hasChanges) {
                    appState.updateTunnel(draft); dismiss()
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
            .background(DS.surface)

            Divider().background(DS.border)

            ScrollView {
                VStack(spacing: 14) {
                    FormBlock("Profile") {
                        FieldRow(label: "Name")  { TextField("Profile name", text: $draft.title).plain() }
                        FieldRow(label: "URL")   { TextField("https://…",    text: $draft.endpointURL).plain() }
                    }
                    FormBlock("Connection") {
                        ToggleRow(label: "Auto-reconnect", icon: "arrow.clockwise", value: $draft.autoReconnect)
                    }
                    FormBlock("Auth") {
                        FieldRow(label: "Method") {
                            Picker("", selection: $draft.authMethod) {
                                ForEach(TunnelAuthMethod.allCases) { m in Text(m.title).tag(m) }
                            }.pickerStyle(.segmented)
                        }
                        if draft.authMethod == .certificate {
                            FieldRow(label: "SHA1") { TextField("Fingerprint", text: $draft.serialNumber).plain() }
                            FieldRow(label: "PIN")  { SecureField("Leave blank to keep", text: $draft.pinCode).plain() }
                        } else {
                            FieldRow(label: "Login")    { TextField("Username", text: $draft.username).plain() }
                            FieldRow(label: "Password") { SecureField("Leave blank to keep", text: $draft.password).plain() }
                        }
                    }
                    Text("Secrets are stored in macOS Keychain and never logged.")
                        .font(.system(size: 11)).foregroundStyle(DS.ter)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(18)
            }
            .background(DS.bg)
        }
        .background(DS.bg)
        .frame(width: 420, height: 400)
        .onAppear {
            if let c = appState.snapshot(for: tunnelID)?.configuration { draft = c }
        }
    }
}

// MARK: - JOURNAL

/// One row in the unified log stream. Carries the tunnel name so we can
/// label each entry when "All tunnels" is selected.
struct UnifiedLogEntry: Identifiable {
    let id = UUID()
    let tunnelID: UUID?
    let tunnelTitle: String?
    let text: String
}

/// Log severity levels that the user can filter by in the Journal.
/// "Info" includes Info, Warning, Critical, Error.
/// "Errors" includes only Critical / Error.
/// "Debug" shows everything including Debug.
enum LogLevel: String, CaseIterable, Identifiable {
    case errors = "Errors"
    case info   = "Info"
    case debug  = "Debug"
    var id: String { rawValue }
}

struct JournalView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedTunnelID: UUID?
    /// Persisted across launches.
    @AppStorage("journalLogLevel") private var logLevelRaw: String = LogLevel.info.rawValue
    /// System pill — independent toggle, default OFF. Persisted across
    /// launches so users who normally hide system noise stay that way,
    /// and the rare user who wants it visible doesn't have to re-enable
    /// every time the app starts.
    @AppStorage("journalShowSystem") private var showSystem: Bool = false

    private var logLevel: LogLevel {
        LogLevel(rawValue: logLevelRaw) ?? .info
    }

    /// All log lines from all tunnels (or just one if a profile is selected),
    /// filtered by the two filters above.
    private var entries: [UnifiedLogEntry] {
        let tunnels = selectedTunnelID
            .flatMap { id in appState.tunnels.first(where: { $0.id == id }).map { [$0] } }
            ?? appState.tunnels

        var result: [UnifiedLogEntry] = []
        if showSystem {
            for line in appState.systemLogLines {
                if !lineMatches(level: logLevel, line: line) { continue }
                result.append(UnifiedLogEntry(tunnelID: nil, tunnelTitle: nil, text: line))
            }
        }

        for tunnel in tunnels {
            let title = tunnel.title.isEmpty ? "Untitled" : tunnel.title
            let lines = appState.snapshot(for: tunnel.id)?.runtime.logLines ?? []
            for line in lines {
                if isSystemLog(line) {
                    if !showSystem { continue }
                    if !lineMatches(level: logLevel, line: line) { continue }
                } else {
                    if !lineMatches(level: logLevel, line: line) { continue }
                }
                result.append(UnifiedLogEntry(tunnelID: tunnel.id, tunnelTitle: title, text: line))
            }
        }
        // Fast path: when the user is looking at a single tunnel AND the
        // System pill is off, every entry in `result` came from that
        // tunnel's buffer, which is appended in time order. There's
        // nothing to merge or reorder, so we skip the sort entirely.
        // Significant for the common case where the buffer reaches its
        // 30 k cap — saves ~Nlog(N) compares each render.
        if selectedTunnelID != nil, !showSystem {
            return result
        }

        return result.enumerated()
            .sorted { lhs, rhs in
                let leftTime = timestampKey(from: lhs.element.text)
                let rightTime = timestampKey(from: rhs.element.text)
                if leftTime == rightTime {
                    return lhs.offset < rhs.offset
                }
                return leftTime < rightTime
            }
            .map(\.element)
    }

    /// Decide whether a line should be shown given the current minimum level.
    /// We extract the severity TOKEN (Debug/Info/Warning/Critical/Error) from
    /// the line — it always precedes the message body. Previously we matched
    /// on substrings anywhere in the line, which incorrectly flagged Debug
    /// lines containing words like "Failed" or "error" in their bodies as
    /// errors.
    private func lineMatches(level: LogLevel, line: String) -> Bool {
        let detected = detectLevel(in: line)

        switch level {
        case .errors:
            // Only Critical / Error
            return detected == .critical || detected == .error
        case .info:
            // Info, Warning, Critical, Error — everything except Debug
            return detected != .debug
        case .debug:
            // Show everything
            return true
        }
    }

    /// Severity tokens that ngateconsoleclient emits.
    private enum DetectedLevel { case debug, info, warning, critical, error, unknown }

    /// Extracts the level word from a line. ngate writes lines like
    /// "Apr 25 08:16:43 Debug Failed to ...". We tokenize and look for the
    /// first known level keyword — words AFTER that point are part of the
    /// message body and must not influence classification.
    private func detectLevel(in line: String) -> DetectedLevel {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        for token in tokens {
            switch token.lowercased() {
            case "debug":    return .debug
            case "info":     return .info
            case "warning":  return .warning
            case "critical": return .critical
            case "error":    return .error
            default: continue
            }
        }
        return .unknown
    }

    /// Lines tagged by AppState.appendSystemLog contain "[SYSTEM]".
    private func isSystemLog(_ line: String) -> Bool {
        line.contains("[SYSTEM]")
    }

    /// Extracts a sortable timestamp key from a log line.
    /// Lines start with `dd.MM.yyyy HH:mm:ss`; we reorder to `yyyy-MM-dd HH:mm:ss`
    /// so lexicographic comparison equals chronological order. Falls back to
    /// bare `HH:mm:ss` for old in-memory entries that pre-date the date prefix.
    private func timestampKey(from line: String) -> String {
        let scalars = Array(line.unicodeScalars)
        if scalars.count >= 19,
           scalars[2] == ".",
           scalars[5] == ".",
           scalars[10] == " ",
           scalars[13] == ":",
           scalars[16] == ":" {
            let dd   = String(scalars[0..<2].map(Character.init))
            let mm   = String(scalars[3..<5].map(Character.init))
            let yyyy = String(scalars[6..<10].map(Character.init))
            let time = String(scalars[11..<19].map(Character.init))
            return "\(yyyy)-\(mm)-\(dd) \(time)"
        }
        guard scalars.count >= 8,
              scalars[2] == ":",
              scalars[5] == ":" else { return "99:99:99" }
        return String(scalars[0..<8].map(Character.init))
    }

    /// Concatenates all currently visible entries into a single copy-friendly string.
    private var allText: String {
        entries.map { e in
            if selectedTunnelID == nil, !isSystemLog(e.text), let tunnelTitle = e.tunnelTitle {
                return "[\(tunnelTitle)] \(e.text)"
            }
            return e.text
        }.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(alignment: .center, spacing: 8) {
                // Profile filter — styled to match the Home header
                Menu {
                    Button("All tunnels") { selectedTunnelID = nil }
                    Divider()
                    ForEach(appState.tunnels) { t in
                        Button(t.title.isEmpty ? "Untitled" : t.title) { selectedTunnelID = t.id }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedTunnelID.flatMap { id in
                            appState.tunnels.first(where: { $0.id == id })?.title
                        } ?? "All tunnels")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.pri)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DS.sec)
                    }
                }
                // .menuIndicator(.hidden) — the built-in NSPopUpButton-style
                // indicator that AppKit overlays on `.borderlessButton` /
                // `.button` styles. Our label already draws a custom
                // chevron on the right, so AppKit's extra glyph on the
                // left was visual duplication. Hidden here, our
                // chevron is now the only affordance.
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                // Log level — dropdown menu, persisted across launches
                Menu {
                    ForEach(LogLevel.allCases) { lvl in
                        Button(lvl.rawValue) { logLevelRaw = lvl.rawValue }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(logLevel.rawValue)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DS.sec)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DS.ter)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(DS.surfaceHi, in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                // System pill — independent toggle, never compressed
                Pill("System", active: showSystem) { showSystem.toggle() }
                    .fixedSize()

                Spacer()

                // Copy all visible entries
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(allText, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.sec)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .help("Copy all visible entries")
                .disabled(entries.isEmpty)

                // Clear logs
                Button {
                    if let id = selectedTunnelID {
                        appState.clearLog(for: id)
                    } else {
                        appState.tunnels.forEach { appState.clearLog(for: $0.id) }
                        appState.clearSystemLog()
                    }
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.sec)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(DS.surface)


            // Single unified log stream — all entries in one scrollable, selectable area
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 28, weight: .thin))
                        .foregroundStyle(DS.ter)
                    Text("No events")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.ter)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.bg)
            } else {
                LogTextView(
                    entries: entries,
                    showTunnelTag: selectedTunnelID == nil
                )
                .background(DS.bg)
            }
        }
    }
}

// MARK: - LogTextView (NSTextView-backed for cross-line selection)

/// `NSTextView` subclass whose only job is to keep the layout manager in
/// sync with the text-view frame at every step of a live window resize.
///
/// Why this exists: `NSLayoutManager` defers full re-flow during live
/// resize as a performance optimisation. With a vanilla `NSTextView` you
/// see the text "freeze" at the wrap position it had when the drag began,
/// and only after you release the mouse does AppKit do the final relayout
/// — which makes the last few words abruptly jump to a new line.
///
/// Overriding `setFrameSize(_:)` puts our re-flow code on every single
/// pixel of resize (this method is called by AppKit during the drag,
/// inside the `eventTracking` runloop mode). We force the container
/// geometry to match the new width and notify the layout manager
/// explicitly via `textContainerChangedGeometry(_:)`, which bypasses the
/// usual deferral and gives smooth, continuous re-wrapping.
///
/// **Stick-to-bottom is also handled here, synchronously.** If we left it
/// to a separate `frameDidChangeNotification` observer that posted a
/// `Task { @MainActor in scrollToBottom() }`, there would be a frame in
/// every drag tick where the layout had updated but the scroll position
/// hadn't yet — visible as flicker only when the viewport was at the
/// bottom (in the middle of the log there's nothing to flicker, the
/// scroll position is unchanged either way). Capturing "was the user
/// near the bottom?" before super.setFrameSize and re-applying scroll
/// **after** the geometry update — all inside the same call — eliminates
/// that frame entirely.
private final class WrappingLogTextView: NSTextView {
    override func setFrameSize(_ newSize: NSSize) {
        // Capture the user's visual reference point BEFORE any layout
        // changes happen.
        let shouldStickToAbsoluteBottom = isViewportAtBottom()
        let bottomAnchorChar = shouldStickToAbsoluteBottom
            ? nil
            : lastVisibleCharacterIndex()

        super.setFrameSize(newSize)
        guard let layoutManager, let textContainer else { return }
        let inset = textContainerInset
        let newContainerWidth = max(1, newSize.width - inset.width * 2)
        if abs(textContainer.containerSize.width - newContainerWidth) >= 0.5 {
            textContainer.containerSize = NSSize(
                width: newContainerWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        layoutManager.textContainerChangedGeometry(textContainer)
        // ensureLayout(for: container) is the safe, non-recursive way
        // to flush layout. DO NOT use glyphRange(for: container) or
        // usedRect(for: container) here — those internally call
        // `_resizeTextViewForTextContainer`, which calls back into
        // setFrameSize, causing infinite recursion (cf. crash report
        // for 2.18 — bottomed out at ~12 800 stack frames).
        layoutManager.ensureLayout(for: textContainer)

        if shouldStickToAbsoluteBottom {
            scrollViewportToBottom()
        } else if let charIdx = bottomAnchorChar {
            scrollCharacterToViewportBottom(charIdx)
        }
    }

    /// Returns true when the user is reading the live tail of the log.
    /// Threshold of 24 pt allows for sub-pixel drift from re-layouts
    /// without losing the "is sticking" signal.
    fileprivate func isViewportAtBottom(threshold: CGFloat = 24) -> Bool {
        guard let scrollView = enclosingScrollView else { return true }
        let documentHeight = frame.height
        let viewportHeight = scrollView.contentView.bounds.height
        let currentY = scrollView.contentView.bounds.origin.y
        let maxY = max(0, documentHeight - viewportHeight)
        return maxY - currentY <= threshold
    }

    /// Pins the visible viewport to the bottom of the document. Uses
    /// `frame.height` (not `usedRect`) because reading `usedRect(for:)`
    /// internally re-enters `setFrameSize` and recurses.
    fileprivate func scrollViewportToBottom() {
        guard let scrollView = enclosingScrollView else { return }
        let documentHeight = frame.height
        let viewportHeight = scrollView.contentView.bounds.height
        let maxY = max(0, documentHeight - viewportHeight)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Returns the character index of the **last** character currently
    /// visible in the viewport — the user's natural visual anchor when
    /// reading the bottom of the journal.
    ///
    /// **Implementation.** We probe `glyphIndex(for: in:)` at the
    /// bottom-right corner of the viewport (in container coordinates),
    /// minus one point so we land inside the last visible line rather
    /// than rounding into the line below or off the end of the
    /// document. Bottom-RIGHT (not bottom-left) is critical: if a log
    /// line wraps to two visual lines, the bottom-left point would hit
    /// the START of the bottom visual line, while the bottom-right
    /// point hits its END — which is what the user sees as their
    /// anchor point.
    ///
    /// Previous attempts:
    ///   * `glyphIndex(for: bottomLeft, in:)` returned the first glyph
    ///     of the bottom line. After reflow that line might wrap into
    ///     two visual lines and our anchor (its first glyph) was
    ///     above the new visual bottom.
    ///   * `glyphRange(forBoundingRect: viewport, in:)` excludes line
    ///     fragments that are only partially visible at the bottom
    ///     edge, so we'd return a character one line higher than the
    ///     user's actual visual anchor.
    private func lastVisibleCharacterIndex() -> Int? {
        guard let scrollView = enclosingScrollView,
              let layoutManager,
              let textContainer else { return nil }
        guard layoutManager.numberOfGlyphs > 0 else { return nil }

        let visibleRect = scrollView.contentView.documentVisibleRect
        // Make sure layout exists for every line currently on screen.
        layoutManager.ensureLayout(for: textContainer)

        // Bottom-right corner of the viewport in textContainer coords.
        // -1 keeps us inside the last visible line.
        let probePoint = NSPoint(
            x: max(0, visibleRect.maxX - textContainerOrigin.x - 1),
            y: max(0, visibleRect.maxY - textContainerOrigin.y - 1)
        )
        let glyphIdx = layoutManager.glyphIndex(for: probePoint, in: textContainer)
        let safeGlyphIdx = min(glyphIdx, max(0, layoutManager.numberOfGlyphs - 1))
        return layoutManager.characterIndexForGlyph(at: safeGlyphIdx)
    }

    /// Scrolls so the line containing `charIdx` sits at the bottom
    /// of the viewport. Used to preserve the user's reading anchor
    /// across a reflow.
    private func scrollCharacterToViewportBottom(_ charIdx: Int) {
        guard let scrollView = enclosingScrollView,
              let layoutManager,
              let textContainer else { return }

        let textLength = (string as NSString).length
        guard textLength > 0 else { return }
        let safeCharIdx = max(0, min(charIdx, textLength - 1))
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: safeCharIdx, length: 1),
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return }

        let charBounds = layoutManager.boundingRect(
            forGlyphRange: glyphRange,
            in: textContainer
        )
        let bottomInTextView = charBounds.maxY + textContainerOrigin.y
        let viewportHeight = scrollView.contentView.bounds.height
        let targetY = max(0, bottomInTextView - viewportHeight)
        // No manual clamp via documentHeight — reading `usedRect(for:)`
        // re-enters setFrameSize and recurses (crash in 2.18). NSClipView's
        // own clamping at scroll time keeps us in the legal range.
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// Wraps NSTextView so the user can select and copy text across multiple lines,
/// just like in any native macOS text area. Lines are rendered as one
/// continuous attributed string with severity-based colouring.
///
/// **Performance.** Older versions rebuilt the entire `NSAttributedString`
/// from scratch on every SwiftUI update, which was O(N) per added line and
/// became visibly laggy after a few thousand entries. Now we detect the
/// common case where SwiftUI has just appended new entries to a previously
/// rendered list, and only build / append the new tail — turning a fresh
/// log line into an O(K) operation where K is the number of new lines, no
/// matter how big the journal has grown. Filter changes, profile switches
/// and Clear still trigger a single full rebuild.
struct LogTextView: NSViewRepresentable {
    let entries: [UnifiedLogEntry]
    let showTunnelTag: Bool

    /// Single-line tunnel-tag colour — blue accent. Hoisted so we don't
    /// allocate it per line during rebuilds.
    private static let tagColor = NSColor(red: 0.20, green: 0.60, blue: 1.00, alpha: 1.0)
    /// SYSTEM tag colour — orange to match its severity colour.
    private static let systemTagColor = NSColor(red: 1.00, green: 0.62, blue: 0.18, alpha: 1.0)
    private static let logFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let tagFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // No frame-change notifications: stick-to-bottom during resize
        // is handled synchronously inside WrappingLogTextView, so we
        // don't need an asynchronous notification observer.

        let contentSize = scrollView.contentSize
        let textView = WrappingLogTextView(
            frame: NSRect(origin: .zero, size: contentSize)
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        textView.isEditable = false
        textView.isSelectable = true                       // cross-line selection works here
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 14, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.font = Self.logFont
        textView.layoutManager?.allowsNonContiguousLayout = false

        scrollView.documentView = textView
        context.coordinator.configure(scrollView: scrollView, textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coord = context.coordinator
        let newCount = entries.count
        let oldCount = coord.entryCount
        let wasNearBottom = coord.isNearBottom()

        // Decide between incremental append and full rebuild.
        //
        // Append-only path requires that the entries we already rendered
        // are exactly the same as the prefix of the new array. Since
        // SwiftUI re-creates UnifiedLogEntry instances (their UUIDs are
        // ephemeral), we use the text of the boundary entry as a cheap
        // fingerprint — the journal is purely additive, so position/text
        // pairs are stable over an append. Anything else (filter change,
        // profile switch, Clear) trips the fingerprint check and falls
        // back to a single setAttributedString.
        let canAppend: Bool
        if oldCount == 0 {
            canAppend = false
        } else if newCount < oldCount {
            // Entry list shrank — definitely a Clear or filter change.
            canAppend = false
        } else if let fingerprint = coord.lastBoundaryFingerprint,
                  oldCount - 1 < newCount,
                  entries[oldCount - 1].text == fingerprint {
            canAppend = true
        } else {
            canAppend = false
        }

        if canAppend, let storage = textView.textStorage {
            // Build attributed string for just the new tail and append.
            let appended = Self.buildAttributedString(
                for: entries[oldCount..<newCount],
                showTunnelTag: showTunnelTag,
                leadingNewline: oldCount > 0
            )
            storage.append(appended)
        } else {
            // Full rebuild — also covers initial render and Clear.
            textView.textStorage?.setAttributedString(
                Self.buildAttributedString(
                    for: entries[0..<newCount],
                    showTunnelTag: showTunnelTag,
                    leadingNewline: false
                )
            )
        }

        coord.entryCount = newCount
        coord.lastBoundaryFingerprint = entries.last?.text

        // Scroll-to-bottom decision:
        //
        // **Full rebuild** (initial render, profile switch, filter
        // change, Clear) — always land at the bottom. The user has
        // just changed *what* they're looking at; the natural default
        // is to see the most recent events of the new view, not
        // wherever the previous viewport happened to be.
        //
        // **Append-only** — respect the user's reading position. If
        // they've scrolled up to read history, leave them there. Only
        // follow the live tail when they were already near the bottom.
        let shouldScrollToBottom: Bool
        if !canAppend {
            shouldScrollToBottom = newCount > 0
        } else {
            shouldScrollToBottom = newCount > oldCount && wasNearBottom
        }

        if shouldScrollToBottom {
            DispatchQueue.main.async {
                coord.scrollToBottom()
            }
        }
    }

    /// Builds an `NSAttributedString` for an arbitrary slice of entries.
    /// `leadingNewline` adds a separator in front so the produced fragment
    /// can be appended to existing text without merging into the previous
    /// line.
    private static func buildAttributedString(
        for slice: ArraySlice<UnifiedLogEntry>,
        showTunnelTag: Bool,
        leadingNewline: Bool
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        guard !slice.isEmpty else { return result }

        if leadingNewline {
            result.append(NSAttributedString(string: "\n"))
        }

        let indices = Array(slice.indices)
        for (offset, idx) in indices.enumerated() {
            let entry = slice[idx]
            let isSystem = entry.text.contains("[SYSTEM]")

            if isSystem {
                // System entries arrive as "yyyy-MM-dd HH:mm:ss [SYSTEM] [profile] message"
                // (or for bulk system, "yyyy-MM-dd HH:mm:ss [SYSTEM] message").
                //
                // We render them so the orange [SYSTEM] tag comes
                // FIRST, then the timestamp, then the message — same
                // visual order as ngate lines, where the [profile]
                // tag is prepended ahead of ngate's own timestamp.
                // This keeps the journal column-aligned: every row
                // starts with a coloured tag of fixed-ish width, then
                // the time, then the body.
                // Strip the [SYSTEM] tag (followed by space or tab) so the renderer
                // can prepend a freshly styled orange "[SYSTEM] " in its place.
                let trimmed = entry.text
                    .replacingOccurrences(of: "[SYSTEM] ", with: "")
                    .replacingOccurrences(of: "[SYSTEM]\t", with: "")
                // trimmed is now: "yyyy-MM-dd HH:mm:ss.SSS Info\t[profile] message"
                // or "yyyy-MM-dd HH:mm:ss.SSS Warning\tmessage" etc.
                let displayText = displaySafeLine(trimmed)

                result.append(NSAttributedString(
                    string: "[SYSTEM] ",
                    attributes: [.font: tagFont, .foregroundColor: systemTagColor]
                ))
                result.append(NSAttributedString(
                    string: displayText,
                    attributes: [.font: logFont, .foregroundColor: nsColor(for: entry.text)]
                ))
            } else {
                let displayText = displaySafeLine(entry.text)

                if showTunnelTag, let tunnelTitle = entry.tunnelTitle {
                    let tag = NSAttributedString(
                        string: "[\(tunnelTitle)] ",
                        attributes: [.font: tagFont, .foregroundColor: tagColor]
                    )
                    result.append(tag)
                }

                let color = nsColor(for: entry.text)
                let line = NSAttributedString(
                    string: displayText,
                    attributes: [.font: logFont, .foregroundColor: color]
                )
                result.append(line)
            }

            if offset < indices.count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }
        return result
    }

    /// ngate sometimes emits tabs between the severity token and JSON
    /// payload. NSTextView expands tabs to wide tab stops and wraps there
    /// even when the visible text would otherwise fit. Display them as
    /// spaces while keeping each log entry a single logical line.
    private static func displaySafeLine(_ line: String) -> String {
        line
            .replacingOccurrences(of: "\t", with: "    ")
            .replacingOccurrences(of: "\r", with: "")
    }

    private static func nsColor(for line: String) -> NSColor {
        // Match coloring to the detected level TOKEN only — same logic as
        // the Journal filter, so we don't accidentally color a Debug line
        // red just because the message body contains words like "failed".
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        for token in tokens {
            switch token.lowercased() {
            case "critical", "error":
                return NSColor(red: 1.00, green: 0.33, blue: 0.33, alpha: 0.9)
            case "warning":
                return NSColor(red: 1.00, green: 0.62, blue: 0.18, alpha: 0.9)
            case "debug", "info":
                // Stop scanning — we found the level token, anything after
                // it is the message body and must not influence colour.
                break
            default:
                continue
            }
            break
        }
        // Neutral text — adapts to current theme
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return isDark
                ? NSColor.white.withAlphaComponent(0.5)
                : NSColor.black.withAlphaComponent(0.65)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var scrollView: NSScrollView?
        private weak var textView: NSTextView?
        var entryCount = 0
        /// Text of the last entry we rendered. Used to detect whether the
        /// next SwiftUI update is a pure append (text matches) or a
        /// filter / clear change (text differs → full rebuild).
        var lastBoundaryFingerprint: String?

        func configure(scrollView: NSScrollView, textView: NSTextView) {
            self.scrollView = scrollView
            self.textView = textView
            // Stick-to-bottom during live resize is handled inside
            // WrappingLogTextView.setFrameSize, synchronously. We keep
            // scrollToBottom available here for the new-content path
            // driven from updateNSView.
        }

        func scrollToBottom() {
            guard let scrollView, let textView else { return }
            if let container = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: container)
            }
            let documentHeight = textView.frame.height
            let viewportHeight = scrollView.contentView.bounds.height
            let maxY = max(0, documentHeight - viewportHeight)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        func isNearBottom(threshold: CGFloat = 24) -> Bool {
            guard let scrollView, let textView else { return true }
            let documentHeight = textView.frame.height
            let viewportHeight = scrollView.contentView.bounds.height
            let currentY = scrollView.contentView.bounds.origin.y
            let maxY = max(0, documentHeight - viewportHeight)
            return maxY - currentY <= threshold
        }
    }
}

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
    }
}

// MARK: - Reusable helpers

struct FormBlock<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.sec)
                .padding(.horizontal, 2).padding(.bottom, 5)
            VStack(spacing: 0) { content() }
                .background(DS.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.rL))
                .overlay(RoundedRectangle(cornerRadius: DS.rL).stroke(DS.border, lineWidth: 1))
        }
    }
}

struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.sec)
                .frame(width: 58, alignment: .trailing)
            content().frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .overlay(alignment: .bottom) { DS.border.frame(height: 1) }
    }
}

struct ToggleRow: View {
    let label: String
    let icon: String
    @Binding var value: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.accent).frame(width: 18)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.pri)
            Spacer()
            RoundedToggle(isOn: value, color: DS.accent, busy: false) { value.toggle() }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .overlay(alignment: .bottom) { DS.border.frame(height: 1) }
    }
}

struct Pill: View {
    let title: String; let active: Bool; let action: () -> Void
    init(_ title: String, active: Bool, action: @escaping () -> Void) {
        self.title = title; self.active = active; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? DS.accent : DS.sec)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(active ? DS.accentDim : DS.surfaceHi, in: Capsule())
        }.buttonStyle(.plain)
    }
}

/// Plain text button for sheet headers — Cancel/Save in macOS style.
/// Uses onTapGesture instead of Button so SwiftUI cannot apply the system
/// "default action" blue bezel that appears when a sheet is presented.
struct SheetTextButton: View {
    let label: String
    let color: Color
    let bold: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hovered = false

    init(_ label: String,
         color: Color,
         bold: Bool = false,
         enabled: Bool = true,
         action: @escaping () -> Void) {
        self.label = label
        self.color = color
        self.bold = bold
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: bold ? .semibold : .regular))
            .foregroundStyle(enabled ? color.opacity(hovered ? 0.7 : 1.0) : color.opacity(0.4))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture { if enabled { action() } }
            .onHover { hovered = enabled && $0 }
            .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

struct SmallButton: View {
    let label: String
    let primary: Bool
    let enabled: Bool
    let tintColor: Color?
    let action: () -> Void
    @State private var hovered = false

    init(_ label: String,
         primary: Bool,
         tintColor: Color? = nil,
         enabled: Bool = true,
         action: @escaping () -> Void) {
        self.label = label
        self.primary = primary
        self.tintColor = tintColor
        self.enabled = enabled
        self.action = action
    }

    private var baseTint: Color { tintColor ?? DS.accent }

    private var fillColor: Color {
        if !enabled {
            return primary ? baseTint.opacity(0.35) : DS.surface
        }
        if primary {
            return hovered ? baseTint.opacity(0.8) : baseTint
        }
        return hovered ? DS.surfaceHi : DS.surface
    }

    private var textColor: Color {
        if !enabled { return primary ? Color.white.opacity(0.6) : DS.ter }
        return primary ? .white : DS.sec
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(textColor)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7).fill(fillColor)
                )
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(primary ? Color.clear : DS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = enabled && $0 }
        .animation(.easeOut(duration: 0.1), value: hovered)
        .animation(.easeOut(duration: 0.15), value: enabled)
    }
}

// MARK: - TextField helpers

extension TextField {
    func plain() -> some View {
        self.textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(DS.pri)
    }
}

extension SecureField {
    func plain() -> some View {
        self.textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(DS.pri)
    }
}

// SettingsView removed — settings are now in AppSettingsView (Settings tab in main window).

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
