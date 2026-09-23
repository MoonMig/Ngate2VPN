import XCTest
@testable import Ngate2VPNApp

final class PersistenceAndProxyTests: XCTestCase {

    /// A profile saved by an older build lacks newer keys; it must still load.
    func testOldProfileJSONWithoutNewerFieldsStillDecodes() throws {
        let json = """
        {"binaryPath":"/opt/x","hideDockOnClose":true,
         "tunnels":[{"id":"00000000-0000-4000-8000-000000000001","title":"Example",
                     "endpointURL":"https://gw/x","authMethod":"credentials","username":"u"}]}
        """
        let state = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
        XCTAssertEqual(state.tunnels.count, 1)
        XCTAssertEqual(state.tunnels[0].title, "Example")
        XCTAssertEqual(state.tunnels[0].authMethod, .credentials)
        XCTAssertEqual(state.tunnels[0].username, "u")
        XCTAssertFalse(state.tunnels[0].autoReconnect)
        XCTAssertEqual(state.tunnels[0].serialNumber, "")
    }

    func testEmptyStateObjectDecodesToDefaults() throws {
        let state = try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))
        XCTAssertTrue(state.tunnels.isEmpty)
        XCTAssertEqual(state.binaryPath, "/opt/cprongate/ngateconsoleclient")
    }

    func testRoundTripPreservesProfile() throws {
        let t = TunnelConfiguration(title: "Example B", endpointURL: "https://gw", authMethod: .certificate,
                                    serialNumber: "abc", autoReconnect: true)
        let data = try JSONEncoder().encode(PersistedState(binaryPath: "/b", hideDockOnClose: false, tunnels: [t]))
        let back = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertEqual(back.tunnels, [t])
    }

    func testProxyResponseParsing() {
        let p = ProxyPreflight.Proxy(host: "127.0.0.1", port: 1082)
        XCTAssertEqual(ProxyPreflight.parse(Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8), proxy: p), .ok(p))
        XCTAssertEqual(ProxyPreflight.parse(Data("HTTP/1.1 503 Service Unavailable\r\n\r\n".utf8), proxy: p), .rejected(p, status: 503))
        XCTAssertEqual(ProxyPreflight.parse(Data("garbage".utf8), proxy: p), .noResponse(p))
        XCTAssertEqual(ProxyPreflight.parse(nil, proxy: p), .noResponse(p))
    }

    func testProbeReportsUnreachableProxy() async {
        // Port 9 (discard) is closed on a normal machine.
        let p = ProxyPreflight.Proxy(host: "127.0.0.1", port: 9)
        let outcome = await ProxyPreflight.probe(p, targetHost: "example.invalid", targetPort: 443, timeout: 4)
        XCTAssertNotEqual(outcome, .ok(p))
        XCTAssertNotNil(ProxyPreflight.warning(for: outcome, host: "example.invalid"))
    }

    func testNoWarningWhenProxyIsFine() {
        let p = ProxyPreflight.Proxy(host: "h", port: 1)
        XCTAssertNil(ProxyPreflight.warning(for: .ok(p), host: "g"))
    }
}

final class PersistenceScrubTests: XCTestCase {
    func testScrubbedBackupNeverContainsSecrets() throws {
        let legacy = """
        {"binaryPath":"/b","tunnels":[{"title":"Example","pinCode":"1234","password":"hunter2","username":"u"}]}
        """
        let scrubbed = TunnelPersistence.scrubbed(Data(legacy.utf8))
        let text = String(decoding: scrubbed, as: UTF8.self)
        XCTAssertFalse(text.contains("1234"))
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertTrue(text.contains("Example"))
        XCTAssertTrue(text.contains("\"username\""))
    }

    func testScrubbedDropsUnparseableData() {
        XCTAssertTrue(TunnelPersistence.scrubbed(Data("not json {".utf8)).isEmpty)
    }
}
