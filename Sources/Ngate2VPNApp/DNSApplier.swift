import Foundation
import Combine
import OSLog
import CryptoKit

// MARK: - Constants

/// Where the privileged helper script lives once installed.
private let kHelperScriptPath = "/usr/local/libexec/ngate2vpn-dns-apply.sh"

/// Sudoers drop-in file that grants the current user NOPASSWD access to the
/// helper above — and only to the helper above.
private let kSudoersPath = "/etc/sudoers.d/ngate2vpn"

// MARK: - DNS Helper installation states

enum DNSHelperState: Equatable {
    /// Not yet activated — no /etc/resolver/ files created.
    case uninstalled
    /// Currently writing files (running a privileged command).
    case applying
    /// Active — split-DNS files are installed under /etc/resolver/ and
    /// the sudoers helper is in place for silent updates.
    case installed
    /// Something went wrong. The user typically needs to reinstall.
    case error(String)
}

// MARK: - DNSApplier

/// Implements DNS Helper using macOS's native `/etc/resolver/<domain>` files.
///
/// **Privilege model.** Writing to `/etc/resolver/` requires root. Without
/// an Apple Developer ID we can't ship a notarized helper daemon
/// (SMAppService and direct `launchctl bootstrap` both reject ad-hoc-signed
/// binaries on macOS Sequoia/Tahoe). Instead we install a tiny shell helper
/// at `/usr/local/libexec/ngate2vpn-dns-apply.sh` plus a single `sudoers.d`
/// rule granting the current user NOPASSWD access **to that one script**.
/// Result: one password prompt at install time, then every subsequent
/// policy change is silent.
///
/// **Security.**
///   - sudoers rule whitelists exactly one absolute path; `visudo -cf`
///     validates the rule before it's installed.
///   - helper script is owned by root:wheel with mode 700 — non-root users
///     cannot tamper with it.
///   - helper script validates every input token with strict regexes
///     (lowercase letters / digits / `.` / `-` for domains; hex digits
///     plus `.` and `:` for IPs). It rejects shell metacharacters.
///   - all data flows over stdin via a fixed line-protocol with named
///     verbs — there is no `eval` or arbitrary command surface.
@MainActor
final class DNSApplier: ObservableObject {

    @Published private(set) var state: DNSHelperState = .uninstalled

    /// Diagnostic callback — AppState routes these into the Journal as
    /// app-wide `[SYSTEM]` events.
    var onDiagnostic: ((String, SystemLogLevel) -> Void)?

    var isInstalled: Bool {
        if case .installed = state { return true }
        return false
    }

    private let policyController: DNSPolicyController
    private var policySubscription: AnyCancellable?
    private var policyApplyInProgress = false
    private var pendingPolicy: ResolvedDNSPolicy?
    private let logger = Logger(subsystem: "com.ngate2vpn.dns", category: "applier")

    /// Domains we wrote on disk (sanitized form). Persisted to the marker
    /// file so we can clean up after a graceful quit AND know what to wipe
    /// after a crash on next launch.
    private var writtenDomains: Set<String> = []

    /// Exact resolver contents we believe are on disk, keyed by sanitized
    /// match domain. This closes a subtle drift case: a tunnel can reconnect
    /// with the same SearchDomains but different DNSs, and comparing only the
    /// domain set would miss that update.
    private var writtenScopedResolvers: [String: [String]] = [:]

    /// True iff we created `/etc/resolver/.` (the catch-all default override).
    private var defaultInstalled: Bool = false

    /// Exact resolver contents written to `/etc/resolver/.`, if any.
    private var writtenDefaultResolver: [String]?

