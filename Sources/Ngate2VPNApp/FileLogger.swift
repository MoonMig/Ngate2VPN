import Foundation

// MARK: - FileLogger

/// Public, Sendable entry point for tunnel logging.
///
/// `append(line:)` is synchronous from the caller's point of view — it
/// just yields the line into an internal `AsyncStream` and returns. A
/// single long-lived consumer task (started in `init`) drains the stream
/// in FIFO order and forwards each line to the file-writer actor.
///
/// **Why AsyncStream and not `Task { await actor.write(...) }`?** The
/// previous design spawned a fresh Task on every log line. With ngate
/// running at `-vvvv` and several tunnels active that meant tens of
/// thousands of Tasks per minute — each one allocates its continuation
/// frame, gets enqueued on the cooperative pool, then competes for the
/// actor's executor. It worked, but:
///   - Strict FIFO order between siblings was not guaranteed: two Tasks
///     suspended at the same `await` could be resumed out of order.
///   - The peak memory cost grew with the in-flight Task count, which
///     could spike under bursty output.
///   - The runtime scheduler took on an avoidable amount of work.
///
/// One stream + one consumer fixes all three: lines arrive at the
/// consumer in append order, no per-line Task is allocated, and the
/// stream's bounded buffering caps memory under backpressure.
///
/// Architecture:
///
///     Caller  →  FileLogger.append()  →  continuation.yield(line)
///                                                ↓
///                                       AsyncStream<String>
///                                                ↓
///                                       single consumer Task
///                                                ↓
///                                       LogWriterActor  →  disk
///
/// Because `FileLogger` itself is reference-typed but immutable after
/// init (the continuation is captured and never re-assigned), it is
/// trivially `Sendable`.

final class FileLogger: @unchecked Sendable {

    private let actor: LogWriterActor
    private let continuation: AsyncStream<String>.Continuation
    /// Holds the consumer alive for the lifetime of the logger. We don't
    /// cancel it explicitly — closing the stream via `continuation.finish()`
    /// in `deinit` lets the `for await` loop fall through naturally, after
    /// which the task completes and is deallocated. Keeping a strong
    /// reference here just stops Swift from warning about an unused result
    /// from `Task.detached`.
    private let consumerTask: Task<Void, Never>

    init(tunnelID: UUID) {
        let actor = LogWriterActor(tunnelID: tunnelID)
        self.actor = actor

        // Bounded buffer — if the consumer falls behind (e.g. the disk
        // is slow, or we got a sudden burst from `-vvvv`), drop the
        // OLDEST queued entries instead of growing memory unboundedly.
        // 4 096 lines is more than two seconds of even pathological
        // ngate output; in normal operation the buffer is empty between
        // writes. The dropped lines are still visible in the in-memory
        // journal, only the on-disk archive misses them — which is the
        // right tradeoff (a slow disk shouldn't crash us).
        //
        // The two-step capture pattern (var continuation outside the
        // closure, populated on first invocation) is what AsyncStream
        // requires before `makeStream(of:)` was added in Swift 5.9 /
        // macOS 14. We target macOS 13, so we use the older form.
        var capturedContinuation: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String>(bufferingPolicy: .bufferingNewest(4_096)) { cont in
            capturedContinuation = cont
        }
        self.continuation = capturedContinuation

        // ONE long-lived consumer for the lifetime of this logger. It
        // reads lines in FIFO order and feeds them through the actor's
        // serial executor, so file I/O remains race-free without any
        // per-line Task allocation.
        self.consumerTask = Task.detached(priority: .utility) {
            for await line in stream {
                await actor.write(line: line)
            }
        }

    }

    deinit {
        // Closing the stream lets the consumer's `for await` loop fall
        // through naturally — no force-cancel needed. The task then
        // exits, releasing the actor.
        continuation.finish()
    }

    /// Fire-and-forget. Returns immediately after enqueueing the line;
    /// the actual file write happens later on the consumer's executor.
    /// Order is preserved across all calls into the same logger.
    func append(line: String) {
        continuation.yield(line)
    }
}

// MARK: - LogWriterActor

/// All file I/O is isolated to this actor.
/// Swift's actor model gives us a serial execution context for free —
/// no DispatchQueue, no locks, no @unchecked Sendable required.

