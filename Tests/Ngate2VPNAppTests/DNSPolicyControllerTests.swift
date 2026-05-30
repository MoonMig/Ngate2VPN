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
}
