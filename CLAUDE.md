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
swift test --filter SecretVaultTests
swift test --filter WarmProcessTests   # runs the real client against 127.0.0.1:9; skipped without /opt/cprongate/ngateconsoleclient or clang

# One-time: create the local code-signing identity that build-app.sh then uses
./Scripts/setup-signing-identity.sh
```

The built app lands at `build/Ngate2VPN.app` (plus `build/Ngate2VPN-<version>.dmg`). Open with `open build/Ngate2VPN.app`.

### Non-Swift parts of the repo

- `Support/ngategate.c` — the `connect()` interposer used for pre-warming; compiled by `build-app.sh` into the bundle (universal arm64+x86_64).
- `Scripts/` — `setup-signing-identity.sh` (local signing identity), `build_icon.sh`, `publish_github_release.sh`.
- `Resources/` — `AppIcon.icns`.
- Note: the app binary is built for the host architecture only (arm64 here), and `ngateconsoleclient` itself is arm64 — the app is Apple-Silicon-only in practice.

## Architecture

This is a macOS-only SwiftUI app (macOS 13+) built as a Swift Package (no Xcode project file, no external dependencies). The single executable target is `Ngate2VPNApp`.

### Data flow

`AppState` is one class spread over several files (all members internal so the extensions can share state): `AppState.swift` (stored properties, `init`, tunnel CRUD), `AppState+Connection.swift` (connect/disconnect/Connect All, exit and state transitions), `AppState+Watchdog.swift` (wake + watchdog loop), `AppState+Prewarm.swift`, `AppState+Logging.swift` (journal ingestion, DNS parser feed), `AppState+Alerts.swift`, `AppState+Secrets.swift`. The value types (`TunnelConfiguration`, `TunnelError`, `TunnelRuntimeState`, `SystemLogLevel`, …) are in `TunnelModels.swift`. Retry/backoff/circuit-breaker decisions are pure functions in `WatchdogPolicy.swift` (unit-tested) — change limits there, not in `AppState`.

```
AppState (@MainActor)
  ├── tunnels: [TunnelConfiguration]       ← persisted to UserDefaults via TunnelPersistence
  ├── runtime: [UUID: TunnelRuntimeState]  ← in-memory only
  ├── TunnelProcessManager                 ← spawns/kills ngateconsoleclient processes
  ├── SecretVault (→ KeychainSecretStore)  ← PIN / password of ALL tunnels in ONE Keychain item, never in UserDefaults
  ├── DNSPolicyController                  ← aggregates DNS configs from all tunnels
  └── DNSApplier                           ← applies policy to /etc/resolver/ via sudoers helper