actor LogWriterActor {

    // MARK: Configuration

    private let maxFileSizeBytes: UInt64 = 5 * 1024 * 1024  // 5 MB

    // MARK: State (actor-isolated — safe without any additional locking)

    private let fileURL: URL
    private var handle: FileHandle?

    // MARK: Init

    init(tunnelID: UUID) {
        self.fileURL = Self.logsDirectory()
            .appendingPathComponent("tunnel_\(tunnelID.uuidString).log")
        // Handle opens on first write — avoids blocking the init caller.
    }

    // MARK: - Public write entry point

    func write(line: String) async {
        // Lazy open: create the file and handle on first use.
        if handle == nil {
            await openHandle()
        }

        guard let data = (line + "\n").data(using: .utf8) else {
            await ErrorLog.shared.record("LogWriterActor: UTF-8 encoding failed — \(line.prefix(80))")
            return
        }

        // Rotation check before every write — keeps the active file under the limit.
        if await shouldRotate() {
            await rotate()
        }

        guard let handle else {
            await ErrorLog.shared.record("LogWriterActor: no open handle for \(fileURL.lastPathComponent)")
            return
        }

        do {
            try handle.write(contentsOf: data)
        } catch {
            await ErrorLog.shared.record("LogWriterActor: write failed — \(error.localizedDescription)")
            await reopenHandle()
        }
    }

    // MARK: - Rotation

    private func shouldRotate() async -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        return size >= maxFileSizeBytes
    }

    /// Atomically moves the live log to a timestamped backup, then opens a fresh file.
    /// moveItem on the same volume is atomic — no byte is lost between old and new file.
    private func rotate() async {
        await closeHandle()

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupName = fileURL.deletingPathExtension().lastPathComponent
            + "_\(timestamp).log"
        let backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(backupName)

        do {
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
        } catch {
            await ErrorLog.shared.record("LogWriterActor: rotation move failed — \(error.localizedDescription)")
        }

        // Always open fresh — even if the move failed, we recover gracefully.
        await openHandle()
    }

    // MARK: - Handle lifecycle

    private func openHandle() async {
        do {
            try Self.prepareFile(at: fileURL)
            let h = try FileHandle(forWritingTo: fileURL)
            _ = try h.seekToEnd()
            handle = h
        } catch {
            handle = nil
            await ErrorLog.shared.record("LogWriterActor: could not open \(fileURL.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    private func closeHandle() async {
        try? handle?.synchronize()   // flush OS write buffer to disk
        try? handle?.close()
        handle = nil
    }

    private func reopenHandle() async {
        await closeHandle()
        await openHandle()
    }

    // MARK: - File system helpers

    private static func logsDirectory() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("NgateVPN", isDirectory: true)
            .appendingPathComponent("logs",    isDirectory: true)
    }

    private static func prepareFile(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: logsDirectory(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    // MARK: - Cleanup (static — runs in a detached Task, not on this actor's executor)

    /// Deletes timestamped backup logs older than `days` days.
    /// Safe to call from any context; does not touch the actor's live file.
    static func deleteOldLogs(olderThanDays days: Int) async {
        let directory = logsDirectory()
        guard let contents = try? FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
        else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        for url in contents where url.pathExtension == "log" {
            // Active log files have no timestamp; skip them.
            guard url.deletingPathExtension().lastPathComponent.contains("_") else { continue }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            guard created < cutoff else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                await ErrorLog.shared.record("LogWriterActor: cleanup failed for \(url.lastPathComponent) — \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - ErrorLog

/// Actor-based error sink for logging failures that occur inside the logging system.
///
/// Writes every error to NSLog (always available, even when disk I/O is broken)
/// and keeps the last 100 messages in memory for in-app diagnostics.
///
/// Using an actor instead of a DispatchQueue-backed class gives us:
/// - Automatic Sendable conformance
/// - No manual synchronisation
/// - Clear async boundary at every call site

actor ErrorLog {

    static let shared = ErrorLog()

    private(set) var recentErrors: [String] = []
    private let maxStoredErrors = 100

    private init() {}

    func record(_ message: String) {
        let entry = "[\(formattedNow())] \(message)"
        NSLog("[NgateVPN] %@", entry)
        recentErrors.append(entry)
        if recentErrors.count > maxStoredErrors {
            recentErrors.removeFirst(recentErrors.count - maxStoredErrors)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private func formattedNow() -> String {
        Self.timestampFormatter.string(from: Date())
    }
}
