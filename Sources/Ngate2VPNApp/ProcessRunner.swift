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
/// `certificateContainerPIN`, `verbose`, `journalVerbose`, `keepSession`.
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
    static func create(for configuration: TunnelConfiguration) throws -> TunnelConfigFile {
        try validateINIValues(configuration)

        let dir = configsDirectory()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let url = dir.appendingPathComponent("\(configuration.id.uuidString).cfg")
        let body = renderINI(for: configuration)

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

    private static func renderINI(for c: TunnelConfiguration) -> String {
        var lines: [String] = []
        // Header — useful when debugging via the file system; doesn't
        // change ngate's behaviour.
        lines.append("; Ngate2VPN tunnel configuration")
        lines.append("; \(c.title)")
        lines.append("; This file is regenerated on every connect and removed on disconnect.")
        lines.append("")
        lines.append("url=\(c.endpointURL)")

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
    private let onOutput: @Sendable (String) -> Void
    private let onStateChange: @Sendable (TunnelState) -> Void
    private let onExit: @Sendable (Int32) -> Void

    private var state: TunnelState = .stopped
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stopCompletion: DispatchSemaphore?
    /// Per-process credential file. Lives only for the duration of one
    /// ngateconsoleclient invocation, deleted in handleTermination().
    private var configFile: TunnelConfigFile?

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

    func start(binaryPath: String, configuration: TunnelConfiguration) throws {
        try queue.sync {
            guard state == .stopped else { throw TunnelProcessError.alreadyRunning }

            // Write a per-process config file with credentials. This
            // replaces what used to be command-line arguments, and is
            // the difference between credentials being visible to
            // every process via `ps` and being readable only by the
            // current user via a 0600-mode temp file.
            let configFile = try TunnelConfigFile.create(for: configuration)

            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = makeArgs(configFilePath: configFile.url.path)
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

            process.terminationHandler = { [weak self] finishedProcess in
                self?.handleTermination(process: finishedProcess)
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

    private func installReadabilityHandler(for handle: FileHandle) {
        handle.readabilityHandler = { [onOutput] readable in
            let data = readable.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            onOutput(text)
        }
    }

    private func handleTermination(process finishedProcess: Process) {
        queue.async {
            guard self.process === finishedProcess else { return }

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

final class TunnelProcessManager: @unchecked Sendable {
    private var processes: [UUID: TunnelProcess] = [:]
    private let queue = DispatchQueue(label: "Ngate2VPN.ProcessManager")

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
        let activeProcesses = queue.sync { Array(processes.values) }
        activeProcesses.forEach { $0.stop() }
    }
}