    /// Marker / state file. Existence implies a previous session installed
    /// the helper. JSON content tracks which `/etc/resolver/` files belong
    /// to us so they can be cleaned up reliably across quits and crashes.
    private let installMarkerURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Ngate2VPN", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dns-helper-active.flag")
    }()

    /// On-disk representation of DNS files we own.
    private struct PersistedState: Codable {
        var writtenDomains: [String]
        var defaultInstalled: Bool
        /// Added after the original marker format. Optional so existing
        /// installs decode cleanly; old markers simply force the next policy
        /// application to rewrite matching domains once.
        var writtenScopedResolvers: [String: [String]]?
        var writtenDefaultResolver: [String]?
        /// Legacy field from versions that tied helper validity to the app
        /// bundle inode. Kept only for decode compatibility; we no longer use
        /// it because it can force unnecessary reinstalls after rebuilds,
        /// app replacement, or other bundle metadata changes while the helper
        /// itself is still present and usable.
        var bundleFingerprint: String?
        /// Hash of helperScriptSource that was current when the privileged
        /// helper was installed/adopted. This is the reinstall trigger we
        /// actually need: app bundle replacement with identical helper code is
        /// fine, but changed helper code must ask the user to reinstall.
        var helperSourceHash: String?
    }

    /// Loads previous-session state from the marker file, if any. Returns
    /// `nil` when the file is absent or unreadable — caller treats that
    /// the same as "not installed".
    private static func loadPersistedState(from url: URL) -> PersistedState? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty,
              let decoded = try? JSONDecoder().decode(PersistedState.self, from: data)
        else {
            return nil
        }
        return decoded
    }

    /// Writes the current DNS helper state to the marker file so the next
    /// launch can resume cleanly. Called after every install / apply /
    /// uninstall that mutates state.
    private func savePersistedState() {
        let snapshot = PersistedState(
            writtenDomains: Array(writtenDomains),
            defaultInstalled: defaultInstalled,
            writtenScopedResolvers: writtenScopedResolvers,
            writtenDefaultResolver: writtenDefaultResolver,
            bundleFingerprint: nil,
            helperSourceHash: Self.currentHelperSourceHash
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: installMarkerURL, options: [.atomic])
    }

    private static var currentHelperSourceHash: String {
        let digest = SHA256.hash(data: Data(helperScriptSource.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    init(policyController: DNSPolicyController) {
        self.policyController = policyController

        // Resume only when BOTH privileged files are still in place. If
        // either is gone (manually deleted, OS reset, …) we treat the
        // helper as uninstalled and the user reinstalls.
        let helperPresent = FileManager.default.fileExists(atPath: kHelperScriptPath)
        let sudoersPresent = FileManager.default.fileExists(atPath: kSudoersPath)

        guard helperPresent && sudoersPresent,
              let persisted = Self.loadPersistedState(from: installMarkerURL)
        else {
            return
        }

        writtenDomains = Set(persisted.writtenDomains)
        defaultInstalled = persisted.defaultInstalled
        writtenScopedResolvers = persisted.writtenScopedResolvers ?? [:]
        writtenDefaultResolver = persisted.writtenDefaultResolver

        if let installedHash = persisted.helperSourceHash,
           installedHash != Self.currentHelperSourceHash {
            state = .error("DNS Helper code changed. Please reinstall to update the privileged helper.")
            return
        }

        state = .installed
        if persisted.helperSourceHash == nil {
            savePersistedState()
        }

        // Auto-cleanup any leftover routes from a hard quit / crash where
        // applicationShouldTerminate didn't get to run. We compute the
        // diff between "what we wrote last time" and "what the policy
        // wants now" and apply it — same code path as a normal change,
        // no extra prompts.
        subscribeToPolicy()
        Task { self.enqueuePolicyApplication(self.policyController.policy) }
    }

    private func diag(_ message: String, level: SystemLogLevel = .info) {
        logger.info("\(message, privacy: .public)")
        onDiagnostic?(message, level)
    }

    // MARK: - Public API

    /// Install. Writes the helper + sudoers rule via a single osascript
    /// "do shell script with administrator privileges" — one password
    /// prompt total, the only one the user will see for normal use.
    ///
    /// The privileged shell creates both files itself from base64 payloads
    /// embedded below. We deliberately do not stage helper/sudoers files in
    /// a user-writable directory and then ask root to move them into place:
    /// that pattern opens a time-of-check/time-of-use window where the staged
    /// files could be swapped before the privileged move.
    func install() async {
        diag("[SYSTEM] DNS Helper: install requested")
        state = .applying

        let user = NSUserName()
        guard isUsernameSafe(user) else {
            state = .error("Username '\(user)' contains characters that are unsafe for sudoers")
            diag("[SYSTEM] DNS Helper install FAILED: unsafe username", level: .error)
            return
        }

        let sudoersBody = "\(user) ALL=(root) NOPASSWD: \(kHelperScriptPath)\n"
        guard let helperPayload = helperScriptSource.data(using: .utf8)?.base64EncodedString(),
              let sudoersPayload = sudoersBody.data(using: .utf8)?.base64EncodedString()
        else {
            state = .error("Failed to prepare installer payloads")
            diag("[SYSTEM] DNS Helper install FAILED: payload encoding error", level: .error)
            return
        }

        // One privileged osascript invocation. set -e ensures we abort on
        // the first failure and `visudo -cf` validates the sudoers rule
        // before we move it into /etc/sudoers.d/.
        let installScript = """
        set -e
        /bin/mkdir -p /usr/local/libexec
        /bin/mkdir -p /etc/resolver
        /bin/chmod 755 /etc/resolver

        helper_tmp="$(/usr/bin/mktemp /usr/local/libexec/ngate2vpn-dns-apply.XXXXXX)"
        sudoers_tmp="$(/usr/bin/mktemp /etc/sudoers.d/ngate2vpn.XXXXXX)"
        cleanup() {
            /bin/rm -f "$helper_tmp" "$sudoers_tmp"
        }
        trap cleanup EXIT

        /bin/echo '\(helperPayload)' | /usr/bin/base64 -D > "$helper_tmp"
        /bin/echo '\(sudoersPayload)' | /usr/bin/base64 -D > "$sudoers_tmp"

        /usr/sbin/chown root:wheel "$helper_tmp"
        /bin/chmod 700 "$helper_tmp"
        /usr/sbin/visudo -cf "$sudoers_tmp" >/dev/null
        /usr/sbin/chown root:wheel "$sudoers_tmp"
        /bin/chmod 440 "$sudoers_tmp"

        /bin/mv -f "$helper_tmp" '\(kHelperScriptPath)'
        /bin/mv -f "$sudoers_tmp" '\(kSudoersPath)'
        trap - EXIT
        """

        do {
            try await runWithPasswordPrompt(installScript)
        } catch {
            state = .error(describe(error))
            diag("[SYSTEM] DNS Helper install FAILED: \(describe(error))", level: .error)
            return
        }

        // From here onwards we need no further password — apply silently.
        FileManager.default.createFile(atPath: installMarkerURL.path, contents: nil)
        subscribeToPolicy()

        // Write the initial policy to disk through the helper.
        let initialPolicy = policyController.policy
        let initialScopedResolvers = scopedResolverMap(for: initialPolicy)
        let initialDomains = Set(initialScopedResolvers.keys)
        let initialDefaultResolver = normalizedDefaultResolver(for: initialPolicy)

        do {
            let stdin = buildLineProtocol(scopedResolvers: initialPolicy.scopedResolvers,
                                          defaultResolver: initialPolicy.defaultResolver,
                                          removeDomains: [],
                                          removeDefault: false)
            if !stdin.isEmpty {
                try await runHelper(stdin: stdin)
            }
            writtenDomains = initialDomains
            writtenScopedResolvers = initialScopedResolvers
            defaultInstalled = initialDefaultResolver != nil
            writtenDefaultResolver = initialDefaultResolver
            savePersistedState()
            state = .installed
            diag("[SYSTEM] DNS Helper: installed (\(writtenDomains.count) domains)")
        } catch {
            // Privileged install succeeded but initial apply failed —
            // unusual. Still mark as installed; next policy change will
            // retry, and apply errors surface there.
            savePersistedState()
            state = .installed
            diag("[SYSTEM] DNS Helper: installed but initial apply errored: \(describe(error))", level: .warning)
        }
    }

    /// Uninstall. Goes through the helper itself (no password prompt)
    /// because it has its own UNINSTALL_SELF verb that wipes resolver
    /// files, the sudoers rule, and finally itself.
    func uninstall() async {
        diag("[SYSTEM] DNS Helper: uninstall requested")
        state = .applying
        policySubscription?.cancel()
        policySubscription = nil

        // If default DNS was overridden via networksetup, restore it first.
        // Then send UNINSTALL_SELF to remove per-domain resolver files,
        // drop the sudoers rule, and self-delete the helper script.
        var stdin = ""
        if defaultInstalled {
            stdin += "REMOVE_DEFAULT\n"
        }
        let domainArgs = writtenDomains.sorted().joined(separator: " ")
        stdin += "UNINSTALL_SELF \(domainArgs)\n"

        do {
            try await runHelper(stdin: stdin)
            diag("[SYSTEM] DNS Helper: uninstalled")
        } catch {
            // Even on failure, clear local state — user clearly wants
            // this off. They can manually remove leftover files.
            diag("[SYSTEM] DNS Helper: uninstall errored (\(describe(error))) — clearing local state anyway", level: .warning)
        }

        writtenDomains.removeAll()
        writtenScopedResolvers.removeAll()
        defaultInstalled = false
        writtenDefaultResolver = nil
        try? FileManager.default.removeItem(at: installMarkerURL)
        state = .uninstalled
    }

    /// Re-applies the current policy without checking the in-memory cache.
    /// Call when a tunnel transitions to `.running` so that resolver files
    /// deleted externally (e.g. by macOS on wake from a long sleep while the
    /// tunnel process survived) are recreated even if the policy hasn't changed.
    func reapplyCurrentPolicy() {
        guard isInstalled else { return }
        // Trigger apply() with the current policy. If writtenScopedResolvers already
        // matches the policy, apply() does the file-existence check and skips the
        // shell invocation when files are present — so this is a no-op in the normal
        // case. When files were externally deleted (sleep/wake), the check detects the
        // gap and rewrites them.
        // Do NOT clear writtenScopedResolvers here: that would race with a concurrent
        // subscription-driven apply() that already wrote the files, causing a second
        // redundant write and a duplicate "policy applied" log entry.
        enqueuePolicyApplication(policyController.policy)
    }

    /// Removes every `/etc/resolver/` file we ever wrote without un-
    /// installing the helper itself. Use this from `applicationShould-
    /// Terminate` so the app leaves the user's DNS state clean when they
    /// quit. Idempotent — does nothing if we never wrote anything, or
    /// if the helper isn't installed.
    ///
    /// Returns when the cleanup is finished. Marker file is updated so
    /// the next launch sees an empty `writtenDomains` and won't try to
    /// re-clean.
    func wipeAllRoutes() async {
        guard isInstalled else { return }
        guard !writtenDomains.isEmpty || defaultInstalled else { return }

        let stdin = buildLineProtocol(scopedResolvers: [],
                                      defaultResolver: nil,
                                      removeDomains: writtenDomains,
                                      removeDefault: defaultInstalled)
        if !stdin.isEmpty {
            try? await runHelper(stdin: stdin)
        }
        writtenDomains.removeAll()
        writtenScopedResolvers.removeAll()
        defaultInstalled = false
        writtenDefaultResolver = nil
        savePersistedState()
        diag("[SYSTEM] DNS Helper: routes wiped on quit")
    }

    // MARK: - Policy application

    private func subscribeToPolicy() {
        policySubscription?.cancel()
        policySubscription = policyController.$policy
            .receive(on: DispatchQueue.main)
            .sink { [weak self] policy in
                self?.enqueuePolicyApplication(policy)
            }
    }

    /// Policy changes can arrive faster than the privileged helper returns.
    /// Because `await runHelper(...)` yields the MainActor, multiple `apply`
    /// calls could otherwise overlap and finish out of order, leaving
    /// `writtenDomains` / resolver files stale. This small coalescing loop
    /// guarantees one helper run at a time and always applies the latest
    /// pending policy after the current run completes.
    private func enqueuePolicyApplication(_ policy: ResolvedDNSPolicy) {
        if policyApplyInProgress {
            pendingPolicy = policy
            return
        }

        policyApplyInProgress = true
        Task { @MainActor [weak self] in
            await self?.drainPolicyApplications(startingWith: policy)
        }
    }

    private func drainPolicyApplications(startingWith initialPolicy: ResolvedDNSPolicy) async {
        var policy = initialPolicy
        while true {
            await apply(policy)
            if let next = pendingPolicy {
                pendingPolicy = nil
                policy = next
                continue
            }
            policyApplyInProgress = false
            return
        }
    }

    /// Diff the desired policy against on-disk state, build a line-protocol
    /// payload, and feed it to the helper. Idempotent; if nothing changed
    /// we don't even invoke `sudo`.
    private func apply(_ policy: ResolvedDNSPolicy) async {
        guard isInstalled else { return }

        let newScopedResolvers = scopedResolverMap(for: policy)
        let newDomains = Set(newScopedResolvers.keys)
        let toRemove = writtenDomains.subtracting(newDomains)
        let newDefaultResolver = normalizedDefaultResolver(for: policy)
        let newDefault = newDefaultResolver != nil
        let removeDefault = defaultInstalled && !newDefault

        if newScopedResolvers == writtenScopedResolvers &&
            newDefaultResolver == writtenDefaultResolver {
            // The in-memory record matches the desired state, but the files on
            // disk may have been removed externally — macOS can wipe /etc/resolver/
            // on wake-from-sleep, network interface changes, or system updates —
            // while our writtenScopedResolvers still thinks they exist. Skip the
            // re-apply only when the files are actually present on disk.
            // Per-domain resolver files may have been removed externally (sleep/wake,
            // system update). Only skip re-apply when the files are actually on disk.
            // Note: the default resolver is networksetup-based, not a file — we trust
            // writtenDefaultResolver as ground truth for that case.
            let filesIntact = newScopedResolvers.keys.allSatisfy {
                FileManager.default.fileExists(atPath: "/etc/resolver/\($0)")
            }
            if filesIntact { return }
        }

        let stdin = buildLineProtocol(scopedResolvers: policy.scopedResolvers,
                                      defaultResolver: policy.defaultResolver,
                                      removeDomains: toRemove,
                                      removeDefault: removeDefault)
        guard !stdin.isEmpty else {
            return
        }

        do {
            try await runHelper(stdin: stdin)
            writtenDomains = newDomains
            writtenScopedResolvers = newScopedResolvers
            defaultInstalled = newDefault
            writtenDefaultResolver = newDefaultResolver
            savePersistedState()
            diag("[SYSTEM] DNS Helper: policy applied (\(newDomains.count) domains, default=\(newDefault))")
        } catch {
            diag("[SYSTEM] DNS Helper apply FAILED: \(describe(error))", level: .error)
            // sudoers rule may have been removed externally; best to
            // surface this as an error so the user reinstalls.
            if isMissingSudoersRule(error) {
                state = .error("Helper privilege rule missing — please reinstall")
            }
        }
    }

    // MARK: - Line-protocol generation

    /// Normalized form of the scoped resolver files we intend to have on
    /// disk: `/etc/resolver/<domain>` => `nameserver ...` values. Must stay
    /// in lock-step with `buildLineProtocol`, because this is what we diff
    /// against the last successful helper run.
    private func scopedResolverMap(for policy: ResolvedDNSPolicy) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for scoped in policy.scopedResolvers {
            let ips = normalizedIPs(scoped.dnsServers)
            guard !ips.isEmpty else { continue }
            for domain in scoped.matchDomains {
                let safe = sanitizeDomain(domain)
                guard !safe.isEmpty else { continue }
                result[safe] = ips
            }
        }
        return result
    }

    private func normalizedDefaultResolver(for policy: ResolvedDNSPolicy) -> [String]? {
        guard let defaults = policy.defaultResolver else { return nil }
        let ips = normalizedIPs(defaults)
        return ips.isEmpty ? nil : ips
    }

    private func normalizedIPs(_ raw: [String]) -> [String] {
        raw
            .map(sanitizeIP)
            .filter { !$0.isEmpty }
    }

    /// Builds the helper-protocol payload for the given diff. Each line
    /// is `VERB arg1 arg2 …`. All values are pre-sanitized.
    private func buildLineProtocol(scopedResolvers: [ResolvedDNSPolicy.Scoped],
                                   defaultResolver: [String]?,
                                   removeDomains: Set<String>,
                                   removeDefault: Bool) -> String {
        var lines: [String] = []

        // Removals first, so that swapping a domain's servers happens in
        // a single helper run without races.
        for domain in removeDomains.sorted() {
            lines.append("REMOVE \(domain)")
        }
        if removeDefault {
            lines.append("REMOVE_DEFAULT")
        }

        // Writes.
        for scoped in scopedResolvers {
            let ips = normalizedIPs(scoped.dnsServers)
            guard !ips.isEmpty else { continue }
            for domain in scoped.matchDomains {
                let safe = sanitizeDomain(domain)
                guard !safe.isEmpty else { continue }
                lines.append("WRITE \(safe) " + ips.joined(separator: " "))
            }
        }
        if let defaults = defaultResolver, !defaults.isEmpty {
            let ips = normalizedIPs(defaults)
            if !ips.isEmpty {
                lines.append("WRITE_DEFAULT " + ips.joined(separator: " "))
            }
        }

        guard !lines.isEmpty else { return "" }
        lines.append("FLUSH")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Sanitization

    private func sanitizeDomain(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return String(raw.lowercased().filter { allowed.contains($0) })
    }

    private func sanitizeIP(_ raw: String) -> String {
        let allowed = Set("0123456789abcdefABCDEF.:")
        return String(raw.filter { allowed.contains($0) })
    }

    private func isUsernameSafe(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 32 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return name.allSatisfy { allowed.contains($0) }
    }

    // MARK: - Privileged execution

    /// Runs `script` as root via `osascript "do shell script ... with
    /// administrator privileges"`. Used **only** for install — every
    /// other operation goes through the NOPASSWD helper.
    private func runWithPasswordPrompt(_ script: String) async throws {
        let forApple = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        do shell script "\(forApple)" with administrator privileges
        """
        try await Task.detached {
            let process = Process()
            process.launchPath = "/usr/bin/osascript"
            process.arguments = ["-e", appleScript]
            let stderrPipe = Pipe()
            let stdoutPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = stdoutPipe
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let raw = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                let msg = (String(data: raw, encoding: .utf8) ?? "exit \(process.terminationStatus)")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw DNSApplierError.privilegedCommandFailed(msg)
            }
        }.value
    }

    /// Runs the helper non-interactively via `sudo -n`. NEVER prompts the
    /// user — the sudoers entry guarantees NOPASSWD on this exact path.
    /// If sudo asks for a password (means our sudoers rule is gone) it
    /// fails immediately rather than blocking the UI.
    private func runHelper(stdin: String) async throws {
        try await Task.detached {
            let process = Process()
            process.launchPath = "/usr/bin/sudo"
            // -n: non-interactive. Fail fast if password is somehow needed.
            process.arguments = ["-n", kHelperScriptPath]

            let stdinPipe = Pipe()
            let stderrPipe = Pipe()
            let stdoutPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardError = stderrPipe
            process.standardOutput = stdoutPipe
            try process.run()
            try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? stdinPipe.fileHandleForWriting.close()

            // 10-second watchdog: if the helper hangs (e.g. mDNSResponder
            // doesn't respond to SIGHUP), terminate the process so we don't
            // block policyApplyInProgress forever.
            let watchdog = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
            process.waitUntilExit()
            watchdog.cancel()

            if process.terminationStatus != 0 {
                let raw = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                let msg = (String(data: raw, encoding: .utf8) ?? "exit \(process.terminationStatus)")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = msg.lowercased()
                if lower.contains("password is required") || lower.contains("a password is required") {
                    throw DNSApplierError.sudoersRuleMissing
                }
                throw DNSApplierError.privilegedCommandFailed(msg.isEmpty
                                                              ? "exit \(process.terminationStatus)"
                                                              : msg)
            }
        }.value
    }

    private func isMissingSudoersRule(_ error: Error) -> Bool {
        if case DNSApplierError.sudoersRuleMissing = error { return true }
        return false
    }

    private func describe(_ error: Error) -> String {
        if let e = error as? DNSApplierError {
            switch e {
            case .privilegedCommandFailed(let m):
                if m.contains("-128") || m.lowercased().contains("user canceled") {
                    return "Authorization cancelled by user"
                }
                return "Privileged command failed: \(m)"
            case .sudoersRuleMissing:
                return "Privilege rule missing — please reinstall the DNS Helper"
            }
        }
        return error.localizedDescription
    }
}

enum DNSApplierError: Error {
    case privilegedCommandFailed(String)
    case sudoersRuleMissing
}

// MARK: - Helper script source

/// Bash source of the privileged helper installed at `kHelperScriptPath`.
///
/// **Protocol** — reads stdin, one verb per line:
///
///     WRITE <domain> <ip> [<ip>…]   create /etc/resolver/<domain>
///     REMOVE <domain>               delete /etc/resolver/<domain>
///     WRITE_DEFAULT <ip> [<ip>…]    create /etc/resolver/. (catch-all)
///     REMOVE_DEFAULT                delete /etc/resolver/.
///     FLUSH                         dscacheutil + mDNSResponder HUP
///     UNINSTALL_SELF [<domain>…]    cleanup, then rm sudoers + self
///
/// **Hardening** — every domain matches `^[a-z0-9.-]+$` plus `..` and
/// leading-dot rejections; every IP matches `^[0-9a-fA-F.:]+$`; unknown
/// verbs cause exit 99. The script does not invoke any user-supplied
/// command; values only ever appear inside `nameserver …` lines and as
/// quoted file paths.
private let helperScriptSource: String = #"""
#!/bin/bash
# Ngate2VPN DNS Helper — privileged worker.
# Owned root:wheel, mode 700, callable only via the matching sudoers.d rule.

set -euo pipefail

DOMAIN_RE='^[a-z0-9.-]+$'
IP_RE='^[0-9a-fA-F.:]+$'

valid_domain() {
    [[ "$1" =~ $DOMAIN_RE ]] || return 1
    [[ "$1" != *..* ]]       || return 1
    [[ "$1" != .* ]]         || return 1
    [[ "${#1}" -le 253 ]]    || return 1
    return 0
}

valid_ip() {
    [[ "$1" =~ $IP_RE ]]     || return 1
    [[ "${#1}" -le 45 ]]     || return 1
    return 0
}

flush_dns() {
    /usr/bin/dscacheutil -flushcache 2>/dev/null || true
    /usr/bin/killall -HUP mDNSResponder 2>/dev/null || true
}

mkdir -p /etc/resolver
chmod 755 /etc/resolver

while IFS= read -r line; do
    read -ra tok <<< "$line"
    [[ ${#tok[@]} -eq 0 ]] && continue

    case "${tok[0]}" in
        WRITE)
            domain="${tok[1]:-}"
            valid_domain "$domain" || { echo "invalid domain: $domain" >&2; exit 11; }
            tmp="/etc/resolver/${domain}.tmp"
            : > "$tmp"
            for ip in "${tok[@]:2}"; do
                valid_ip "$ip" || { echo "invalid ip: $ip" >&2; rm -f "$tmp"; exit 12; }
                printf 'nameserver %s\n' "$ip" >> "$tmp"
            done
            if [[ -s "$tmp" ]]; then
                chmod 644 "$tmp"
                mv -f "$tmp" "/etc/resolver/${domain}"
            else
                rm -f "$tmp"
            fi
            ;;
        REMOVE)
            domain="${tok[1]:-}"
            valid_domain "$domain" || { echo "invalid domain: $domain" >&2; exit 14; }
            rm -f "/etc/resolver/${domain}"
            ;;
        WRITE_DEFAULT)
            # macOS resolver(5): the "default" DNS client is the system primary
            # (resolv.conf / Network prefs), not a file in /etc/resolver/.
            # A file named "." cannot be created on HFS+/APFS — the kernel always
            # resolves "." to the directory. Override the default resolver by
            # setting DNS servers on every active network service instead.
            for ip in "${tok[@]:1}"; do
                valid_ip "$ip" || { echo "invalid ip: $ip" >&2; exit 15; }
            done
            while IFS= read -r service; do
                [[ -z "$service" ]] && continue
                [[ "$service" == \** ]] && continue   # disabled service
                /usr/sbin/networksetup -setdnsservers "$service" "${tok[@]:1}" 2>/dev/null || true
            done < <(/usr/sbin/networksetup -listallnetworkservices 2>/dev/null | /usr/bin/tail -n +2)
            ;;
        REMOVE_DEFAULT)
            # Restore DHCP-assigned DNS on every active network service.
            while IFS= read -r service; do
                [[ -z "$service" ]] && continue
                [[ "$service" == \** ]] && continue
                /usr/sbin/networksetup -setdnsservers "$service" "Empty" 2>/dev/null || true
            done < <(/usr/sbin/networksetup -listallnetworkservices 2>/dev/null | /usr/bin/tail -n +2)
            ;;
        FLUSH)
            flush_dns
            ;;
        UNINSTALL_SELF)
            for d in "${tok[@]:1}"; do
                valid_domain "$d" || continue
                rm -f "/etc/resolver/$d"
            done
            flush_dns
            # Drop privilege rule first — once gone we can't re-enter as root.
            rm -f /etc/sudoers.d/ngate2vpn
            # Self-delete. mac OS lets us unlink the running script; the
            # process keeps its open file handle until exit.
            rm -f "$0"
            ;;
        *)
            echo "unknown verb: ${tok[0]}" >&2
            exit 99
            ;;
    esac
done

exit 0
"""#
