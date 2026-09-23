import Foundation

// MARK: - TunnelConfigFile

/// On-disk config for `ngateconsoleclient`. Credentials are written here
/// so they don't have to be passed as command-line arguments — which would
/// otherwise be visible to every process on the system via `ps`, leak
/// into `sysdiagnose`, end up in crash reports, and so on.
///
/// **Format.** Plain `key=value` INI lines, one per setting. Comments are
/// prefixed with `;`. Keys understood by ngateconsoleclient (verified
/// against its option list):
/// `url`, `username`, `password`, `certificateSha1`,
/// `certificateContainerPIN`, and `operationsTimeout` (milliseconds; only
/// written for pre-warmed clients). Verbosity is a command-line flag (`-vvvv`),
/// not an ini key.
///
/// **Lifecycle.**
///   1. `create(for:)` writes the file with mode `0600` under
///      `~/Library/Caches/Ngate2VPN/secure-configs/`.
///   2. ProcessRunner passes `-c <path>` to ngateconsoleclient.
///   3. `delete()` runs in the process's `terminationHandler`.
///   4. `removeAllStaleConfigs()` is invoked once at app launch to wipe any
///      leftovers from a prior crash or Force Quit.
///
/// **Security.** Mode 0600 means only the owning user can read it.
/// During the brief window between write and ngate's `open()`, even root
/// would need to specifically race for the file — and root can already
/// read everything, so this is no regression. The previous design
/// (credentials as argv) leaked them to **all** local users via `ps`.
struct TunnelConfigFile {

    let url: URL

    /// Writes a fresh per-tunnel config and returns a handle to it. The
    /// caller is responsible for invoking `delete()` once ngate has
    /// terminated. If the write fails partway through we make a best-
    /// effort cleanup so we never leave partially-populated credentials
    /// on disk.
    /// - Parameter operationsTimeoutMs: overrides the client's transaction
    ///   timeout (ms). Pre-warmed clients need this: the client arms its login
    ///   timer when it starts and gives up ~2 min later, whether or not it is
    ///   being held at the gate.
    static func create(for configuration: TunnelConfiguration, operationsTimeoutMs: Int? = nil) throws -> TunnelConfigFile {
        try validateINIValues(configuration)

        let dir = configsDirectory()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // Unique per launch: a pre-warmed process that is being discarded
        // deletes its own file on exit and must never take a fresh launch's
        // file with it.
        let url = dir.appendingPathComponent("\(configuration.id.uuidString)-\(UUID().uuidString.prefix(8)).cfg")
        let body = renderINI(for: configuration, operationsTimeoutMs: operationsTimeoutMs)

        // Write atomically then chmod. `Data.write(to:options:.atomic)`
        // produces the file via a temp+rename, so we can't `umask` it
        // beforehand — instead we pin permissions immediately after.
        do {
            try body.data(using: .utf8)?.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        return TunnelConfigFile(url: url)
    }

    /// Removes the file from disk. Idempotent — safe to call after a
    /// successful exit, after a crash, or even after we already deleted.
    func delete() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Wipes every `*.cfg` left in our config dir. Call once at app
    /// startup — there should never be a live ngate process referring to
    /// these files at that point because the previous app instance has
    /// exited. Catches the rare crash-during-tunnel-running case.
    static func removeAllStaleConfigs() {
        let dir = configsDirectory()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }
        for url in contents where url.pathExtension == "cfg" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func configsDirectory() -> URL {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return cache
            .appendingPathComponent("Ngate2VPN", isDirectory: true)
            .appendingPathComponent("secure-configs", isDirectory: true)
    }

    private static func renderINI(for c: TunnelConfiguration, operationsTimeoutMs: Int?) -> String {
        var lines: [String] = []
        // Header — useful when debugging via the file system; doesn't
        // change ngate's behaviour.
        lines.append("; Ngate2VPN tunnel configuration")
        lines.append("; \(c.title)")
        lines.append("; This file is regenerated on every connect and removed on disconnect.")
        lines.append("")
        lines.append("url=\(c.endpointURL)")
        if let operationsTimeoutMs {
            lines.append("operationsTimeout=\(operationsTimeoutMs)")
        }

        switch c.authMethod {
        case .certificate:
            lines.append("certificateSha1=\(c.serialNumber)")
            if !c.pinCode.isEmpty {
                lines.append("certificateContainerPIN=\(c.pinCode)")
            }
        case .credentials:
            lines.append("username=\(c.username)")
            lines.append("password=\(c.password)")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func validateINIValues(_ c: TunnelConfiguration) throws {
        try validateINIValue(c.title, field: "profile name")
        try validateINIValue(c.endpointURL, field: "URL")
        switch c.authMethod {
        case .certificate:
            try validateINIValue(c.serialNumber, field: "certificate SHA1")
            try validateINIValue(c.pinCode, field: "PIN")
        case .credentials:
            try validateINIValue(c.username, field: "username")
            try validateINIValue(c.password, field: "password")
        }
    }

    private static func validateINIValue(_ value: String, field: String) throws {
        if value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw TunnelProcessError.invalidConfigValue(field)
        }
    }
}

// MARK: - TunnelProcessError

enum TunnelProcessError: LocalizedError {
    case alreadyRunning
    case invalidConfigValue(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Already running"
        case .invalidConfigValue(let field):
            return "\(field) contains unsupported control characters"
        }
    }
}

enum TunnelState: String {
    case stopped
    case starting
    case running
    case degraded
    case stopping
    case failed
}

final class TunnelProcess: @unchecked Sendable {
    private let queue: DispatchQueue
    private var onOutput: @Sendable (String) -> Void
    private var onStateChange: @Sendable (TunnelState) -> Void
    private var onExit: @Sendable (Int32) -> Void

