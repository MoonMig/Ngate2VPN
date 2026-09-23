import Foundation
import SwiftUI
import Combine
import CryptoKit

// Journal / log ingestion: per-tunnel and system log lines, timestamps, DNS parser feed.
// Split out of AppState.swift; members are internal (not private) so the
// extensions in the sibling files can share state.
extension AppState {
    /// Per-tunnel DNS parser. Feeds raw log lines through the parser and
    /// upserts any extracted DNS config into the global policy controller.
    func feedDNSParser(pieces: [String], tunnelID: UUID) {
        // Lazily create one parser per tunnel.
        let parser = dnsParsers[tunnelID] ?? NgateGatewayResponseParser()
        if dnsParsers[tunnelID] == nil {
            dnsParsers[tunnelID] = parser
        }

        for piece in pieces {
            let wasCapturing = parser.capturing
            let extracted = parser.feed(piece)
            let isCapturing = parser.capturing

            // Diagnostic: log the moment the JSON block is first detected.
            if !wasCapturing && isCapturing {
                appendSystemLog("DNS: JSON block detected, reading…", to: tunnelID)
            }

            // Diagnostic: parse was triggered (capturing ended) but produced nothing.
            if wasCapturing && !isCapturing && extracted.isEmpty {
                let reason = parser.parseFailureReason
                let suffix = reason.isEmpty ? "" : " — \(reason)"
                appendSystemLog("DNS: JSON block parsed but no tunnel data found\(suffix)", to: tunnelID, level: .warning)
            }

            guard !extracted.isEmpty else { continue }

            // Gateway can return multiple IPTunnel entries in one JSON block.
            // Calling upsert() per-entry would overwrite the previous call for
            // the same tunnelID: if the last entry has empty SearchDomains the
            // split-DNS domains collected from earlier entries are lost, and if
            // it has empty DNSs the whole config is silently removed via
            // TunnelDNSConfig.isValid. Aggregate all entries into one upsert.
            let allServers = Array(Set(extracted.flatMap { $0.dnsServers }))
            let allDomains = Array(Set(extracted.flatMap { $0.searchDomains }))

            let srvStr = allServers.isEmpty ? "none" : allServers.joined(separator: ", ")
            let domStr = allDomains.isEmpty ? "none" : allDomains.joined(separator: ", ")
            appendSystemLog("DNS parsed from gateway — servers: \(srvStr); domains: \(domStr)", to: tunnelID)

            if allServers.isEmpty {
                appendSystemLog("DNS: no DNS servers in gateway response — split-DNS requires nameserver addresses; check gateway configuration", to: tunnelID, level: .warning)
            }

            dnsPolicy.upsert(
                tunnelID: tunnelID,
                dnsServers: allServers,
                matchDomains: allDomains
            )
        }
    }

    /// Application-level log (e.g. watchdog actions, error explanations,
    /// "Stopped" / "Disconnect requested" announcements). These lines get a
    /// Application-level log entry related to a specific tunnel. Format:
    ///     [SYSTEM] [TunnelName] message
    /// "[SYSTEM]" comes first because the Journal filters on it; the tunnel
    /// name lets the user know which profile the event belongs to.
    func appendSystemLog(_ line: String, to id: UUID, level: SystemLogLevel = .info) {
        let title = tunnelTitle(for: id)
        let ts = Self.logTimestampFormatter.string(from: Date())
        // Format: "30.05.2026 11:08:52.123 [SYSTEM] Info    \t[profile] message"
        // Level word is padded to the width of the longest level ("Critical" = 8
        // chars) so all messages align in the same column in the monospaced journal.
        let levelField = level.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
        appendLog("\(ts) [SYSTEM] \(levelField)  [\(title)] " + line, to: id)
    }

    /// Application-level log entry NOT tied to a specific tunnel (e.g. DNS
    /// Helper status, app-wide diagnostics). Kept in a dedicated app-wide
    /// buffer so the Journal can show it once instead of duplicating it for
    /// every profile.
    func appendBulkSystemLog(_ line: String, level: SystemLogLevel = .info) {
        let ts = Self.logTimestampFormatter.string(from: Date())
        let levelField = level.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
        let formattedLine = "\(ts) [SYSTEM] \(levelField)  " + line
        systemLogLines.append(formattedLine)
        Self.trimLogBuffer(&systemLogLines, target: maxSystemLogLines, slack: logTrimSlack)
        NSLog("%@", formattedLine)
    }

