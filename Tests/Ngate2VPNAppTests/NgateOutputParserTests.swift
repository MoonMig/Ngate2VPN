import XCTest
@testable import Ngate2VPNApp

final class NgateOutputParserTests: XCTestCase {
    func testClassifiesCertificateErrorsAsNonRetryable() {
        let error = NgateOutputParser.classifyError(
            from: "critical no certificates acquired by sha1 hash"
        )

        XCTAssertEqual(error, .certificateNotFound)
        XCTAssertFalse(error?.isRetryable ?? true)
    }

    func testDoesNotTreatSessionDestroyedCleanupAsRetryableError() {
        let error = NgateOutputParser.classifyError(
            from: "info vpn session destroyed"
        )

        XCTAssertNil(error)
    }

    func testClassifiesSessionRefreshFailureAsRetryable() {
        let error = NgateOutputParser.classifyError(
            from: "warning refreshtransaction failed"
        )

        XCTAssertEqual(error, .sessionRefreshFailed)
        XCTAssertTrue(error?.isRetryable ?? false)
    }

    func testClassifiesGatewayLogoutFailureAsRetryable() {
        let error = NgateOutputParser.classifyError(
            from: "warning unable to correctly logout from remote gate. vpn session closed."
        )

        XCTAssertEqual(error, .sessionRefreshFailed)
        XCTAssertTrue(error?.isRetryable ?? false)
    }

    func testExtractsClientAddressFromJsonFragment() {
        let address = NgateOutputParser.extractClientAddress(
            from: #"Debug {"ClientAddress":"10.10.0.42","Other":true}"#
        )

        XCTAssertEqual(address, "10.10.0.42")
    }
}