    private var state: TunnelState = .stopped
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stopCompletion: DispatchSemaphore?
    /// Per-process credential file. Lives only for the duration of one
    /// ngateconsoleclient invocation, deleted in handleTermination().
    private var configFile: TunnelConfigFile?

    // Pre-warm ("gated") support. While `gateFile` is set the process is
    // initialised but held before its first network connect, and its output
    // is buffered instead of delivered.
    private var gateFile: URL?
    private var releasedGateFile: URL?
    private var buffersOutput = false
    private var bufferedOutput: [String] = []

    init(
        label: String,
        onOutput: @escaping @Sendable (String) -> Void,
        onStateChange: @escaping @Sendable (TunnelState) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        self.queue = DispatchQueue(label: label)
        self.onOutput = onOutput
        self.onStateChange = onStateChange
        self.onExit = onExit
    }

    /// - Parameter gated: start the client pre-warmed — it initialises fully
    ///   but is held before its first network connect until `adopt` releases
    ///   the gate. Requires `GateSupport.libraryURL`; falls back to an
    ///   ordinary (ungated) launch if the library is unavailable.
    func start(binaryPath: String, configuration: TunnelConfiguration, gated: Bool = false) throws {
        try queue.sync {
            guard state == .stopped else { throw TunnelProcessError.alreadyRunning }

            // Write a per-process config file with credentials. This
            // replaces what used to be command-line arguments, and is
            // the difference between credentials being visible to
            // every process via `ps` and being readable only by the
            // current user via a 0600-mode temp file.
            let willGate = gated && GateSupport.libraryURL != nil
            let configFile = try TunnelConfigFile.create(
                for: configuration,
                operationsTimeoutMs: willGate ? GateSupport.warmOperationsTimeoutMs : nil
            )

            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            var command = [binaryPath] + makeArgs(configFilePath: configFile.url.path)
            var newGateFile: URL?
            if gated, let library = GateSupport.libraryURL {
                do {
                    let gate = try GateSupport.makeGateFileURL()
                    // env(1) sets the variables itself: sandbox-exec is a
                    // SIP-protected binary, so dyld strips DYLD_* from the
                    // environment it would otherwise pass on to the client.
                    command = [
                        "/usr/bin/env",
                        "DYLD_INSERT_LIBRARIES=\(library.path)",
                        "NGATE2VPN_GATE_FILE=\(gate.path)",
                        "NGATE2VPN_GATE_PARENT=\(getpid())",
                    ] + command
                    newGateFile = gate
                } catch {
                    configFile.delete()
                    throw error
                }
            }
            if configuration.authMethod == .credentials && Self.tokenSandboxEnabled {
                process.executableURL = URL(fileURLWithPath: Self.sandboxExecPath)
                process.arguments = ["-p", Self.noTokenSandboxProfile] + command
            } else {
                process.executableURL = URL(fileURLWithPath: command[0])
                process.arguments = Array(command.dropFirst())
            }
            self.gateFile = newGateFile
            self.buffersOutput = newGateFile != nil
            self.bufferedOutput = []
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            installReadabilityHandler(for: stdoutPipe.fileHandleForReading)
            installReadabilityHandler(for: stderrPipe.fileHandleForReading)

            self.process = process
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            self.stopCompletion = DispatchSemaphore(value: 0)
            self.configFile = configFile
            transition(to: .starting)

            // Strong capture on purpose: a discarded warm process is no longer
            // referenced by the manager, yet must still run its cleanup (it
            // deletes the credential file) when it exits. The cycle is broken
            // in handleTermination.
            process.terminationHandler = { finishedProcess in
                self.handleTermination(process: finishedProcess)
            }

            do {
                try process.run()
                transition(to: .running)
            } catch {
                // Launch failed — make sure we don't leak the credential
                // file we just wrote.
                configFile.delete()
                self.configFile = nil
                cleanupAfterTermination()
                transition(to: .failed)
                throw error
            }
        }
    }