    func appendLog(_ line: String, to id: UUID) {
        guard deletingTunnelIDs.contains(id) == false else { return }
        guard runtime[id] != nil else { return }

        // Process output can arrive as a multi-line chunk, especially with
        // -vvvv verbosity. Split on newlines and append each line separately
        // so every entry is correctly attributed to this tunnel.
        let pieces = line
            .split(whereSeparator: { $0.isNewline })
            .map { String($0) }

        let now = Date()
        let ts = Self.tf.string(from: now)
        let datePrefix = Self.datePrefixFormatter.string(from: now)

        // Feed each raw line into this tunnel's DNS parser. Lines that
        // contain the gateway's JSON response with "IPTunnels" / "DNSs" /
        // "SearchDomains" produce extracted configs which we hand to the
        // policy controller.
        // Guard: appendSystemLog also calls appendLog (to write [SYSTEM] entries
        // to the same journal). Without this guard those lines would re-enter
        // feedDNSParser while capturing==true and corrupt the JSON buffer.
        if !line.contains("[SYSTEM]") {
            feedDNSParser(pieces: pieces, tunnelID: id)
        }

        if !line.contains("[SYSTEM]") && runtime[id]?.firstOutputAt == nil {
            runtime[id]?.firstOutputAt = Date()
        }

        for piece in pieces {
            let t = piece.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, var r = runtime[id] else { continue }

            // Two parallel formats:
            //
            //   * **In-memory** (`formattedLine`) — what the Journal UI
            //     shows. Carries the full date so cross-midnight sorting
            //     stays chronological in the unified multi-tunnel view.
            //
            //   * **On-disk** (`diskLine`) — what FileLogger archives.
            //     Carries "yyyy-MM-dd " in front so log files retain
            //     the full timestamp and remain useful after they roll
            //     over a day boundary or get archived.
            //
            // The three branches mirror appendLog's normalization
            // logic above.
            let formattedLine: String
            if let stripped = Self.stripNgateDatePrefix(from: t) {
                formattedLine = "\(datePrefix) \(stripped)"
            } else if Self.lineCarriesFullTimestamp(t) {
                formattedLine = t
            } else if Self.lineCarriesOwnTimestamp(t) {
                formattedLine = "\(datePrefix) \(t)"
            } else {
                formattedLine = "\(datePrefix) \(ts) \(t)"
            }
            r.logLines.append(formattedLine)
            Self.trimLogBuffer(&r.logLines, target: maxLogLinesPerTunnel, slack: logTrimSlack)
            runtime[id] = r
            logger(for: id).append(line: formattedLine)

            let normalized = t.lowercased()
            if let seconds = NgateOutputParser.extractLoginTransactionSeconds(from: normalized) {
                runtime[id]?.lastLoginTransactionSeconds = seconds
            }
            if let clientAddress = NgateOutputParser.extractClientAddress(from: t) {
                runtime[id]?.clientAddress = clientAddress
            }

            if normalized.contains("vpn online") {
                runtime[id]?.hasEstablishedConnection = true
                warmAdoptedAt.removeValue(forKey: id)
                runtime[id]?.isNgateReconnecting = false
                // Successful connection — reset auto-restart accounting.
                // If the tunnel later drops with a retryable error, the
                // watchdog starts the backoff sequence over from the base
                // delay rather than resuming wherever we left off.
                runtime[id]?.consecutiveWatchdogFailures = 0
                runtime[id]?.watchdogPaused = false
                transitionState(id: id, newState: .running)
                continue
            }

            if NgateOutputParser.indicatesNgateReconnect(from: normalized) {
                runtime[id]?.isNgateReconnecting = true
                continue
            }

            guard var classifiedError = NgateOutputParser.classifyError(from: normalized) else { continue }
            if tunnels.first(where: { $0.id == id })?.authMethod == .credentials {
                classifiedError = NgateOutputParser.refineCredentialsError(
                    classifiedError, loginTransactionSeconds: runtime[id]?.lastLoginTransactionSeconds
                )
            }
            let isRuntimeIssue = runtime[id]?.hasEstablishedConnection == true

            // A proxy hiccup during a session refresh is the client's own retry
            // business (it retries 5×); marking the tunnel degraded here could
            // leave it stuck if recovery prints no "VPN Online" line.
            if isRuntimeIssue && classifiedError.isRetryable && classifiedError != .proxyFailure {
                runtime[id]?.isNgateReconnecting = true
                transitionState(id: id, newState: .degraded, errorMessage: classifiedError.message, tunnelError: classifiedError)
                continue
            }

            if isRuntimeIssue {
                continue
            }

            applyConnectionError(classifiedError, to: id)
        }
    }
    
    
    func updateTrayIcon() {
        let connectedCount = runtime.values.filter {
            $0.status == .running || $0.status == .degraded
        }.count
        statusIconManager?.updateIcon(connectedCount: connectedCount, totalTunnels: runtime.count)
    }

