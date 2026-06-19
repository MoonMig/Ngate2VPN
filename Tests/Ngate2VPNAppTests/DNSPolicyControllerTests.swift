import XCTest
@testable import Ngate2VPNApp

@MainActor
final class DNSPolicyControllerTests: XCTestCase {
    func testNewestTunnelWinsDomainConflict() {
        let controller = DNSPolicyController()
        let olderID = UUID()
        let newerID = UUID()

        controller.upsert(
            tunnelID: olderID,
            dnsServers: ["10.0.0.1"],
            matchDomains: ["corp.local"],
            connectedAt: Date(timeIntervalSince1970: 100)
        )
        controller.upsert(
            tunnelID: newerID,
            dnsServers: ["10.0.0.2"],
            matchDomains: ["CORP.local"],
            connectedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(controller.policy.scopedResolvers.count, 1)
        XCTAssertEqual(controller.policy.scopedResolvers.first?.matchDomains, ["corp.local"])
        XCTAssertEqual(controller.policy.scopedResolvers.first?.dnsServers, ["10.0.0.2"])
    }

    func testRemovingNewestTunnelRestoresPreviousDomainOwner() {
        let controller = DNSPolicyController()
        let olderID = UUID()
        let newerID = UUID()

        controller.upsert(
            tunnelID: olderID,
            dnsServers: ["10.0.0.1"],
            matchDomains: ["corp.local"],
            connectedAt: Date(timeIntervalSince1970: 100)
        )
        controller.upsert(
            tunnelID: newerID,
            dnsServers: ["10.0.0.2"],
            matchDomains: ["corp.local"],
            connectedAt: Date(timeIntervalSince1970: 200)
        )

        controller.remove(tunnelID: newerID)

        XCTAssertEqual(controller.policy.scopedResolvers.count, 1)
        XCTAssertEqual(controller.policy.scopedResolvers.first?.dnsServers, ["10.0.0.1"])
    }

    func testHoldDefaultDNSSuppressesDefaultResolver() {
        let controller = DNSPolicyController()
        controller.holdDefaultDNS = true

        controller.upsert(
            tunnelID: UUID(),
            dnsServers: ["10.0.0.53"],
            matchDomains: []
        )

        XCTAssertNil(controller.policy.defaultResolver)
    }

    func testDefaultResolverAppearsWhenHoldDefaultDNSIsOff() {
        let controller = DNSPolicyController()
        controller.holdDefaultDNS = false

        controller.upsert(
            tunnelID: UUID(),
            dnsServers: ["10.0.0.53"],
            matchDomains: []
        )

        XCTAssertEqual(controller.policy.defaultResolver, ["10.0.0.53"])
    }

    // MARK: - NgateGatewayResponseParser

    private func makeLines(_ json: String, level: String = "Debug") -> [String] {
        json.split(separator: "\n", omittingEmptySubsequences: false).map {
            "[12:00:00] Jan 01 12:00:00.000 \(level)     \($0)"
        }
    }

    private let sampleJSON = """
        {
            "IPTunnels" : [
                {
                    "DNSs" : ["10.0.0.1"],
                    "SearchDomains" : ["corp.local"]
                }
            ]
        }
        """

    func testParserExtractsBasicDNS() {
        let parser = NgateGatewayResponseParser()
        var result: [NgateGatewayResponseParser.ExtractedTunnel] = []
        for line in makeLines(sampleJSON) {
            result += parser.feed(line)
        }
        XCTAssertEqual(result.first?.dnsServers, ["10.0.0.1"])
        XCTAssertEqual(result.first?.searchDomains, ["corp.local"])
    }

    func testParserAcceptsLowercaseDebug() {
        let parser = NgateGatewayResponseParser()
        var result: [NgateGatewayResponseParser.ExtractedTunnel] = []
        for line in makeLines(sampleJSON, level: "debug") {
            result += parser.feed(line)
        }
        XCTAssertEqual(result.first?.dnsServers, ["10.0.0.1"])
        XCTAssertEqual(result.first?.searchDomains, ["corp.local"])
    }

    func testParserAcceptsUppercaseDebug() {
        let parser = NgateGatewayResponseParser()
        var result: [NgateGatewayResponseParser.ExtractedTunnel] = []
        for line in makeLines(sampleJSON, level: "DEBUG") {
            result += parser.feed(line)
        }
        XCTAssertEqual(result.first?.dnsServers, ["10.0.0.1"])
        XCTAssertEqual(result.first?.searchDomains, ["corp.local"])
    }

    func testParserAcceptsJsonAfterPrefixOnSameLine() {
        // Gateway logs "Response: {" rather than "{" as the first character.
        let parser = NgateGatewayResponseParser()
        var result: [NgateGatewayResponseParser.ExtractedTunnel] = []
        let json = sampleJSON.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, jsonLine) in json.enumerated() {
            let payload = i == 0 ? "Gateway response: \(jsonLine)" : String(jsonLine)
            let line = "[12:00:00] Jan 01 12:00:00.000 Debug     \(payload)"
            result += parser.feed(line)
        }
        XCTAssertEqual(result.first?.dnsServers, ["10.0.0.1"])
        XCTAssertEqual(result.first?.searchDomains, ["corp.local"])
    }