    func stop() {
        queue.async {
            guard let process = self.process else { return }
            guard self.state == .starting || self.state == .running || self.state == .degraded || self.state == .failed else { return }

            self.transition(to: .stopping)
            self.send(signal: SIGINT, to: process)
            self.scheduleEscalation(for: process, signal: SIGTERM, after: 3)
            self.scheduleEscalation(for: process, signal: SIGKILL, after: 6)
        }
    }

    func stopAndWait(timeout: TimeInterval = 7) -> Bool {
        let completion: DispatchSemaphore? = queue.sync {
            guard let process else { return nil }
            if state == .stopping {
                return stopCompletion
            }

            guard state == .starting || state == .running || state == .degraded || state == .failed else {
                return nil
            }

            transition(to: .stopping)
            send(signal: SIGINT, to: process)
            scheduleEscalation(for: process, signal: SIGTERM, after: 3)
            scheduleEscalation(for: process, signal: SIGKILL, after: 6)
            return stopCompletion
        }
        return wait(on: completion, timeout: timeout)
    }

    func forceKill() {
        queue.async {
            guard let process = self.process else { return }
            if self.state != .stopping {
                self.transition(to: .stopping)
            }
            self.send(signal: SIGKILL, to: process)
        }
    }

    func currentState() -> TunnelState {
        queue.sync { state }
    }

    // MARK: Pre-warm

    /// True while the process is alive and still held at the gate.
    func isWarmReady() -> Bool {
        queue.sync { gateFile != nil && state == .running && process?.isRunning == true }
    }

    func setExitHandler(_ handler: @escaping @Sendable (Int32) -> Void) {
        queue.sync { onExit = handler }
    }

    /// Hands a warm process over to the tunnel state machine: installs the
    /// real callbacks, replays the output buffered so far, and releases the
    /// gate so the client proceeds to connect. Returns false (touching
    /// nothing) if the process is no longer warm.
    func adopt(
        onOutput: @escaping @Sendable (String) -> Void,
        onStateChange: @escaping @Sendable (TunnelState) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) -> Bool {
        queue.sync {
            guard let gate = gateFile, state == .running, process?.isRunning == true else { return false }
            guard FileManager.default.createFile(
                atPath: gate.path, contents: nil, attributes: [.posixPermissions: 0o600]
            ) else { return false }

            self.onOutput = onOutput
            self.onStateChange = onStateChange
            self.onExit = onExit
            self.buffersOutput = false
            let pending = bufferedOutput
            bufferedOutput = []
            pending.forEach(onOutput)

            // Keep the path so it can be removed once the process is gone.
            releasedGateFile = gate
            gateFile = nil
            return true
        }
    }

