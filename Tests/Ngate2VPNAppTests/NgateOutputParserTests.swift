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

    func testClassifiesLoginTransactionTimeoutAsRetryable() {
        for line in [
            "critical vx0000000105fadd90 unable to login to remote gate in a reasonable time. stopping vpn connection.",
            "debug htx0000007bfee00d20 transaction timeout happened while connecting to gate. aborting connection and releasing ssl socket",
        ] {
            let error = NgateOutputParser.classifyError(from: line)
            XCTAssertEqual(error, .startupTimeout, line)
            XCTAssertTrue(error?.isRetryable ?? false)
        }
    }

    func testExtractsClientAddressFromJsonFragment() {
        let address = NgateOutputParser.extractClientAddress(
            from: #"Debug {"ClientAddress":"10.10.0.42","Other":true}"#
        )

        XCTAssertEqual(address, "10.10.0.42")
    }

    func testExtractsLoginTransactionDuration() {
        XCTAssertEqual(
            NgateOutputParser.extractLoginTransactionSeconds(
                from: "debug       vx000000782724c000 vpn session logintransaction finished in 15.048s"),
            15.048
        )
        XCTAssertNil(NgateOutputParser.extractLoginTransactionSeconds(from: "debug something else"))
    }

    func testSlowRejectedPasswordLoginIsTwoFactorTimeout() {
        let slow = NgateOutputParser.refineCredentialsError(.invalidCredentials, loginTransactionSeconds: 15.05)
        XCTAssertEqual(slow, .twoFactorTimeout)
        XCTAssertTrue(slow.isRetryable)
    }

    func testFastRejectedPasswordLoginStaysInvalidCredentials() {
        XCTAssertEqual(NgateOutputParser.refineCredentialsError(.invalidCredentials, loginTransactionSeconds: 0.2), .invalidCredentials)
        XCTAssertEqual(NgateOutputParser.refineCredentialsError(.invalidCredentials, loginTransactionSeconds: nil), .invalidCredentials)
        XCTAssertEqual(NgateOutputParser.refineCredentialsError(.certificateNotFound, loginTransactionSeconds: 30), .certificateNotFound)
    }

    func testClassifiesProxyFailures() {
        for line in [
            "critical htx0000007a0047c380 unrecoverable socket error occurred qabstractsocket::proxyconnectionclosederror (proxy connection closed prematurely) while connecting",
            "critical vx0000007a00494600 connection with proxy closed prematurely.",
        ] {
            let error = NgateOutputParser.classifyError(from: line)
            XCTAssertEqual(error, .proxyFailure, line)
            XCTAssertTrue(error?.isRetryable ?? false)
        }
        // A plain refused connection is still just that.
        XCTAssertEqual(NgateOutputParser.classifyError(from: "critical socket error occurred qabstractsocket::connectionrefusederror (connection refused) while connecting"), .connectionRefused)
    }
}