    func testParserAcceptsInfoLevel() {
        let parser = NgateGatewayResponseParser()
        var result: [NgateGatewayResponseParser.ExtractedTunnel] = []
        for line in makeLines(sampleJSON, level: "Info") {
            result += parser.feed(line)
        }
        XCTAssertEqual(result.first?.dnsServers, ["10.0.0.1"])
        XCTAssertEqual(result.first?.searchDomains, ["corp.local"])
    }

    func testParserAcceptsWarningLevel() {
        let parser = NgateGatewayResponseParser()
        var result: [NgateGatewayResponseParser.ExtractedTunnel] = []
        for line in makeLines(sampleJSON, level: "Warning") {
            result += parser.feed(line)
        }
        XCTAssertEqual(result.first?.dnsServers, ["10.0.0.1"])
        XCTAssertEqual(result.first?.searchDomains, ["corp.local"])
    }

    func testParserExtractsDNSFromTopLevelFields() {
        // Some gateway versions place DNSs/SearchDomains at the top level,
        // not nested inside IPTunnels entries.
        let json = """
            {
                "IPTunnels" : [
                    {
                        "dst" : "10.0.0.0/24",
                        "src" : "10.0.0.100"
                    }
                ],
                "DNSs" : ["10.0.0.53"],
                "SearchDomains" : ["domain.ru"]
            }
            """
        let parser = NgateGatewayResponseParser()
        var result: [NgateGatewayResponseParser.ExtractedTunnel] = []
        for line in makeLines(json) { result += parser.feed(line) }
        XCTAssertEqual(result.first?.dnsServers, ["10.0.0.53"])
        XCTAssertEqual(result.first?.searchDomains, ["domain.ru"])
    }

    func testParserAcceptsRawJsonWithoutLogPrefix() {
        // Some ngateconsoleclient versions output the JSON block as plain text
        // with no log-level prefix at all.
        let parser = NgateGatewayResponseParser()
        var result: [NgateGatewayResponseParser.ExtractedTunnel] = []
        for line in sampleJSON.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            result += parser.feed(line)
        }
        XCTAssertEqual(result.first?.dnsServers, ["10.0.0.1"])
        XCTAssertEqual(result.first?.searchDomains, ["corp.local"])
    }

    func testParserAcceptsNoTimestampDebugPrefix() {
        // Some ngateconsoleclient versions log the HTTP response body as a
        // sequence of "Debug     <line>" lines — level keyword at column 0,
        // no preceding date/time.  strip() must strip the "Debug" prefix so
        // the buffer contains pure JSON, not "Debug         \"key\" : …".
        let parser = NgateGatewayResponseParser()
        var result: [NgateGatewayResponseParser.ExtractedTunnel] = []
        let lines = sampleJSON.split(separator: "\n", omittingEmptySubsequences: false).map {
            "Debug     \($0)"
        }
        // Precede JSON with HTTP response headers (same format as real output).
        let preamble = [
            "Debug     HTTP/1.1 200 OK",
            "Debug     Content-Type: text/html",
            "Debug     ",
        ]
        for line in preamble + lines {
            result += parser.feed(line)
        }
        XCTAssertEqual(result.first?.dnsServers, ["10.0.0.1"])
        XCTAssertEqual(result.first?.searchDomains, ["corp.local"])
    }
}