    /// Kills a warm process immediately (SIGKILL — it holds no session, so
    /// there is nothing to shut down gracefully).
    func discardWarm() {
        queue.async {
            guard let process = self.process, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func installReadabilityHandler(for handle: FileHandle) {
        handle.readabilityHandler = { [weak self] readable in
            let data = readable.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.deliver(text)
        }
    }

    private func deliver(_ text: String) {
        queue.async {
            if self.buffersOutput {
                self.bufferedOutput.append(text)
            } else {
                self.onOutput(text)
            }
        }
    }

    private func handleTermination(process finishedProcess: Process) {
        queue.async {
            guard self.process === finishedProcess else { return }
            finishedProcess.terminationHandler = nil

            self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe?.fileHandleForReading.readabilityHandler = nil

            let exitCode = finishedProcess.terminationStatus
            let nextState: TunnelState
            switch self.state {
            case .stopping:
                nextState = .stopped
            case .starting, .running, .degraded:
                nextState = exitCode == 0 ? .stopped : .failed
            case .failed:
                nextState = .failed
            case .stopped:
                nextState = .stopped
            }

            self.cleanupAfterTermination()
            self.transition(to: nextState)
            self.onExit(exitCode)
        }
    }

    private func cleanupAfterTermination() {
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        // Wipe the credential file as soon as ngate has stopped reading
        // it. We do this here rather than waiting for the next launch's
        // sweep so that a long-lived stopped tunnel doesn't keep its
        // credentials sitting on disk.
        configFile?.delete()
        configFile = nil
        if let gate = gateFile { try? FileManager.default.removeItem(at: gate) }
        if let gate = releasedGateFile { try? FileManager.default.removeItem(at: gate) }
        gateFile = nil
        releasedGateFile = nil
        buffersOutput = false
        bufferedOutput = []
        stopCompletion?.signal()
        stopCompletion = nil
    }

    private func scheduleEscalation(for process: Process, signal: Int32, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) {
            guard self.process === process, process.isRunning else { return }
            self.send(signal: signal, to: process)
        }
    }

    private func send(signal: Int32, to process: Process) {
        guard process.isRunning else { return }
        kill(process.processIdentifier, signal)
    }

    private func transition(to newState: TunnelState) {
        guard state != newState else { return }
        state = newState
        onStateChange(newState)
    }

    private func wait(on semaphore: DispatchSemaphore?, timeout: TimeInterval) -> Bool {
        guard let semaphore else { return process == nil }
        return semaphore.wait(timeout: .now() + timeout) == .success
    }

    private static let sandboxExecPath = "/usr/bin/sandbox-exec"

    // ngateconsoleclient enumerates every smartcard container at startup
    // (~12 s for a JaCarta, and the token is a serial resource shared by all
    // client processes) even for login/password tunnels that never use it.
    // sandbox-exec exec()s the client, so the PID is unchanged.
    private static let noTokenSandboxProfile = """
        (version 1)
        (allow default)
        (deny mach-lookup (global-name "com.apple.ctkpcscd"))
        (deny file-read* file-map-executable
          (subpath "/Applications/JaCartaUC.app")
          (subpath "/Library/Frameworks/jcPKCS11-2.framework"))
        """

    // Escape hatch: `defaults write com.ngate2vpn.app disableTokenSandbox -bool YES`
    static var tokenSandboxEnabled: Bool {
        FileManager.default.isExecutableFile(atPath: sandboxExecPath)
            && !UserDefaults.standard.bool(forKey: "disableTokenSandbox")
    }

    /// Command-line arguments for ngateconsoleclient. The interesting bit
    /// is what is **not** here: no `-u`, `-p`, `-H`, `-P`, no URL. All
    /// credentials and the endpoint URL live in the per-process config
    /// file (see `TunnelConfigFile`), so an attacker reading `ps` output
    /// gets nothing but the path to a 0600-mode file they can't read.
    ///
    ///   - `-c`         path to the temp config file
    ///   - `-N`         non-interactive — fail rather than blocking on a
    ///                  TTY prompt for missing fields
    ///   - `-vvvv`      verbose level 4; required because DNS Helper parses
    ///                  gateway DNS data from verbose ngate output
    private func makeArgs(configFilePath: String) -> [String] {
        return ["-c", configFilePath, "-N", "-vvvv"]
    }
}

enum WarmAdoption {
    /// The warm process was handed over and released; it is now connecting.
    case adopted
    /// A warm process existed but was built from different settings; it was discarded.
    case stale
    /// No usable warm process; the caller should start one normally.
    case unavailable
}

final class TunnelProcessManager: @unchecked Sendable {
    private var processes: [UUID: TunnelProcess] = [:]
    /// Pre-warmed clients, held at the gate and deliberately kept out of
    /// `processes` so the tunnel state machine (watchdog, status, alerts)
    /// never sees them until a Connect adopts one.
    private var warm: [UUID: (process: TunnelProcess, signature: String, startedAt: Date)] = [:]
    private var intentionalKills = Set<ObjectIdentifier>()
    private let queue = DispatchQueue(label: "Ngate2VPN.ProcessManager")

