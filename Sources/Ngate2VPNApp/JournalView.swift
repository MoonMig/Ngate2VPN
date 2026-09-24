import SwiftUI
import AppKit

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
                    Button(L("All tunnels")) { selectedTunnelID = nil }
                    Divider()
                    ForEach(appState.tunnels) { t in
                        Button(t.title.isEmpty ? L("Untitled") : t.title) { selectedTunnelID = t.id }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedTunnelID.flatMap { id in
                            appState.tunnels.first(where: { $0.id == id })?.title
                        } ?? L("All tunnels"))
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
                        Button(L(lvl.rawValue)) { logLevelRaw = lvl.rawValue }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(L(logLevel.rawValue))
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
                    Label(L("Copy"), systemImage: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.sec)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .help(L("Copy all visible entries"))
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
                    Label(L("Clear"), systemImage: "trash")
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
                    Text(L("No events"))
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
