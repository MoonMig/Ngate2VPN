# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build debug binary
swift build

# Build release binary
swift build -c release

# Build the .app bundle (release by default)
./build-app.sh
./build-app.sh debug   # debug variant

# Run tests
swift test

# Run a single test class
swift test --filter NgateOutputParserTests
swift test --filter DNSPolicyControllerTests
```

The built app lands at `build/Ngate2VPN.app`. Open with `open build/Ngate2VPN.app`.

## Architecture

This is a macOS-only SwiftUI app (macOS 13+) built as a Swift Package (no Xcode project file, no external dependencies). The single executable target is `Ngate2VPNApp`.

### Data flow

```
AppState (@MainActor)
  ├── tunnels: [TunnelConfiguration]       ← persisted to UserDefaults via TunnelPersistence
  ├── runtime: [UUID: TunnelRuntimeState]  ← in-memory only
  ├── TunnelProcessManager                 ← spawns/kills ngateconsoleclient processes
  ├── KeychainSecretStore                  ← PIN / password, never in UserDefaults
  ├── DNSPolicyController                  ← aggregates DNS configs from all tunnels
  └── DNSApplier                           ← applies policy to /etc/resolver/ via sudoers helper
```

`AppState` is the single source of truth, always accessed on the main actor. UI reads from it via `@EnvironmentObject`. The three-tab UI (`Home`, `Journal`, `Settings`) lives entirely in `ContentView.swift`.

### Concurrency model

- `AppState` — `@MainActor`, all tunnel state mutations happen here
- `FileLogger` — Swift `actor`, serialises async disk writes per tunnel
- `ProcessRunner` / `TunnelProcessManager` — per-tunnel `DispatchQueue`s for stdout/stderr; callbacks hop back to `@MainActor` via `Task { @MainActor in … }`
- `DNSApplier` — `@MainActor` for state, `Task.detached` for shell invocations (`sudo`, `osascript`)

### Credential security

`TunnelConfiguration` stores credentials in-memory during profile editing. Before any persistence (`TunnelPersistence.save`) or connection start, `sanitizedConfiguration(_:)` strips `pinCode` and `password` to empty strings. The actual secrets live only in `KeychainSecretStore`. At connection time `resolvedConfigurationForStart` re-injects them from Keychain.

### Process management

Each tunnel runs one `ngateconsoleclient` process, always launched with `-vvvv` (verbose). The verbose output is necessary: `NgateGatewayResponseParser` scans the `Debug` log lines for the JSON block containing `IPTunnels`/`DNSs`/`SearchDomains`. Without `-vvvv` this block is not printed.

`AppState` contains a watchdog loop that runs every 5 s. On retryable errors it restarts the process with exponential backoff (base 5 s, cap 15 min, max 8 consecutive failures before pausing). The `TunnelError.isRetryable` property is the authoritative classification.

### DNS Helper

Without an Apple Developer ID, neither `SMAppService` daemons nor `NEDNSSettings` are available (ad-hoc-signed binaries are rejected by macOS Sequoia/Tahoe). Instead:

1. **Install** (one password prompt): embeds a bash helper script at `/usr/local/libexec/ngate2vpn-dns-apply.sh` plus a `sudoers.d` rule granting the current user NOPASSWD access to exactly that script.
2. **Apply/Wipe** (silent): sends a line-protocol over stdin to `sudo -n <helper>`. Verbs: `WRITE`, `REMOVE`, `WRITE_DEFAULT`, `REMOVE_DEFAULT`, `FLUSH`, `UNINSTALL_SELF`.

The helper script source is embedded as a Swift string literal at the bottom of `DNSApplier.swift`. If the source changes, the app detects the hash mismatch on next launch and asks the user to reinstall.

State is persisted to `~/Library/Application Support/Ngate2VPN/dns-helper-active.flag` (JSON) so stale `/etc/resolver/` files from a crash are cleaned up on the next launch.

#### Per-domain resolvers vs. the default resolver — two different mechanisms

These are NOT the same and must not be conflated:

- **Per-domain (split-DNS)** — `WRITE`/`REMOVE` create/delete files under `/etc/resolver/<domain>` containing `nameserver <ip>` lines. This is the standard macOS `resolver(5)` mechanism.
- **Default resolver** — `WRITE_DEFAULT`/`REMOVE_DEFAULT` operate via `networksetup -setdnsservers` on every active network service. There is **no** `/etc/resolver/.` file: per `resolver(5)`, the default DNS is the system primary (resolv.conf / Network prefs), and a file literally named `.` cannot exist on HFS+/APFS (the kernel resolves `.` to the directory). An earlier implementation tried `mv tmp /etc/resolver/.` which silently produced a useless `..tmp` file — the default resolver never worked until this was rewritten. `REMOVE_DEFAULT` restores DHCP DNS via `networksetup -setdnsservers <service> "Empty"`. `uninstall()` sends `REMOVE_DEFAULT` before `UNINSTALL_SELF` when `defaultInstalled` so the user's DNS is restored on uninstall.

Note: `holdDefaultDNS` defaults to `true`, which means `WRITE_DEFAULT` is only ever emitted when the user explicitly turns it off in Settings.

#### runHelper timeout

`runHelper` wraps `Process.waitUntilExit()` with a 10-second `DispatchWorkItem` watchdog that calls `process.terminate()`. Without it, a hung helper (e.g. `killall -HUP mDNSResponder` not returning) would leave `policyApplyInProgress == true` forever, silently dropping all subsequent DNS policy changes into `pendingPolicy`.

#### DNS Helper initialization

`dnsApplier` is a `lazy var` on `AppState` but is **force-initialized in `AppState.init()`** via `_ = dnsApplier`. Without this, the helper would only come alive when the Settings tab is visited, leaving DNS inoperable after a restart if the user never opens Settings.

`holdDefaultDNS` is also synced from UserDefaults in `AppState.init()` before the applier is created, so the correct value is used on first policy application.

#### DNS Helper apply() resilience

`apply()` in `DNSApplier` short-circuits when `writtenScopedResolvers == newScopedResolvers`. Before returning early it now **checks that the per-domain files actually exist on disk** (`FileManager.fileExists` for each `/etc/resolver/<domain>`). This handles the case where macOS deletes `/etc/resolver/` files during sleep/wake or network interface changes without the policy changing. The default resolver is networksetup-based (not a file), so `writtenDefaultResolver` is trusted as ground truth for it — there is no file-existence check for the default.

`reapplyCurrentPolicy()` is called from `AppState.transitionState` whenever a tunnel transitions **into** `.running` (guarded by `stateChanged == true`). This ensures files are recreated even when the tunnel process survived a sleep cycle and the policy never changed. Importantly, `reapplyCurrentPolicy()` does **not** clear `writtenScopedResolvers` — that would race with the subscription-driven apply and produce duplicate "policy applied" log entries.

### System log format

`[SYSTEM]` events are formatted as:
```
dd.MM.yyyy HH:mm:ss.SSS [SYSTEM] Level        [TunnelName] message   ← tunnel-specific
dd.MM.yyyy HH:mm:ss.SSS [SYSTEM] Level        message                ← app-wide (DNS Helper etc.)
```

Level words are padded with spaces to 8 characters (width of `"Critical"`) so all messages align in a column in the monospaced journal font. The `SystemLogLevel` enum (`Info`, `Warning`, `Error`, `Critical`) is defined at the top of `AppState.swift` and is shared with `DNSApplier.swift` via the same module. `DNSApplier.onDiagnostic` carries `(String, SystemLogLevel)`.

In the Journal renderer (`ContentView.swift / buildAttributedString`), `[SYSTEM]` lines use `nsColor(for: entry.text)` for body coloring — the same level-token detection as ngate lines. The `[SYSTEM] ` tag itself is always rendered in `systemTagColor` (orange).

### Log timestamps

All log lines use `dd.MM.yyyy` date prefix (not `yyyy-MM-dd`). The `timestampKey` function in `JournalView` rearranges the components back to `yyyy-MM-dd HH:mm:ss` for lexicographic sorting. The `lineCarriesFullTimestamp` detector checks for dots at positions 2 and 5 (not dashes at 4 and 7).

### Error classification

`NgateOutputParser.swift` is a pure, stateless enum with no dependencies on `AppState` or any actor. It maps lowercased ngate log lines to `TunnelError` values. Order matters — more specific patterns precede general ones. This is the most churn-prone code (ngate phrasing changes between versions) and is directly unit-tested.

Notable classification decisions:
- `"vpn session destroyed"` is intentionally **not** classified — it is a finalization event that fires after both retryable and non-retryable errors, and matching it would overwrite an earlier correct classification.
- `"unable to correctly logout from remote gate"` → `sessionRefreshFailed` (retryable): the server closed the session; watchdog reconnects silently.

### App lifecycle

The app uses a SwiftUI `@main` entry with `@NSApplicationDelegateAdaptor`. The real UI lives in an AppKit-managed `NSWindow` created by `AppDelegate`. A placeholder SwiftUI `Window` scene is required to satisfy the protocol but is immediately closed on launch.

`applicationShouldHandleReopen` returns **`false`** (not `true`). Returning `true` would tell AppKit to run its own scene-restoration logic, which reopens all previously closed SwiftUI Window scenes — including the placeholder. Since we handle reopen ourselves via `showMainWindow()`, returning `false` prevents the phantom placeholder window.

Quit is asynchronous (`applicationShouldTerminate` returns `.terminateLater`): DNS routes are wiped, tunnels terminated, credential temp files cleaned, then `NSApp.reply(toApplicationShouldTerminate: true)`. A 3 s watchdog forces the reply if cleanup stalls.

The About panel reads its version from `Bundle.main.infoDictionary["CFBundleShortVersionString"]` — do NOT hardcode it. The single source of truth for the version is `APP_VERSION` in `build-app.sh` (which writes it into the generated `Info.plist`). README status line and CHANGELOG must be bumped to match.

### UI conventions (ContentView.swift)

The whole UI is one file. Colors come from the `DS` design-token enum (each token has a dark/light pair via `NSColor(name:dynamicProvider:)`); corner radii are `DS.r` (10) and `DS.rL` (14). The status-bar (tray) icon is managed by `StatusIconManager` — it tints a `globe` SF Symbol; the disconnected state uses `NSColor.secondaryLabelColor` (NOT a fixed white/black) so it stays visible on both light and dark menu bars. Color tiers in `updateIcon(connectedCount:totalTunnels:)`: 0 connected = grey, 1 = light blue, 2+ but not all = darker blue `(0.2, 0.4, 1.0)`, all = green. The check order matters (all-connected is tested before `>= 2`); do not darken the mid-blue further — `(0.1, 0.2, 0.8)` was unreadable on dark menu bars.

### Persistence of settings

Both `binaryPath` and `hideDockOnClose` are persisted via `@Published` sinks in `AppState.init()` — not via UI-side `onChange`. Adding new persisted `@Published` properties must follow the same pattern (add `$property.sink { [weak self] _ in self?.persist() }` in `init`). Do NOT rely on `ContentView.onChange` for persistence — the window may be closed when the value changes.

### Tray menu updates

The tray menu is rebuilt **only** in `menuWillOpen(_:)` (i.e. just before the user sees it). There is intentionally no `objectWillChange` subscription driving `rebuildMenu()` — that pattern caused 500+ rebuilds/sec at `-vvvv` log verbosity. `menuWillOpen` is sufficient because menu items are only visible when open.

### Old-log cleanup

`LogWriterActor.deleteOldLogs(olderThanDays:)` is called **once** in `AppState.init()` as a detached background task. Do not call it from `FileLogger.init()` — that would run N concurrent cleanup sweeps for N tunnels, producing spurious `ErrorLog` entries from concurrent file-delete races.

### Journal level filter

`[SYSTEM]` log lines are subject to the same log-level filter (`lineMatches`) as regular ngate lines. Both paths (tunnel-scoped `[SYSTEM]` lines and app-wide `systemLogLines`) must apply the filter. Do not gate `[SYSTEM]` lines on the System pill alone.

### `connectAndWait` retry logic

`connectAndWait` has two nested `while` loops. The outer loop calls `connectTunnel` and increments `attempts`. The inner loop polls status every 200 ms.

**Critical**: when a retryable failure is detected (`.failed` or `.stopped` with `canRetry == true`), the code must use `continue outerLoop` (labeled continue) — NOT a bare `break`. A bare `break` exits only the `switch` statement, leaving the inner `while` running and never calling `connectTunnel` again. This was a bug that caused all tunnels except the first to hang in "Connecting" indefinitely.

### Token-less sandbox for password tunnels

`ngateconsoleclient` enumerates every smartcard container at startup regardless of auth method. For a JaCarta this is 6 container reads (~1.7 s each, ≈12 s per process standalone; the same 3 containers are read twice because the token is visible through both the native and the PKCS11 reader), and the token is a serial resource, so N concurrent client processes take roughly N × 12 s. There is no CLI flag or ini option to skip it (`--containerpath` does not help), and a `csptest` warmup does not help either — nothing is cached across processes.

`TunnelProcess.start` therefore launches clients for `authMethod == .credentials` through `/usr/bin/sandbox-exec -p <noTokenSandboxProfile>`, which denies `mach-lookup com.apple.ctkpcscd` and file access to `/Applications/JaCartaUC.app` and `/Library/Frameworks/jcPKCS11-2.framework`. Storage init drops to ~0.3 s and the password login works normally. Certificate tunnels are launched directly and must keep full token access. `sandbox-exec` execs the target, so the PID (and terminate/kill behaviour) is unchanged. It is skipped if `/usr/bin/sandbox-exec` is missing or `disableTokenSandbox` is set in UserDefaults. Do not touch CryptoPro reader configuration (`cpconfig`) as a workaround — the user explicitly ruled that out.

### Connect All startup

`runConnectAllStaggered` starts tunnels in parallel with a 3 s offset per tunnel (`withTaskGroup`, each child calls `connectAndWait` with its own 120 s deadline). Do not make it strictly sequential (each CryptoPro cert-storage init takes ~27 s, so 3 tunnels took ~90 s) and do not start all at once (contention on the CSP/token stretches init to 60+ s). A `csptest` warmup at launch was tried and removed — it does not affect the cert-storage init time.

Startup timeout: `connectAllTimeout` is 120 s (certificate tunnels with a Jacarta/CryptoPro token spend ~27–35 s initialising the cert storage before the first VPN session, and 60+ s under contention). The watchdog measures the `.starting` timeout from `TunnelRuntimeState.firstOutputAt` (first non-`[SYSTEM]` line from the process; reset in `connectTunnel`, set in `appendLog`), falling back to `lastStateChange` / `launchedAt`. Do not use `lastStateChange` alone: `updateState` is idempotent (`guard r.status != newState`), so re-starting a tunnel that is already `.starting` never refreshes it and the watchdog fires a false timeout.

## Key invariants

- Credentials (`pinCode`, `password`) must never reach `UserDefaults` or logs. Always call `sanitizedConfiguration` before persisting.
- `ngateconsoleclient` must always be launched with `-vvvv` — see `ProcessRunner.swift`.
- `TunnelError.isRetryable` is the single source of truth for retry decisions. Both the watchdog and `connectAndWait` consult it.
- DNS Helper line-protocol inputs are sanitized in both Swift (`sanitizeDomain`/`sanitizeIP`) and the bash helper (regex guards). Do not bypass either layer.
- `reapplyCurrentPolicy()` must **not** clear `writtenScopedResolvers` — doing so races with the subscription and produces duplicate "policy applied" logs.
- `transitionState(.running)` calls `reapplyCurrentPolicy()` only when `stateChanged == true` to avoid spurious re-applies (and duplicate log entries) when ngate emits "vpn online" multiple times during internal reconnects.
- The default resolver is applied via `networksetup`, never via an `/etc/resolver/.` file (which cannot exist). Do not add file-based logic for the default resolver.
- In `runWatchdogPass`, a missing tunnel in `tunnels` or `runtime` must `continue` (skip that tunnel), never `return` — returning would tear down the watchdog for ALL tunnels.
- `runHelper` must keep its watchdog-terminate timeout; a hung helper otherwise wedges `policyApplyInProgress` permanently.
- App version is sourced from the bundle / `build-app.sh APP_VERSION` only — never hardcode it in Swift.
- `diag()` in `DNSApplier` maps `SystemLogLevel` to the corresponding OSLog level (`.info` / `.warning` / `.error`). Do not use a single hardcoded level.
- `feedDNSParser` must aggregate ALL `ExtractedTunnel` entries from one JSON parse into **a single** `dnsPolicy.upsert()` call. Multiple calls for the same `tunnelID` overwrite each other — if the last entry has empty `SearchDomains` or empty `DNSs`, domains collected from earlier entries are silently lost. Use `flatMap` to merge all entries before calling `upsert()`.