    /// Starts a pre-warmed client for the tunnel. `signature` identifies the
    /// exact configuration it was built from. `onExit` is called (with
    /// `intentional == true` for kills we requested) when it goes away
    /// before being adopted. Returns false if pre-warming isn't possible or
    /// the tunnel already has a process.
    @discardableResult
    func prewarm(
        tunnelID: UUID,
        binaryPath: String,
        configuration: TunnelConfiguration,
        signature: String,
        onExit: @escaping @Sendable (Int32, Bool) -> Void
    ) throws -> Bool {
        guard GateSupport.libraryURL != nil else { return false }
        let (existing, hasWarm) = queue.sync { (processes[tunnelID], warm[tunnelID] != nil) }
        guard !hasWarm else { return false }
        // A client that is shutting down (user pressed Disconnect) doesn't
        // block warming its replacement — that overlap is the whole point.
        if let existing, existing.currentState() != .stopping { return false }

        let created = TunnelProcess(
            label: "Ngate2VPN.Warm.\(tunnelID.uuidString)",
            onOutput: { _ in },
            onStateChange: { _ in },
            onExit: { _ in }
        )
        let key = ObjectIdentifier(created)
        created.setExitHandler { [weak self] code in
            guard let self else { return }
            self.queue.async {
                if let entry = self.warm[tunnelID], ObjectIdentifier(entry.process) == key {
                    self.warm.removeValue(forKey: tunnelID)
                }
                let intentional = self.intentionalKills.remove(key) != nil
                onExit(code, intentional)
            }
        }

        queue.sync { warm[tunnelID] = (created, signature, Date()) }
        do {
            try created.start(binaryPath: binaryPath, configuration: configuration, gated: true)
        } catch {
            queue.sync {
                if let entry = warm[tunnelID], ObjectIdentifier(entry.process) == key {
                    warm.removeValue(forKey: tunnelID)
                }
            }
            throw error
        }
        return true
    }

