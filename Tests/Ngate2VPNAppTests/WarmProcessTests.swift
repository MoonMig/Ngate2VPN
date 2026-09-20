import XCTest
@testable import Ngate2VPNApp

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined() }
}

/// Runs the real ngateconsoleclient against an unreachable local address, so
/// no gateway is ever contacted. Skipped when the client or clang is missing.
final class WarmProcessTests: XCTestCase {

    private let clientPath = "/opt/cprongate/ngateconsoleclient"

    private func buildGateLibrary() throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Support/ngategate.c").path
        let out = NSTemporaryDirectory() + "libngategate-test-\(UUID().uuidString).dylib"
        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        clang.arguments = ["-dynamiclib", "-o", out, source]
        try clang.run()
        clang.waitUntilExit()
        guard clang.terminationStatus == 0 else { throw XCTSkip("clang failed to build the gate library") }
        return out
    }

    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    func testWarmClientIsHeldUntilAdoptedThenConnects() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: clientPath), "ngateconsoleclient not installed")
        let library = try buildGateLibrary()
        setenv("NGATE2VPN_GATE_LIB", library, 1)
        defer { unsetenv("NGATE2VPN_GATE_LIB"); try? FileManager.default.removeItem(atPath: library) }

        // Password auth also exercises the sandbox-exec -> env -> client chain.
        let config = TunnelConfiguration(
            title: "warm-test", endpointURL: "https://127.0.0.1:9/x/",
            authMethod: .credentials, username: "u", password: "p"
        )
        let manager = TunnelProcessManager()
        // Wait for the exit so the client's temp config file is removed.
        defer { _ = manager.terminateAndWait(tunnelID: config.id) }

        let started = try manager.prewarm(
            tunnelID: config.id, binaryPath: clientPath, configuration: config,
            signature: "sig-1", onExit: { _, _ in })
        XCTAssertTrue(started)
        XCTAssertTrue(manager.hasWarm(tunnelID: config.id))

        // Let it finish initialising and reach the gate.
        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(manager.hasWarm(tunnelID: config.id), "held client must still be alive")

        let output = Collector()
        let adoption = manager.adoptWarm(
            tunnelID: config.id, signature: "sig-1",
            onOutput: { output.add($0) }, onStateChange: { _ in }, onExit: { _ in })
        guard case .adopted = adoption else { return XCTFail("expected adoption, got \(adoption)") }

        // Replayed output shows it was initialised but never reached the network.
        let replayed = output.text
        XCTAssertTrue(replayed.contains("All local certificates storages operational"), replayed)
        XCTAssertFalse(replayed.contains("Socket error"), "client must not have connected before release")

        // After release it proceeds to connect (and is refused by 127.0.0.1:9).
        XCTAssertTrue(waitFor(5) { output.text.contains("Socket error") }, "client did not proceed after release")
        XCTAssertFalse(manager.hasWarm(tunnelID: config.id), "adopted process is no longer warm")
    }

    func testReplacementCanBeWarmedWhileOldClientIsShuttingDown() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: clientPath), "ngateconsoleclient not installed")
        let library = try buildGateLibrary()
        setenv("NGATE2VPN_GATE_LIB", library, 1)
        defer { unsetenv("NGATE2VPN_GATE_LIB"); try? FileManager.default.removeItem(atPath: library) }

        // A local listener that never accepts, so the client hangs mid-connect
        // and stays alive until we stop it.
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 8), 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &len) }
        }
        let port = UInt16(bigEndian: addr.sin_port)

        let config = TunnelConfiguration(
            title: "warm-test", endpointURL: "https://127.0.0.1:\(port)/x/",
            authMethod: .credentials, username: "u", password: "p"
        )
        let manager = TunnelProcessManager()
        defer {
            manager.terminateAll()
            _ = manager.terminateAndWait(tunnelID: config.id)
            Thread.sleep(forTimeInterval: 1)
        }

        // A live (cold) client, as after a normal Connect.
        try manager.launch(tunnelID: config.id, binaryPath: clientPath, configuration: config,
                           onOutput: { _ in }, onStateChange: { _ in }, onExit: { _ in })
        XCTAssertTrue(waitFor(5) { manager.state(for: config.id) == .running })
        Thread.sleep(forTimeInterval: 1.5)

        // Warming is refused while that client is genuinely running…
        XCTAssertFalse(try manager.prewarm(tunnelID: config.id, binaryPath: clientPath, configuration: config,
                                           signature: "s", onExit: { _, _ in }))

        // …but allowed as soon as it is being stopped (Disconnect).
        manager.terminate(tunnelID: config.id)
        let started = try manager.prewarm(tunnelID: config.id, binaryPath: clientPath, configuration: config,
                                          signature: "s", onExit: { _, _ in })
        XCTAssertTrue(started, "replacement must be warmed during shutdown of the old client")
        XCTAssertTrue(manager.hasWarm(tunnelID: config.id))
    }

    func testWarmConfigRaisesTheClientLoginTimeoutButColdConfigDoesNot() throws {
        let config = TunnelConfiguration(
            title: "t", endpointURL: "https://127.0.0.1:9/x/",
            authMethod: .credentials, username: "u", password: "p"
        )
        let warm = try TunnelConfigFile.create(for: config, operationsTimeoutMs: GateSupport.warmOperationsTimeoutMs)
        let cold = try TunnelConfigFile.create(for: config)
        defer { warm.delete(); cold.delete() }

        let warmText = try String(contentsOf: warm.url, encoding: .utf8)
        let coldText = try String(contentsOf: cold.url, encoding: .utf8)
        XCTAssertTrue(warmText.contains("operationsTimeout=\(GateSupport.warmOperationsTimeoutMs)"))
        XCTAssertFalse(coldText.contains("operationsTimeout"))
    }

    func testWarmClientsReportTheirAgeSoStaleOnesCanBeRefreshed() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: clientPath), "ngateconsoleclient not installed")
        let library = try buildGateLibrary()
        setenv("NGATE2VPN_GATE_LIB", library, 1)
        defer { unsetenv("NGATE2VPN_GATE_LIB"); try? FileManager.default.removeItem(atPath: library) }

        let config = TunnelConfiguration(
            title: "warm-test", endpointURL: "https://127.0.0.1:9/x/",
            authMethod: .credentials, username: "u", password: "p"
        )
        let manager = TunnelProcessManager()
        defer { Thread.sleep(forTimeInterval: 1) }

        try manager.prewarm(tunnelID: config.id, binaryPath: clientPath, configuration: config,
                            signature: "s", onExit: { _, _ in })
        XCTAssertEqual(manager.warmTunnelIDs(olderThan: 3600), [], "a fresh client is not stale")
        XCTAssertEqual(manager.warmTunnelIDs(olderThan: 0), [config.id])
        manager.discardWarm(tunnelID: config.id)
        XCTAssertEqual(manager.warmTunnelIDs(olderThan: 0), [], "discarded clients are no longer tracked")
    }

    /// The client abandons a login ~2 min after start unless operationsTimeout
    /// is raised. Slow, so opt-in: NGATE2VPN_SLOW_TESTS=1 swift test --filter WarmProcessTests
    func testWarmClientSurvivesBeingHeldLongerThanTheClientsDefaultLoginTimeout() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NGATE2VPN_SLOW_TESTS"] == "1", "slow (~2.5 min); set NGATE2VPN_SLOW_TESTS=1")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: clientPath), "ngateconsoleclient not installed")
        let library = try buildGateLibrary()
        setenv("NGATE2VPN_GATE_LIB", library, 1)
        defer { unsetenv("NGATE2VPN_GATE_LIB"); try? FileManager.default.removeItem(atPath: library) }

        let config = TunnelConfiguration(
            title: "warm-test", endpointURL: "https://127.0.0.1:9/x/",
            authMethod: .credentials, username: "u", password: "p"
        )
        let manager = TunnelProcessManager()
        defer { _ = manager.terminateAndWait(tunnelID: config.id) }

        try manager.prewarm(tunnelID: config.id, binaryPath: clientPath, configuration: config,
                            signature: "s", onExit: { _, _ in })
        Thread.sleep(forTimeInterval: 150)   // default limit is ~120 s

        let output = Collector()
        let adoption = manager.adoptWarm(tunnelID: config.id, signature: "s",
                                         onOutput: { output.add($0) }, onStateChange: { _ in }, onExit: { _ in })
        guard case .adopted = adoption else { return XCTFail("warm client died while held: \(adoption)") }

        XCTAssertTrue(waitFor(5) { output.text.contains("Socket error") }, output.text)
        XCTAssertFalse(output.text.contains("Transaction timeout"), "client gave up while held at the gate")
    }

    func testStaleSignatureIsDiscardedNotAdopted() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: clientPath), "ngateconsoleclient not installed")
        let library = try buildGateLibrary()
        setenv("NGATE2VPN_GATE_LIB", library, 1)
        defer { unsetenv("NGATE2VPN_GATE_LIB"); try? FileManager.default.removeItem(atPath: library) }

        let config = TunnelConfiguration(
            title: "warm-test", endpointURL: "https://127.0.0.1:9/x/",
            authMethod: .credentials, username: "u", password: "p"
        )
        let manager = TunnelProcessManager()
        // The discarded client is killed asynchronously; give it time to exit
        // so its temp config file is cleaned up before the test ends.
        defer { Thread.sleep(forTimeInterval: 1) }

        try manager.prewarm(tunnelID: config.id, binaryPath: clientPath, configuration: config,
                            signature: "old", onExit: { _, _ in })
        let adoption = manager.adoptWarm(
            tunnelID: config.id, signature: "new",
            onOutput: { _ in }, onStateChange: { _ in }, onExit: { _ in })
        guard case .stale = adoption else { return XCTFail("expected stale, got \(adoption)") }
        XCTAssertFalse(manager.hasWarm(tunnelID: config.id))
    }
}
