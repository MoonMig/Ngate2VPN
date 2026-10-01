import Foundation
import IOKit

/// Support for pre-warmed (gated) ngateconsoleclient processes. See
/// `Support/ngategate.c` for the injected library that does the holding.
enum GateSupport {

    /// ngateconsoleclient abandons a login ~2 min after it started ("Transaction
    /// timeout happened while connecting to gate"), even if it is being held at
    /// the gate. `operationsTimeout` (milliseconds) raises that limit for warm
    /// clients; connectionsTimeout does not help. Measured: default survives
    /// 100 s but not 200 s; 1_000_000 ms survived 400 s.
    static let warmOperationsTimeoutMs = 1_200_000

    /// Warm clients older than this are replaced, so they are always well
    /// inside `warmOperationsTimeoutMs` and adopted tunnels don't carry a huge
    /// timeout for long.
    static let maxWarmAge: TimeInterval = 600

    /// The interposer library, or nil if it isn't bundled (e.g. `swift run`),
    /// in which case pre-warming is simply unavailable.
    static var libraryURL: URL? {
        if let override = ProcessInfo.processInfo.environment["NGATE2VPN_GATE_LIB"],
           FileManager.default.isReadableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.url(forResource: "libngategate", withExtension: "dylib")
    }

    /// A fresh, not-yet-existing path. The gate is "released" by creating a
    /// file at this path.
    static func makeGateFileURL() throws -> URL {
        let dir = gatesDirectory()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir.appendingPathComponent("\(UUID().uuidString).gate")
    }

    static func removeAllStaleGates() {
        let dir = gatesDirectory()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }
        for url in contents where url.pathExtension == "gate" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func gatesDirectory() -> URL {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return cache
            .appendingPathComponent("Ngate2VPN", isDirectory: true)
            .appendingPathComponent("gates", isDirectory: true)
    }
}

/// Pure decision logic behind `TokenMonitor`'s "ignore a brief disappearance"
/// debounce, split out so it can be unit-tested without IOKit or real timers.
/// This type owns no timer: the caller schedules the actual delay and reports
/// back what the raw presence was when it fired.
struct TokenPresenceDebouncer: Equatable {
    private(set) var hasReportedInitial = false
    private(set) var lastReported: Bool?
    /// True while a "removed" report is waiting on a scheduled re-check.
    private(set) var removalPending = false

    enum Action: Equatable {
        /// Tell the caller the presence actually changed.
        case report(Bool)
        /// Schedule a re-check after the debounce delay and call
        /// `removalCheckFired` with the presence observed then.
        case scheduleRemovalCheck
        case none
    }

    /// Called with the raw, just-observed presence (IOKit's current count > 0).
    mutating func observe(present: Bool) -> Action {
        if present {
            // Any sign of presence cancels a pending removal check — this is
            // what swallows a remove-then-reinsert blip before it is ever
            // reported: the stale check later fires into `removalCheckFired`
            // with `removalPending` already false.
            removalPending = false
            return reportIfChanged(true)
        }
        guard hasReportedInitial else {
            // Reported once immediately after start, present or not — unlike
            // later transitions, there is no prior state a blip could be
            // mistaken for.
            return reportIfChanged(false)
        }
        guard lastReported != false else { return .none }   // already reported absent
        removalPending = true
        return .scheduleRemovalCheck
    }

    /// Called when a scheduled removal check fires, with the raw presence
    /// re-observed at that moment (it may have flipped back already, or have
    /// gone through another blip since).
    mutating func removalCheckFired(presentNow: Bool) -> Action {
        defer { removalPending = false }
        guard removalPending, !presentNow else { return .none }
        return reportIfChanged(false)
    }

    private mutating func reportIfChanged(_ present: Bool) -> Action {
        hasReportedInitial = true
        guard lastReported != present else { return .none }
        lastReported = present
        return .report(present)
    }
}

/// Reports whether a smartcard token/reader (USB CCID interface, class 0x0B)
/// is plugged in, and calls back on the main queue when that changes.
/// Always calls back once shortly after `start` with the initial state.
final class TokenMonitor: @unchecked Sendable {
    private var port: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var count = 0
    private var debouncer = TokenPresenceDebouncer()
    private var pendingRemovalCheck: DispatchWorkItem?
    private var onChange: (@Sendable (Bool) -> Void)?

    /// A reader that disappears for less than this and comes back on its own
    /// (seen in the field: USB power-management blips, re-enumeration around
    /// display sleep/wake on some hubs/docks) is treated as if nothing
    /// happened. Without this, every such blip tore down and rebuilt every
    /// certificate tunnel's pre-warmed client (~12 s of token reads each),
    /// often dozens of times a day with the token never actually having left.
    private let removalDebounce: TimeInterval = 2.0

    func start(onChange: @escaping @Sendable (Bool) -> Void) {
        self.onChange = onChange
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            onChange(false)
            return
        }
        self.port = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let refCon = Unmanaged.passUnretained(self).toOpaque()

        let added: IOServiceMatchingCallback = { refCon, iterator in
            guard let refCon else { return }
            Unmanaged<TokenMonitor>.fromOpaque(refCon).takeUnretainedValue().drain(iterator, delta: 1)
        }
        let removed: IOServiceMatchingCallback = { refCon, iterator in
            guard let refCon else { return }
            Unmanaged<TokenMonitor>.fromOpaque(refCon).takeUnretainedValue().drain(iterator, delta: -1)
        }

        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, Self.matching(), added, refCon, &addedIterator)
        drain(addedIterator, delta: 1)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, Self.matching(), removed, refCon, &removedIterator)
        drain(removedIterator, delta: -1)
    }

    private static func matching() -> CFDictionary {
        [
            "IOProviderClass": "IOUSBHostInterface",
            "IOPropertyMatch": ["bInterfaceClass": 11],
        ] as CFDictionary
    }

    private func drain(_ iterator: io_iterator_t, delta: Int) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
            count = max(0, count + delta)
        }
        switch debouncer.observe(present: count > 0) {
        case .report(let present):
            onChange?(present)
        case .scheduleRemovalCheck:
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if case .report(let present) = self.debouncer.removalCheckFired(presentNow: self.count > 0) {
                    self.onChange?(present)
                }
            }
            pendingRemovalCheck?.cancel()
            pendingRemovalCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + removalDebounce, execute: work)
        case .none:
            break
        }
    }
}