    /// Turns a warm process into the tunnel's live process and releases its
    /// gate, so it proceeds straight to connecting.
    func adoptWarm(
        tunnelID: UUID,
        signature: String,
        onOutput: @escaping @Sendable (String) -> Void,
        onStateChange: @escaping @Sendable (TunnelState) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) -> WarmAdoption {
        guard let entry = queue.sync(execute: { warm[tunnelID] }) else { return .unavailable }
        if entry.signature != signature {
            discardWarm(tunnelID: tunnelID)
            return .stale
        }

        let key = ObjectIdentifier(entry.process)
        queue.sync {
            warm.removeValue(forKey: tunnelID)
            processes[tunnelID] = entry.process
        }
        let adopted = entry.process.adopt(
            onOutput: onOutput,
            onStateChange: onStateChange,
            onExit: { [weak self] code in
                if let self {
                    self.queue.async {
                        if let current = self.processes[tunnelID], ObjectIdentifier(current) == key {
                            self.processes.removeValue(forKey: tunnelID)
                        }
                    }
                }
                onExit(code)
            }
        )
        if adopted { return .adopted }

        queue.sync {
            if let current = processes[tunnelID], ObjectIdentifier(current) == key {
                processes.removeValue(forKey: tunnelID)
            }
            intentionalKills.insert(key)
        }
        entry.process.discardWarm()
        return .unavailable
    }

    func hasWarm(tunnelID: UUID) -> Bool {
        queue.sync { warm[tunnelID] != nil }
    }

    /// Tunnels whose warm client has been held for longer than `age` seconds.
    func warmTunnelIDs(olderThan age: TimeInterval) -> [UUID] {
        let cutoff = Date().addingTimeInterval(-age)
        return queue.sync { warm.filter { $0.value.startedAt <= cutoff }.map(\.key) }
    }

    func discardWarm(tunnelID: UUID) {
        let process: TunnelProcess? = queue.sync {
            guard let entry = warm.removeValue(forKey: tunnelID) else { return nil }
            intentionalKills.insert(ObjectIdentifier(entry.process))
            return entry.process
        }
        process?.discardWarm()
    }

    func discardAllWarm() {
        let all: [TunnelProcess] = queue.sync {
            let processes = warm.values.map(\.process)
            processes.forEach { intentionalKills.insert(ObjectIdentifier($0)) }
            warm.removeAll()
            return processes
        }
        all.forEach { $0.discardWarm() }
    }

    func launch(
        tunnelID: UUID,
        binaryPath: String,
        configuration: TunnelConfiguration,
        onOutput: @escaping @Sendable (String) -> Void,
        onStateChange: @escaping @Sendable (TunnelState) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        // Track whether we created a new process in this call,
        // so we only clean it up on failure if we own it.
        var wasCreated = false
        let process = queue.sync { () -> TunnelProcess in
            if let existing = processes[tunnelID] {
                return existing
            }

            wasCreated = true
            let created = TunnelProcess(
                label: "Ngate2VPN.Process.\(tunnelID.uuidString)",
                onOutput: onOutput,
                onStateChange: onStateChange,
                onExit: { [weak self] code in
                    guard let self else {
                        onExit(code)
                        return
                    }
                    self.queue.async {
                        self.processes.removeValue(forKey: tunnelID)
                    }
                    onExit(code)
                }
            )
            processes[tunnelID] = created
            return created
        }

        do {
            try process.start(binaryPath: binaryPath, configuration: configuration)
        } catch {
            // Only remove from the dictionary if we just created this process.
            // If it already existed before this call, leave it intact.
            if wasCreated {
                queue.async { [weak self] in
                    self?.processes.removeValue(forKey: tunnelID)
                }
            }
            throw error
        }
    }

    func terminate(tunnelID: UUID) {
        queue.sync {
            processes[tunnelID]?.stop()
        }
    }

    func terminateAndWait(tunnelID: UUID, timeout: TimeInterval = 7) -> Bool {
        let process = queue.sync { processes[tunnelID] }
        return process?.stopAndWait(timeout: timeout) ?? true
    }

    func forceKill(tunnelID: UUID) {
        queue.sync {
            processes[tunnelID]?.forceKill()
        }
    }

    func state(for tunnelID: UUID) -> TunnelState? {
        queue.sync { processes[tunnelID]?.currentState() }
    }

    func terminateAll() {
        discardAllWarm()
        let activeProcesses = queue.sync { Array(processes.values) }
        activeProcesses.forEach { $0.stop() }
    }
}