```

`AppState` is the single source of truth, always accessed on the main actor. UI reads from it via `@EnvironmentObject`. The three-tab UI (`Home`, `Journal`, `Settings`) is split by view: `ContentView.swift` (root + titlebar tabs), `HomeView.swift` (profile list, `ProfileRow`, `RoundedToggle`), `EditSheet.swift`, `JournalView.swift`, `LogTextView.swift` (NSTextView-backed log renderer), `SettingsView.swift` (+ `DNSHelperSection`), `Components.swift` (shared controls), `DesignSystem.swift` (`DS` tokens).

### Concurrency model

- `AppState` — `@MainActor`, all tunnel state mutations happen here
- `FileLogger` — Swift `actor`, serialises async disk writes per tunnel
- `ProcessRunner` / `TunnelProcessManager` — per-tunnel `DispatchQueue`s for stdout/stderr; callbacks hop back to `@MainActor` via `Task { @MainActor in … }`
- `DNSApplier` — `@MainActor` for state, `Task.detached` for shell invocations (`sudo`, `osascript`)

### Credential security

`TunnelConfiguration` stores credentials in-memory during profile editing. Before any persistence (`TunnelPersistence.save`) or connection start, `sanitizedConfiguration(_:)` strips `pinCode` and `password` to empty strings. The actual secrets live only in the Keychain, accessed through `SecretVault` (see below). At connection time `resolvedConfigurationForStart` re-injects them from Keychain.

### Keychain: one item, stable signing identity

macOS prompts per Keychain **item**, and an ad-hoc-signed app is a different app after every build, so per-secret items meant N prompts after each update.

- **`SecretVault`** keeps every tunnel's PIN/password in one item (`service NgateVPN`, `account vault.v1`, JSON `{tunnelUUID: {pin, password}}`), reads it once and caches it in memory. One prompt for all tunnels. The old per-secret items (`<id>_pin`, `<id>_password`) are migrated on first load and then deleted; any read error during migration aborts it without writing, so a denied prompt is simply retried later. `AppState.saveSecretsIfNeeded` treats an empty field as "unchanged" (profile forms never show stored secrets) and drops the other auth method's secret.
- **Stable signing.** `Scripts/setup-signing-identity.sh` creates a self-signed code-signing identity ("Ngate2VPN Local Signing") once; `build-app.sh` signs with it when present (override with `SIGN_IDENTITY`), falling back to ad-hoc. The designated requirement then pins the certificate, not the cdhash, so "Always Allow" survives updates. `codesign` only uses a *trusted* identity (`security add-trusted-cert -p codeSign`, needs an interactive password) — an untrusted one reports "no identity found". Do not hide `codesign` errors in `build-app.sh` (`sign_app` returns non-zero and the script falls back explicitly).
- Keychain reads happen on the main actor (first read may block on the prompt); pre-warming uses the quiet resolver so a prompt at launch never fails a tunnel.

### Process management

Each tunnel runs one `ngateconsoleclient` process, always launched with `-vvvv` (verbose). The verbose output is necessary: `NgateGatewayResponseParser` scans the `Debug` log lines for the JSON block containing `IPTunnels`/`DNSs`/`SearchDomains`. Without `-vvvv` this block is not printed.

`AppState` contains a watchdog loop that runs every 5 s. On retryable errors it restarts the process with exponential backoff (base 5 s, cap 15 min). The restart decision is a pure function, `WatchdogPolicy.decide` (unit-tested in `WatchdogPolicyTests`); `AppState+Watchdog.swift` only gathers its inputs and performs the side effects. Limits (all in `WatchdogPolicy`): 8 consecutive failures without Auto-reconnect, **24 with Auto-reconnect** (≈5 h awake; it used to be unlimited), and **2 attempts in total for a missed 2FA prompt** (`twoFactorMaxRetries = 1`; a pause before the retry was tried and dropped — once the gateway has timed out an attempt it is dead, so approving the old prompt later cannot save it). When a limit trips the tunnel is paused (`watchdogPaused`) with a journal line (and an alert for Auto-reconnect / 2FA); the user's Connect/toggle clears it, and a wake from sleep clears it for Auto-reconnect tunnels (not for a 2FA pause). The `TunnelError.isRetryable` property is the authoritative classification.

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

#### `/etc/resolver` ownership

The directory must be `root:wheel`: a user-owned `/etc/resolver` lets any process running as the user plant resolver files without sudo. Both the install script and the helper (`chown root:wheel /etc/resolver`) enforce it. Changing the helper source changes its hash, so the app then shows "DNS Helper code changed" until the user reinstalls it (one admin prompt) and DNS is not applied in between — call that out in release notes when touching the helper.

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

Level words are padded with spaces to 8 characters (width of `"Critical"`) so all messages align in a column in the monospaced journal font. The `SystemLogLevel` enum (`Info`, `Warning`, `Error`, `Critical`) is defined in `TunnelModels.swift` and is shared with `DNSApplier.swift` via the same module. `DNSApplier.onDiagnostic` carries `(String, SystemLogLevel)`.

In the Journal renderer (`LogTextView.swift / buildAttributedString`), `[SYSTEM]` lines use `nsColor(for: entry.text)` for body coloring — the same level-token detection as ngate lines. The `[SYSTEM] ` tag itself is always rendered in `systemTagColor` (orange).

### Log timestamps

All log lines use `dd.MM.yyyy` date prefix (not `yyyy-MM-dd`). The `timestampKey` function in `JournalView` rearranges the components back to `yyyy-MM-dd HH:mm:ss` for lexicographic sorting. The `lineCarriesFullTimestamp` detector checks for dots at positions 2 and 5 (not dashes at 4 and 7).

### Error classification

`NgateOutputParser.swift` is a pure, stateless enum with no dependencies on `AppState` or any actor. It maps lowercased ngate log lines to `TunnelError` values. Order matters — more specific patterns precede general ones. This is the most churn-prone code (ngate phrasing changes between versions) and is directly unit-tested.

Notable classification decisions:
- `"vpn session destroyed"` is intentionally **not** classified — it is a finalization event that fires after both retryable and non-retryable errors, and matching it would overwrite an earlier correct classification.
- `"unable to correctly logout from remote gate"` → `sessionRefreshFailed` (retryable): the server closed the session; watchdog reconnects silently.
- **2FA timeout.** The gateway holds a password login ~15 s waiting for the second factor, then answers `401` — indistinguishable in text from a wrong password. `AppState+Logging` records the last `LoginTransaction finished in N s` per attempt (`lastLoginTransactionSeconds`); `NgateOutputParser.refineCredentialsError` turns `invalidCredentials` into `twoFactorTimeout` (retryable) when a password tunnel was rejected after ≥ 8 s. The refinement must be applied to *every* `invalidCredentials` line of the attempt (the client prints the error twice), otherwise the second line overwrites it and raises the "Invalid credentials" alert. `connectAndWait` does not retry `twoFactorTimeout` (`WatchdogPolicy.canRetryDuringStartup`) — the watchdog owns that budget, or the user would get extra prompts.
- **Proxy.** The client uses the *system* HTTP(S) proxy. `ProxyConnectionClosedError` / "connection with proxy closed prematurely" → `proxyFailure` (retryable), matched before the generic "connection refused". It is ignored while a session is up (the client retries refreshes itself; marking the tunnel degraded could leave it stuck). `ProxyPreflight` (called from `connectTunnel`, fire-and-forget) sends a real `CONNECT` through the proxy that CFNetwork selects for the gateway URL and logs a warning if the proxy is down or refuses; it never blocks or fails the connect. SOCKS/PAC proxies are not probed.

### App lifecycle

The app uses a SwiftUI `@main` entry with `@NSApplicationDelegateAdaptor`. The real UI lives in an AppKit-managed `NSWindow` created by `AppDelegate`. A placeholder SwiftUI `Window` scene is required to satisfy the protocol but is immediately closed on launch.

`applicationShouldHandleReopen` returns **`false`** (not `true`). Returning `true` would tell AppKit to run its own scene-restoration logic, which reopens all previously closed SwiftUI Window scenes — including the placeholder. Since we handle reopen ourselves via `showMainWindow()`, returning `false` prevents the phantom placeholder window.

Quit is asynchronous (`applicationShouldTerminate` returns `.terminateLater`): DNS routes are wiped, tunnels terminated, credential temp files cleaned, then `NSApp.reply(toApplicationShouldTerminate: true)`. A 3 s watchdog forces the reply if cleanup stalls.

The About panel reads its version from `Bundle.main.infoDictionary["CFBundleShortVersionString"]` — do NOT hardcode it. The single source of truth for the version is `APP_VERSION` in `build-app.sh` (which writes it into the generated `Info.plist`). README status line and CHANGELOG must be bumped to match.

### UI conventions (Sources/Ngate2VPNApp/*View.swift, DesignSystem.swift)

Colors come from the `DS` design-token enum (each token has a dark/light pair via `NSColor(name:dynamicProvider:)`); corner radii are `DS.r` (10) and `DS.rL` (14). The status-bar (tray) icon is managed by `StatusIconManager` — it tints a `globe` SF Symbol; the disconnected state uses `NSColor.secondaryLabelColor` (NOT a fixed white/black) so it stays visible on both light and dark menu bars. Color tiers in `updateIcon(connectedCount:totalTunnels:)`: 0 connected = grey, 1 = light blue, 2+ but not all = darker blue `(0.2, 0.4, 1.0)`, all = green. The check order matters (all-connected is tested before `>= 2`); do not darken the mid-blue further — `(0.1, 0.2, 0.8)` was unreadable on dark menu bars.

### Persistence of settings

`TunnelConfiguration` and `PersistedState` have **hand-written tolerant decoders** (`decodeIfPresent` + defaults). Never rely on synthesized `Codable` here: a new non-optional field would make old saved data undecodable and the app would start with no profiles. `TunnelPersistence.save` keeps the previous blob in `ngate2vpn.saved.state.previous` and an undecodable one in `…undecodable`, both passed through `scrubbed(_:)` so no PIN/password can be in a backup. On launch profiles are loaded *unsanitized*, `migratePersistedSecretsToKeychainIfNeeded()` moves any legacy in-JSON secrets to the Keychain and strips them, and only then does anything call `persist()` — do not reorder that in `AppState.init`.

Both `binaryPath` and `hideDockOnClose` are persisted via `@Published` sinks in `AppState.init()` — not via UI-side `onChange`. Adding new persisted `@Published` properties must follow the same pattern (add `$property.sink { [weak self] _ in self?.persist() }` in `init`). Do NOT rely on `ContentView.onChange` for persistence — the window may be closed when the value changes.

Plain `UserDefaults` keys (read/written via `@AppStorage` or `UserDefaults.standard`, not through `persist()`): `autoConnect`, `prewarmTunnels` (default on), `disableTokenSandbox` (escape hatch, default off), `holdDefaultDNS` (default on), `showErrorAlerts`, `appTheme`, `journalLogLevel`, `journalShowSystem`. Tunnel profiles and `binaryPath`/`hideDockOnClose` go through `TunnelPersistence`.

### Tray menu updates

Between the profile list and "Settings…" an "Active connections" area lists each connected tunnel's name and IP. Rows are custom views (`ConnectionMenuItemView`): a normal `NSMenuItem` click always dismisses the menu, a click inside a custom view does not, which is what allows "copy IP, flash Copied, stay open". Consequences worth knowing: menus draw no tooltips for view items (hence the private `HintPanel`), `mouseExited` is not delivered reliably during menu tracking (hence the pointer-position watch and the shared `hoveredRow`), and such rows are not keyboard-navigable.

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

### Pre-warming (gated clients)

Goal: hide the ~12 s/process token enumeration behind app launch / token insertion instead of the Connect click.

- **Gate.** `Support/ngategate.c` is built by `build-app.sh` into `Contents/Resources/libngategate.dylib` and inserted with `DYLD_INSERT_LIBRARIES`. It interposes `connect()` for `AF_INET/AF_INET6` and blocks (20 ms polling) until the file `NGATE2VPN_GATE_FILE` exists; it `_exit`s if `getppid()` stops matching `NGATE2VPN_GATE_PARENT` (app died — no orphaned clients holding the token). The client binary is not modified; it is ad-hoc signed without hardened runtime, which is what allows DYLD injection. SIGSTOP-based holding was rejected: the client sends its first request ~40 ms after init, so the freeze lands mid-connection and the gateway drops the half-open socket.
- **Launch chain.** `TunnelProcess.start(gated: true)` runs `env DYLD_INSERT_LIBRARIES=… NGATE2VPN_GATE_FILE=… NGATE2VPN_GATE_PARENT=<pid> <client> …`. For password tunnels it is `sandbox-exec -p <profile> env … <client>` — **`env` must come after `sandbox-exec`**, because SIP-protected binaries strip `DYLD_*` from the environment they pass on; `env` (re)sets the variables right before exec'ing the client.
- **Separation.** Warm processes live in `TunnelProcessManager.warm`, NOT in `processes`. The watchdog, `state(for:)`, status and alerts never see them; the tunnel stays `.stopped`. Their output is buffered inside `TunnelProcess` and replayed on adoption. `connectTunnel` calls `adoptWarm` before a cold `launch`: `.adopted` (gate released), `.stale` (settings signature differs — discarded, cold start), `.unavailable`. Adoption is allowed even while the client is still initialising (it just releases the gate early).
- **When to warm** (`AppState.schedulePrewarm`, staggered 3 s because launches contend for the token): launch (skipped if Auto-connect is on), token inserted, **at the moment of a user Disconnect** (`disconnectTunnel` → `schedulePrewarm(duringDisconnect: true)`: the replacement's token read overlaps the old client's shutdown; `TunnelProcessManager.prewarm` allows this only while the old process is `.stopping`; `handleExit` re-arms as a fallback), after profile edit, after wake, when the setting is switched on. Certificate tunnels only when `TokenMonitor` (IOKit, USB interface class 0x0B) sees a token; token removal, sleep, profile edit/delete and quit discard warm processes (SIGKILL — no session to close).
- **Who is warmed.** Only tunnels that read the token (`needsToken`: certificate auth, or password auth when the token sandbox is disabled). Password tunnels in the sandbox init in ~0.3 s, so warming them buys nothing and would leave an idle process plus its credential file around. `runConnectAllStaggered` likewise starts non-token tunnels immediately and only staggers token-using cold ones.
- **Hold-time limit (important).** The client arms its login-transaction timer when the session starts, i.e. right after storage init — *before* our gate — and gives up after ~120 s ("Transaction timeout happened while connecting to gate" → "Unable to login to remote gate in a reasonable time", exit 0). Measured: holds of 100 s survive, 200 s and 400 s do not. Warm clients therefore get `operationsTimeout=1200000` (milliseconds!) in their config file (`GateSupport.warmOperationsTimeoutMs`; `connectionsTimeout` does nothing; seconds-vs-ms was verified: 60 fails a 30 s hold, 100000 fails a 130 s hold). Because an adopted client keeps that big timeout for its whole life, warm clients are also replaced after `GateSupport.maxWarmAge` (10 min) by `refreshAgedWarmClients()` (called from every watchdog pass; discard + relaunch in one main-actor turn so Connect never sees a gap). Without both, a warm client older than ~2 min dies the moment it is released — the tunnel "switches on and immediately off".
- **Safety net.** If an adopted client still dies within 30 s without ever going online and with no real error (`lastError` nil or `.startupTimeout`), `handleExit` starts a fresh client once (`warmAdoptedAt`) instead of failing the tunnel. `NgateOutputParser` classifies the two timeout messages as `.startupTimeout` (retryable).
- **Signature.** `warmSignature` = SHA-256 of title/URL/auth/cert/PIN/user/password. A warm client is only adopted if it matches the resolved configuration at Connect time.
- **Quiet resolution.** Pre-warming uses `resolvedConfigurationForStart(…, quiet: true)`: missing Keychain secrets must not log, alert, or fail the tunnel.
- **Invariants.**
  - The `terminationHandler` in `TunnelProcess.start` captures `self` **strongly** (cycle broken in `handleTermination`). A weak capture leaks the credential file when a discarded warm process is no longer referenced by the manager.
  - Config file names are unique per launch (`<uuid>-<rand>.cfg`); otherwise a dying warm process deletes the file of a fresh cold start.
  - Never put a warm process into `processes` before `adopt` succeeds, and never let its callbacks reach `handleExit`/`handleProcessStateChange` (that would fail the tunnel and raise alerts for something the user never started).
  - Kill switch: Settings toggle (`prewarmTunnels`); pre-warming is also silently unavailable when the dylib is not bundled.
- Tests: `WarmProcessTests` runs the real client against `127.0.0.1:9` (skipped if `/opt/cprongate/ngateconsoleclient` or clang is missing). The 150 s long-hold test is opt-in: `NGATE2VPN_SLOW_TESTS=1 swift test --filter WarmProcessTests`.

### Connect All startup

`runConnectAllStaggered` starts tunnels in parallel with a 3 s offset per tunnel (`withTaskGroup`, each child calls `connectAndWait` with its own 120 s deadline). Do not make it strictly sequential (each CryptoPro cert-storage init takes ~27 s, so 3 tunnels took ~90 s) and do not start all at once (contention on the CSP/token stretches init to 60+ s). A `csptest` warmup at launch was tried and removed — it does not affect the cert-storage init time.

Startup timeout: `connectAllTimeout` is 120 s (certificate tunnels with a Jacarta/CryptoPro token spend ~27–35 s initialising the cert storage before the first VPN session, and 60+ s under contention). The watchdog measures the `.starting` timeout from `TunnelRuntimeState.firstOutputAt` (first non-`[SYSTEM]` line from the process; reset in `connectTunnel`, set in `appendLog`), falling back to `lastStateChange` / `launchedAt`. Do not use `lastStateChange` alone: `updateState` is idempotent (`guard r.status != newState`), so re-starting a tunnel that is already `.starting` never refreshes it and the watchdog fires a false timeout.

### Performance floor and rejected approaches

Measured on the maintainer's Mac (JaCarta token, three profiles: tunnel A = password, tunnel B and tunnel C = certificate). Connect All with warm clients: tunnel A ~2.6 s, tunnel B/tunnel C ~8 s after the click, ~8.6 s total (was ~43 s). The remaining time is the token: certificate tunnels each need a container pick (~3 s) and a TLS-handshake signature (~1.7 s) on the token, and the token serves them one at a time. Do not re-propose:

- token/certificate "caching" — the client has no input for preloaded certificates, its store lives in process memory, and the private key stays on the token anyway;
- a `csptest` warmup (removed; no effect), CryptoPro reader reconfiguration (`cpconfig` — ruled out by the user), decompiling/patching the client;
- SIGSTOP-based holding (see Pre-warming) or blocking `librdrjacarta` per process (it provides *both* JaCarta readers, so the VPN certificate's PKCS11 container disappears; the native container is only ~0.4 s of the ~12 s anyway);
- hidden client options: `--help-all`, the ini keys and env vars were checked — nothing skips the storage scan (`--containerpath` and `-H` do not).

### Debugging with logs

- Per-tunnel logs: `~/Library/Application Support/Ngate2VPN/logs/tunnel_<tunnel-uuid>.log` (5 MB rotation). Ngate lines carry no tunnel tag on disk — map UUID → profile by grepping `[SYSTEM] … [Name]` lines. `[SYSTEM]` lines (`Using pre-warmed client`, `Client pre-warmed`, `Disconnect requested`, `Connect All finished`) are the timeline anchors; `Certificates storages thread staring` → `All local certificates storages operational` is the token-init window.
- A warm client's output is buffered and only reaches the journal/disk when a Connect adopts it, so an unadopted warm client leaves no trace there (only its `Client pre-warmed` system line).
- Temp state: `~/Library/Caches/Ngate2VPN/secure-configs/*.cfg` (credentials, 0600, removed on process exit and swept at launch/quit) and `…/gates/*.gate`. Leftovers after tests or a crash are safe to delete; never delete them while a real tunnel is starting.
- Keychain checks without touching secrets: `security find-generic-password -s NgateVPN -a vault.v1` (no `-w`/`-g`). Do not dump the Keychain.
- `pgrep -f` can fail with "illegal byte sequence" here; use `ps -A -o pid,command | grep '[n]gateconsoleclient'`.
- Signature of a warm client that sat at the gate too long: `Using pre-warmed client`, then within ~20 ms `Transaction timeout happened while connecting to gate` → `Unable to login to remote gate in a reasonable time` → `NGate console client stopped.` → `Connection failed with exit code: 0`. If it reappears, check that the client's config has `operationsTimeout=…` and that `refreshAgedWarmClients` is firing (`Pre-warmed client refreshed` system lines every ~10 min).
- Timing experiments against the client (dummy URL `https://127.0.0.1:9/x/`, `sandbox-exec -f notoken.sb /usr/bin/env DYLD_INSERT_LIBRARIES=… NGATE2VPN_GATE_FILE=… client -N -vvvv --disable-proxy`): **do not set `NGATE2VPN_GATE_PARENT` from a script subshell** — it must equal the client's real parent PID, otherwise the gate `_exit(0)`s at its first 20 ms poll and the client silently vanishes. Kill experiment processes by explicit PID: `ps | grep name | xargs kill` matches your own shell command line and kills the tool call. Long waits: run the script with `run_in_background` and watch its result file rather than sleeping.

### Release workflow

1. Bump `APP_VERSION` in `build-app.sh`, the README status line, and add a CHANGELOG entry (Russian, newest first).
2. `swift test`, then `./build-app.sh` (signs with "Ngate2VPN Local Signing" if present — check the printed `designated =>` line shows `certificate leaf`, not `cdhash`).
3. The user installs and verifies on real tunnels (`pkill -x Ngate2VPN; rm -rf /Applications/Ngate2VPN.app && cp -R build/Ngate2VPN.app /Applications/ && open /Applications/Ngate2VPN.app`) and reports back with Journal logs. **Do not commit or publish before they confirm it works.**
3b. `build/Ngate2VPN.app` has been seen to disappear between a build and the release step; the DMG is what ships, so before publishing mount it read-only (`hdiutil attach -readonly -nobrowse -mountpoint <tmp> build/Ngate2VPN-X.Y.dmg`) and check `CFBundleShortVersionString`, `codesign --verify --deep --strict`, the `designated =>` line (`certificate leaf`), and that `Contents/Resources/libngategate.dylib` is present; then `hdiutil detach`.
4. `git add` the specific files (never `.claude/settings.local.json`), commit, `git push origin main`, then `gh release create vX.Y build/Ngate2VPN-X.Y.dmg --target main --title vX.Y --notes …` (notes in Russian).
- Users must install a build ≥ 3.27 to read secrets: older builds look for the per-secret Keychain items that `SecretVault` migrates away.

## Key invariants

- Retry policy lives in `WatchdogPolicy` only (limits, backoff, 2FA budget). Do not re-introduce constants or decision logic in `AppState`.
- `TunnelConfiguration` / `PersistedState` decoding must stay tolerant of missing keys; backups of persisted state must go through `TunnelPersistence.scrubbed`.
- `TunnelRuntimeState.lastLoginTransactionSeconds` is reset in `connectTunnel` and is what tells a 2FA timeout from a wrong password; keep the refinement on every `invalidCredentials` line.
- `/etc/resolver` must stay `root:wheel`.
- Right-click menus that need coloured items use `NativeContextMenu` (SwiftUI `.contextMenu` ignores text colour); the Settings tab draws its own translucent titlebar strip (`TitlebarBackdrop` in `SettingsView.swift`) — do not move it to `ContentView`, it darkened every tab. Tab switches deliberately have no implicit animation (`ContentView`), because it flashed an empty rectangle on first display.

- Secrets live in exactly one Keychain item (`SecretVault`, account `vault.v1`); never reintroduce per-tunnel/per-secret items — each is a separate macOS access prompt.
- Never hide `codesign` failures in `build-app.sh`, and keep the ad-hoc fallback: an unusable identity must not produce an unsigned bundle.
- The client's login transaction dies ~120 s after session start regardless of our gate. Any change to gating/warming must keep warm clients' `operationsTimeout` (ms) raised **and** refreshed within `GateSupport.maxWarmAge`; holds longer than ~100 s without both silently break the first Connect.
- Pre-warmed processes stay out of `TunnelProcessManager.processes` until adopted (see Pre-warming); a discarded one must still clean up its credential file.

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
