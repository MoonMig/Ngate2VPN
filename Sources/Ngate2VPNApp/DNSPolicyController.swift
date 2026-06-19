import Foundation
import OSLog

// MARK: - DNS Configuration Models

/// One tunnel's contribution to the global DNS policy.
/// Built from the JSON block ngateconsoleclient prints after a successful
/// `/ng_login_and_cln_tunnels` exchange.
struct TunnelDNSConfig: Equatable, Hashable {
    /// The owning tunnel's UUID — used so DNSPolicyController knows which
    /// rules to drop when the tunnel disconnects.
    let tunnelID: UUID
    /// Resolver IPs (the "DNSs" array in the gateway response).
    let dnsServers: [String]
    /// Domain zones this tunnel should resolve (the "SearchDomains" array).
    /// EMPTY ⇒ this is a default-DNS contribution, not a split-DNS one.
    let matchDomains: [String]
    /// Wall-clock time the tunnel finished negotiating DNS. Used to break
    /// ties when two tunnels claim the same domain — newest wins.
    let connectedAt: Date

    /// True iff this config has no SearchDomains — it represents a
    /// candidate for the system-wide default resolver.
    var isDefault: Bool { matchDomains.isEmpty }

    /// True iff the config is usable. We require at least one resolver IP;
    /// without it the tunnel is silently ignored per spec.
    var isValid: Bool { !dnsServers.isEmpty }
}

/// The final, computed DNS policy that must be applied to the system.
/// `ResolvedDNSPolicy` is what `DNSPolicyController.policy` publishes —
/// a fully resolved snapshot, not a stream of deltas.
struct ResolvedDNSPolicy: Equatable {
    /// One scoped resolver per split-DNS zone. matchDomains is non-empty
    /// for every entry here.
    struct Scoped: Equatable {
        let dnsServers: [String]
        let matchDomains: [String]
    }

    /// Per-zone resolvers — each handles its own matchDomains list.
    let scopedResolvers: [Scoped]

    /// Resolver for everything else. nil ⇒ use the system default.
    let defaultResolver: [String]?

    /// Convenience — empty policy means "leave the system alone".
    static let empty = ResolvedDNSPolicy(scopedResolvers: [], defaultResolver: nil)

    var isEmpty: Bool { scopedResolvers.isEmpty && defaultResolver == nil }
}

// MARK: - DNSPolicyController

/// Aggregates per-tunnel DNS contributions and computes the system-wide
/// DNS policy. Conflict resolution rules (per spec):
///
/// • Each tunnel's `matchDomains` list claims those zones for that tunnel's
///   resolvers.
/// • If two tunnels claim the same domain, the most recently connected one
///   wins (because it overrides). When it disconnects, the previous claimant
///   regains the zone automatically.
/// • At most one tunnel may be the "default" — i.e. no SearchDomains. Most
///   recent default wins. Disconnecting it falls back to the previous default,
///   or to the system DNS if none exists.
/// • Tunnels with empty DNSs are dropped silently — they cannot participate.
///
/// The controller is a `@MainActor` ObservableObject so SwiftUI views can
/// react to policy changes if needed (e.g. to show "DNS active" in the UI).
@MainActor
final class DNSPolicyController: ObservableObject {

    /// Per-tunnel configs, keyed by tunnel UUID. Insertion order is irrelevant —
    /// `connectedAt` decides priority.
    @Published private(set) var configs: [UUID: TunnelDNSConfig] = [:]

    /// Latest computed policy, ready to apply via NEDNSSettingsManager.
    @Published private(set) var policy: ResolvedDNSPolicy = .empty

    /// "Hold Default DNS" — when true, we never advertise a default resolver.
    /// The system default is preserved and used for everything outside
    /// split-DNS zones. Default ON per spec.
    var holdDefaultDNS: Bool = true {
        didSet { recompute() }
    }

    private let logger = Logger(subsystem: "com.ngate2vpn.dns", category: "policy")

    // MARK: Public API — called by AppState

    /// Register or replace a tunnel's DNS contribution.
    /// Pass `nil` for `connectedAt` to use "now".
    func upsert(tunnelID: UUID,
                dnsServers: [String],
                matchDomains: [String],
                connectedAt: Date? = nil) {
        let config = TunnelDNSConfig(
            tunnelID: tunnelID,
            dnsServers: dnsServers,
            matchDomains: matchDomains,
            connectedAt: connectedAt ?? Date()
        )

        guard config.isValid else {
            // Spec: tunnels with empty DNSs are ignored entirely, not stored.
            logger.warning("Ignoring tunnel \(tunnelID, privacy: .public): no DNS servers")
            configs.removeValue(forKey: tunnelID)
            recompute()
            return
        }

        configs[tunnelID] = config
        recompute()
    }

    /// Drop a tunnel's contribution. Idempotent.
    func remove(tunnelID: UUID) {
        guard configs.removeValue(forKey: tunnelID) != nil else { return }
        recompute()
    }

