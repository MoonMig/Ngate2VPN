import Foundation
import IOKit

/// Support for pre-warmed (gated) ngateconsoleclient processes. See
/// `Support/ngategate.c` for the injected library that does the holding.
enum GateSupport {

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

/// Reports whether a smartcard token/reader (USB CCID interface, class 0x0B)
/// is plugged in, and calls back on the main queue when that changes.
/// Always calls back once shortly after `start` with the initial state.
final class TokenMonitor: @unchecked Sendable {
    private var port: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var count = 0
    private var lastPresent: Bool?
    private var onChange: (@Sendable (Bool) -> Void)?

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
        let present = count > 0
        if lastPresent != present {
            lastPresent = present
            onChange?(present)
        }
    }
}