    func logger(for tunnelID: UUID) -> FileLogger {
        if let existing = fileLoggers[tunnelID] {
            return existing
        }
        let created = FileLogger(tunnelID: tunnelID)
        fileLoggers[tunnelID] = created
        return created
    }

    func tunnelTitle(for id: UUID) -> String {
        tunnels.first(where: { $0.id == id })?.title ?? "Tunnel"
    }

    static let tf: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    static let logTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy HH:mm:ss.SSS"
        return f
    }()

    /// Date prefix used only for on-disk log files. The in-memory
    /// journal shows just the time of day for compactness; on disk
    /// we keep the full ISO date so log archives are still useful
    /// after they roll over a day boundary.
    static let datePrefixFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    /// If `line` starts with ngate's full `<MonthAbbrev> <D> ` prefix
    /// (e.g. "May 7 00:42:00.722 Debug …"), returns the line with that
    /// prefix removed (e.g. "00:42:00.722 Debug …"). Returns nil if
    /// the line doesn't match — caller falls through to other paths.
    ///
    /// Why we strip rather than leave alone: keeping `May 7 ` in the
    /// in-memory journal duplicates information already encoded in
    /// the on-disk log filename, and makes the journal noisier than
    /// our own system entries. The full date is preserved on disk via
    /// `FileLogger`; the live view only needs wall-clock time.
    static func stripNgateDatePrefix(from line: String) -> String? {
        let scalars = Array(line.unicodeScalars)
        guard scalars.count >= 16 else { return nil }
        let monthAbbrevs = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let firstThree = String(scalars[0..<3].map(Character.init))
        guard monthAbbrevs.contains(firstThree),
              scalars[3] == " " else { return nil }
        // Skip 1-2 day digits.
        var idx = 4
        while idx < scalars.count, scalars[idx].properties.numericType != nil {
            idx += 1
        }
        guard idx < scalars.count, scalars[idx] == " " else { return nil }
        idx += 1
        // Sanity-check the HH:mm:ss shape we expect right after.
        guard idx + 8 <= scalars.count,
              scalars[idx + 2] == ":",
              scalars[idx + 5] == ":" else { return nil }
        return String(scalars[idx...].map(Character.init))
    }

    /// True if `line` begins with bare `HH:mm:ss`, the timestamp shape ngate
    /// may emit after we strip its month/day prefix.
    static func lineCarriesOwnTimestamp(_ line: String) -> Bool {
        let scalars = Array(line.unicodeScalars)
        guard scalars.count >= 8 else { return false }
        return scalars[2] == ":" && scalars[5] == ":"
    }

    /// True if `line` begins with `dd.MM.yyyy HH:mm:ss`.
    static func lineCarriesFullTimestamp(_ line: String) -> Bool {
        let scalars = Array(line.unicodeScalars)
        guard scalars.count >= 19 else { return false }
        return scalars[2] == "."
            && scalars[5] == "."
            && scalars[10] == " "
            && scalars[13] == ":"
            && scalars[16] == ":"
    }

    /// Drops the oldest entries from a log buffer once it overshoots its
    /// allowed `target` size by more than `slack`. Inout so we modify the
    /// caller's array in place without copy-on-write churn from
    /// re-assigning a struct field round-trip.
    ///
    /// Why we don't trim every overflow: `Array.removeFirst(_:)` is
    /// O(N) — it has to slide the rest of the buffer left. By tolerating
    /// `slack` extra entries between trims we amortise that cost across
    /// many appends, so the per-append work stays roughly constant.
    static func trimLogBuffer(_ buffer: inout [String], target: Int, slack: Int) {
        let currentCount = buffer.count
        guard currentCount > target + slack else { return }
        buffer.removeFirst(currentCount - target)
    }
}