    /// Drop everything. Returns the system to its baseline DNS state.
    func clearAll() {
        configs.removeAll()
        recompute()
    }

    // MARK: Recomputation

    /// Rebuilds `policy` from scratch every time `configs` changes.
    /// Cheaper than tracking deltas and impossible to drift.
    private func recompute() {
        // Sort by connectedAt descending — newest first. This means the
        // first tunnel we encounter that claims a domain wins. The same
        // ordering is used for the default resolver.
        let ordered = configs.values.sorted { $0.connectedAt > $1.connectedAt }

        var domainOwner: [String: TunnelDNSConfig] = [:]   // matchDomain → tunnel
        var defaultConfig: TunnelDNSConfig?

        for config in ordered {
            if config.isDefault {
                // First default wins (i.e. the most recent one); subsequent
                // defaults are shadowed.
                if defaultConfig == nil {
                    defaultConfig = config
                }
                continue
            }
            for domain in config.matchDomains {
                let key = domain.lowercased()
                if domainOwner[key] == nil {
                    domainOwner[key] = config
                }
            }
        }

        // Re-group claimed domains back into scoped resolvers, one per
        // owning tunnel. We collapse multiple matchDomains owned by the same
        // tunnel into a single Scoped entry so NEDNSSettingsManager doesn't
        // need to manage redundant rules.
        var scopedByTunnel: [UUID: ResolvedDNSPolicy.Scoped] = [:]
        for (domain, config) in domainOwner {
            if var existing = scopedByTunnel[config.tunnelID] {
                let merged = Array(Set(existing.matchDomains + [domain]))
                    .sorted()
                existing = ResolvedDNSPolicy.Scoped(
                    dnsServers: config.dnsServers,
                    matchDomains: merged
                )
                scopedByTunnel[config.tunnelID] = existing
            } else {
                scopedByTunnel[config.tunnelID] = ResolvedDNSPolicy.Scoped(
                    dnsServers: config.dnsServers,
                    matchDomains: [domain]
                )
            }
        }

        // Stable order so the published policy is deterministic — eases
        // diffing & debugging.
        let scopedResolvers = scopedByTunnel.values
            .sorted { $0.matchDomains.first ?? "" < $1.matchDomains.first ?? "" }

        let defaultResolver: [String]? = holdDefaultDNS
            ? nil                              // user opted to keep system default
            : defaultConfig?.dnsServers

        let newPolicy = ResolvedDNSPolicy(
            scopedResolvers: scopedResolvers,
            defaultResolver: defaultResolver
        )

        // Avoid spurious republishes — Equatable comparison is cheap here.
        if newPolicy != policy {
            policy = newPolicy
            logger.info("DNS policy recomputed: \(scopedResolvers.count) scoped, default \(defaultResolver?.joined(separator: ",") ?? "system", privacy: .public)")
        }
    }
}

// MARK: - Log Parser
//
// ngateconsoleclient prints the gateway response as Debug log lines that
// look like:
//
//   [15:01:24] Apr 28 15:01:24.831 Debug     {
//   [15:01:24] Apr 28 15:01:24.831 Debug         "IPTunnels" : [
//   [15:01:24] Apr 28 15:01:24.831 Debug             {
//   [15:01:24] Apr 28 15:01:24.831 Debug                 "DNSs" : [...],
//   [15:01:24] Apr 28 15:01:24.831 Debug                 "SearchDomains" : [...],
//   ...
//
// We strip the timestamp/level prefix from each line, accumulate the JSON
// payload, then parse it with JSONSerialization.

/// Stateful parser. Hold one instance per tunnel (not shared) so it can
/// accumulate the multi-line JSON across many `feed` calls.
final class NgateGatewayResponseParser {

    /// Returned to the caller when a complete response is decoded.
    struct ExtractedTunnel {
        let dnsServers: [String]
        let searchDomains: [String]
    }

    /// Lines stripped of their `[HH:MM:SS] Mon DD HH:MM:SS.mmm Debug ` prefix.
    private var buffer: String = ""

    /// Brace depth — we start collecting at the first '{' and stop when
    /// depth returns to 0. Until then everything is appended.
    private var depth: Int = 0

    /// True while we're inside a JSON block.
    var capturing: Bool = false

    /// Set by parse() when JSON decoding fails; cleared on success.
    /// feedDNSParser reads this to emit a diagnostic with the buffer sample.
    var parseFailureReason: String = ""

