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
    private var capturing: Bool = false

    /// Strips the log prefix from a single line. Returns nil for lines we
    /// don't recognize as Debug output (e.g. Info/Warning lines).
    private func strip(_ raw: String) -> String? {
        // Format: "[HH:MM:SS] Mon DD HH:MM:SS.mmm Level<spaces>payload"
        // We don't care about the prefix details — split off the level word
        // ("Debug", "Info", etc.) and take everything after the trailing
        // whitespace. If "Debug" isn't present, this isn't a payload line.
        guard let levelRange = raw.range(of: " Debug") ?? raw.range(of: "\tDebug") else {
            return nil
        }
        let after = raw[levelRange.upperBound...]
        // Drop leading spaces/tabs that ngate uses for indentation
        return String(String(after).drop(while: { $0 == " " || $0 == "\t" }))
    }

    /// Feed one log line. When this method returns a non-empty array,
    /// a complete response was found and parsed; otherwise more lines are
    /// needed (or the line is ignored).
    func feed(_ line: String) -> [ExtractedTunnel] {
        guard let payload = strip(line) else { return [] }

        // Detect start of JSON object
        if !capturing {
            if payload.first == "{" {
                capturing = true
                buffer = ""
                depth = 0
            } else {
                return []
            }
        }

        // Track brace depth across the line — strings might contain `{`/`}`
        // but ngate's response is well-formed JSON so simple counting works.
        // Cookie strings ("nginxauth=*** hidden cookie ***") are sanitized
        // before they get here (we only see them in Debug HTTP body, not in
        // the JSON object that starts with {).
        var inString = false
        var escape = false
        for char in payload {
            if escape { escape = false; continue }
            if char == "\\" { escape = true; continue }
            if char == "\"" { inString.toggle() }
            if inString { continue }
            if char == "{" { depth += 1 }
            if char == "}" { depth -= 1 }
        }

        buffer.append(payload)
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

    /// Decodes a complete JSON blob. Tolerates missing fields — emits one
    /// `ExtractedTunnel` per IPTunnels[] entry that has a usable DNSs list.
    private func parse(_ json: String) -> [ExtractedTunnel] {
        guard let data = json.data(using: .utf8) else { return [] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        guard let tunnels = obj["IPTunnels"] as? [[String: Any]] else { return [] }

        return tunnels.compactMap { tunnel in
            // DNSs may be missing or empty — caller filters those out
            // through TunnelDNSConfig.isValid.
            let servers = (tunnel["DNSs"] as? [String]) ?? []
            let domains = (tunnel["SearchDomains"] as? [String]) ?? []
            // Drop tunnels that contributed neither resolvers nor zones —
            // there's no useful info in them.
            guard !servers.isEmpty || !domains.isEmpty else { return nil }
            return ExtractedTunnel(dnsServers: servers, searchDomains: domains)
        }
    }
}