    /// Strips the log prefix from a single line.
    /// Returns nil when no recognised log-level keyword is found.
    private func strip(_ raw: String) -> String? {
        // Format: "[HH:MM:SS] Mon DD HH:MM:SS.mmm Level<spaces>payload"
        // Accept all standard ngate log levels, case-insensitively.
        // After the keyword, require whitespace (space or tab) so we don't
        // match the word inside payload text like "…some information…".
        let opts: String.CompareOptions = .caseInsensitive
        let keywords = [" Debug", "\tDebug", " Info", "\tInfo",
                        " Warning", "\tWarning", " Error", "\tError"]
        for keyword in keywords {
            guard let range = raw.range(of: keyword, options: opts) else { continue }
            let next = range.upperBound
            guard next == raw.endIndex || raw[next] == " " || raw[next] == "\t" else { continue }
            let after = raw[next...]
            return String(String(after).drop(while: { $0 == " " || $0 == "\t" }))
        }
        // Some ngateconsoleclient versions output "Debug     payload" with the
        // level word at column 0 — no preceding timestamp at all.  The loop
        // above only finds " Debug" (space-prefixed), so we need an anchored
        // check here.  Without it, strip() returns nil; the fallback (?? line)
        // keeps the "Debug " prefix in the buffer, which corrupts the JSON and
        // causes JSONSerialization to fail silently.
        let anchoredKeywords = ["debug", "info", "warning", "error"]
        let lower = raw.lowercased()
        for kw in anchoredKeywords {
            guard lower.hasPrefix(kw) else { continue }
            let next = raw.index(raw.startIndex, offsetBy: kw.count)
            guard next == raw.endIndex || raw[next] == " " || raw[next] == "\t" else { continue }
            return String(String(raw[next...]).drop(while: { $0 == " " || $0 == "\t" }))
        }
        return nil
    }

    /// Feed one log line. When this method returns a non-empty array,
    /// a complete response was found and parsed; otherwise more lines are
    /// needed (or the line is ignored).
    func feed(_ line: String) -> [ExtractedTunnel] {
        // Fall back to the raw line when no log-level prefix is recognised.
        // Some ngateconsoleclient versions output the JSON block as plain text
        // (no "Debug"/"Info"/… prefix), making strip() return nil for every
        // JSON line. Without the fallback the block would be silently skipped.
        let payload = strip(line) ?? line

        // Detect start of JSON object.
        // Some gateway versions log the JSON after a descriptive prefix on the
        // same Debug line (e.g. "Response: {…}"). Accept '{' anywhere in the
        // payload, not just at position 0. Brace tracking starts from '{',
        // so any text before it is ignored and cannot skew the depth counter.
        var effectivePayload = payload
        if !capturing {
            guard let braceIndex = payload.firstIndex(of: "{") else { return [] }
            capturing = true
            buffer = ""
            depth = 0
            effectivePayload = String(payload[braceIndex...])
        }

        // Track brace depth across the line — strings might contain `{`/`}`
        // but ngate's response is well-formed JSON so simple counting works.
        var inString = false
        var escape = false
        for char in effectivePayload {
            if escape { escape = false; continue }
            if char == "\\" { escape = true; continue }
            if char == "\"" { inString.toggle() }
            if inString { continue }
            if char == "{" { depth += 1 }
            if char == "}" { depth -= 1 }
        }

        buffer.append(effectivePayload)
        buffer.append("\n")

        if depth <= 0 && capturing {
            capturing = false
            let json = buffer
            buffer = ""
            depth = 0
            return parse(json)
        }
        return []
    }

    /// Resets state — call when the tunnel disconnects so leftover partial
    /// data doesn't bleed into the next session.
    func reset() {
        buffer = ""
        depth = 0
        capturing = false
    }

    /// Decodes a complete JSON blob. Searches the entire object tree
    /// recursively for "DNSs" and "SearchDomains" keys so the parser
    /// works regardless of the nesting level the gateway uses — some
    /// gateways embed DNS inside IPTunnels[] entries, others hoist it
    /// to the top level or use a different outer key.
    private func parse(_ json: String) -> [ExtractedTunnel] {
        parseFailureReason = ""
        guard let data = json.data(using: .utf8) else {
            parseFailureReason = "UTF-8 encode failed"
            return []
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            parseFailureReason = "JSONSerialization failed (buffer \(json.count) bytes)"
            return []
        }

        var servers: [String] = []
        var domains: [String] = []
        collectDNS(from: root, servers: &servers, domains: &domains)

        guard !servers.isEmpty || !domains.isEmpty else {
            parseFailureReason = "JSON valid but DNSs/SearchDomains not found (buffer \(json.count) bytes)"
            return []
        }
        return [ExtractedTunnel(
            dnsServers: Array(Set(servers)),
            searchDomains: Array(Set(domains))
        )]
    }

    /// Walks the JSON tree and collects all string arrays named "DNSs"
    /// and "SearchDomains", regardless of nesting depth.
    private func collectDNS(from value: Any, servers: inout [String], domains: inout [String]) {
        if let dict = value as? [String: Any] {
            if let s = dict["DNSs"] as? [String]          { servers.append(contentsOf: s) }
            if let d = dict["SearchDomains"] as? [String] { domains.append(contentsOf: d) }
            for v in dict.values { collectDNS(from: v, servers: &servers, domains: &domains) }
        } else if let array = value as? [Any] {
            for item in array { collectDNS(from: item, servers: &servers, domains: &domains) }
        }
    }
}
