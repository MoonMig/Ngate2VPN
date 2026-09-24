import XCTest
@testable import Ngate2VPNApp

final class WatchdogPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func inputs(
        status: TunnelState = .failed,
        error: TunnelError? = .gatewayUnreachable,
        auto: Bool = false,
        paused: Bool = false,
        failures: Int = 0,
        lastRestart: Date? = nil,
        lastFailure: Date? = nil
    ) -> WatchdogPolicy.Inputs {
        .init(status: status, lastError: error, autoReconnect: auto, paused: paused,
              consecutiveFailures: failures, lastRestartAt: lastRestart, lastFailureAt: lastFailure, now: now)
    }

    // MARK: Backoff

    func testBackoffDoublesAndCaps() {
        XCTAssertEqual(WatchdogPolicy.backoff(afterFailures: 0), 5)
        XCTAssertEqual(WatchdogPolicy.backoff(afterFailures: 1), 10)
        XCTAssertEqual(WatchdogPolicy.backoff(afterFailures: 2), 20)
        XCTAssertEqual(WatchdogPolicy.backoff(afterFailures: 7), 640)
        XCTAssertEqual(WatchdogPolicy.backoff(afterFailures: 8), 900)
        XCTAssertEqual(WatchdogPolicy.backoff(afterFailures: 1000), 900)
        XCTAssertEqual(WatchdogPolicy.backoff(afterFailures: -3), 5)
    }

    // MARK: Who gets restarted

    func testRetryableFailureIsRestarted() {
        XCTAssertEqual(WatchdogPolicy.decide(inputs()), .restart(attempt: 1, limit: 8, waited: 5))
    }

    func testManuallyStoppedTunnelIsNeverRestarted() {
        XCTAssertEqual(WatchdogPolicy.decide(inputs(status: .stopped, auto: true)), .skip)
        XCTAssertEqual(WatchdogPolicy.decide(inputs(status: .stopped)), .skip)
    }

    func testNonRetryableErrorIsNotRestartedWithoutAutoReconnect() {
        for error in [TunnelError.processExited, .unknown, .launchFailed, .invalidCredentials, .certificateNotFound] {
            XCTAssertEqual(WatchdogPolicy.decide(inputs(error: error)), .skip, "\(error)")
        }
        XCTAssertEqual(WatchdogPolicy.decide(inputs(error: nil)), .skip)
    }

    func testWithoutAutoReconnectOnlyFailedStatusRestarts() {
        XCTAssertEqual(WatchdogPolicy.decide(inputs(status: .degraded)), .skip)
    }

    func testAutoReconnectRestartsEvenForUnclassifiedExits() {
        XCTAssertEqual(WatchdogPolicy.decide(inputs(error: .processExited, auto: true)),
                       .restart(attempt: 1, limit: 24, waited: 5))
        XCTAssertEqual(WatchdogPolicy.decide(inputs(error: nil, auto: true)),
                       .restart(attempt: 1, limit: 24, waited: 5))
    }

    func testAutoReconnectStillSkipsConfigErrors() {
        for error in [TunnelError.invalidCredentials, .certificateNotFound, .invalidCertificateHash,
                      .serverCertificateNameMismatch, .invalidEndpoint] {
            XCTAssertEqual(WatchdogPolicy.decide(inputs(error: error, auto: true)), .skip, "\(error)")
        }
    }

    func testPausedTunnelIsSkippedInBothModes() {
        XCTAssertEqual(WatchdogPolicy.decide(inputs(paused: true)), .skip)
        XCTAssertEqual(WatchdogPolicy.decide(inputs(auto: true, paused: true)), .skip)
    }

    // MARK: Backoff timing

    func testWaitsForBackoffToElapse() {
        // 2 failures so far → 20 s wait.
        let recent = now.addingTimeInterval(-19)
        XCTAssertEqual(WatchdogPolicy.decide(inputs(failures: 2, lastRestart: recent)), .skip)
        let old = now.addingTimeInterval(-21)
        XCTAssertEqual(WatchdogPolicy.decide(inputs(failures: 2, lastRestart: old)),
                       .restart(attempt: 3, limit: 8, waited: 20))
    }

    // MARK: Circuit breaker

    func testCircuitBreakerTripsAfterEightRestartsWithoutAutoReconnect() {
        XCTAssertEqual(WatchdogPolicy.decide(inputs(failures: 7)), .restart(attempt: 8, limit: 8, waited: 640))
        XCTAssertEqual(WatchdogPolicy.decide(inputs(failures: 8)), .pause(.tooManyFailures, failures: 8))
    }

    func testAutoReconnectHasALongerButFiniteBudget() {
        XCTAssertEqual(WatchdogPolicy.decide(inputs(auto: true, failures: 23)),
                       .restart(attempt: 24, limit: 24, waited: 900))
        XCTAssertEqual(WatchdogPolicy.decide(inputs(auto: true, failures: 24)),
                       .pause(.tooManyFailures, failures: 24))
    }

    // MARK: Two-factor budget

    func testTwoFactorTimeoutGetsExactlyTwoAttempts() {
        // First failure → one automatic retry…
        XCTAssertEqual(WatchdogPolicy.decide(inputs(error: .twoFactorTimeout, failures: 0)),
                       .restart(attempt: 1, limit: 8, waited: 5))
        // …second failure → stop and tell the user.
        XCTAssertEqual(WatchdogPolicy.decide(inputs(error: .twoFactorTimeout, failures: 1)),
                       .pause(.twoFactor, failures: 1))
        XCTAssertEqual(WatchdogPolicy.twoFactorMaxRetries, 1)
    }

    func testTwoFactorRetryWaitsSoThePromptCanBeApproved() {
        let justFailed = now.addingTimeInterval(-6)
        XCTAssertEqual(WatchdogPolicy.decide(inputs(error: .twoFactorTimeout, lastFailure: justFailed)), .skip)
        let waitedLongEnough = now.addingTimeInterval(-21)
        XCTAssertEqual(WatchdogPolicy.decide(inputs(error: .twoFactorTimeout, lastFailure: waitedLongEnough)),
                       .restart(attempt: 1, limit: 8, waited: 5))
        // Other errors are not delayed by it.
        XCTAssertEqual(WatchdogPolicy.decide(inputs(error: .gatewayUnreachable, lastFailure: justFailed)),
                       .restart(attempt: 1, limit: 8, waited: 5))
    }

    func testTwoFactorBudgetAppliesWithAutoReconnectToo() {
        XCTAssertEqual(WatchdogPolicy.decide(inputs(error: .twoFactorTimeout, auto: true, failures: 1)),
                       .pause(.twoFactor, failures: 1))
    }

    func testPausedTwoFactorTunnelStaysPaused() {
        XCTAssertEqual(WatchdogPolicy.decide(inputs(error: .twoFactorTimeout, paused: true, failures: 1)), .skip)
    }

    // MARK: Startup timeout

    func testStartupTimeoutMeasuredFromFirstOutput() {
        let launched = now.addingTimeInterval(-200)
        let firstOutput = now.addingTimeInterval(-30)
        XCTAssertFalse(WatchdogPolicy.isStartupTimedOut(
            now: now, firstOutputAt: firstOutput, lastStateChange: launched, launchedAt: launched, timeout: 120))
        XCTAssertTrue(WatchdogPolicy.isStartupTimedOut(
            now: now, firstOutputAt: now.addingTimeInterval(-120), lastStateChange: launched, launchedAt: launched, timeout: 120))
    }

    func testSilentProcessFallsBackToStateChangeThenLaunch() {
        XCTAssertTrue(WatchdogPolicy.isStartupTimedOut(
            now: now, firstOutputAt: nil, lastStateChange: now.addingTimeInterval(-121), launchedAt: nil, timeout: 120))
        XCTAssertTrue(WatchdogPolicy.isStartupTimedOut(
            now: now, firstOutputAt: nil, lastStateChange: nil, launchedAt: now.addingTimeInterval(-500), timeout: 120))
        XCTAssertFalse(WatchdogPolicy.isStartupTimedOut(
            now: now, firstOutputAt: nil, lastStateChange: nil, launchedAt: nil, timeout: 120))
    }

    // MARK: connectAndWait retries

    func testStartupRetryRules() {
        XCTAssertTrue(WatchdogPolicy.canRetryDuringStartup(lastError: .gatewayUnreachable, attempts: 1, limit: 1))
        XCTAssertFalse(WatchdogPolicy.canRetryDuringStartup(lastError: .gatewayUnreachable, attempts: 2, limit: 1))
        XCTAssertFalse(WatchdogPolicy.canRetryDuringStartup(lastError: .invalidCredentials, attempts: 1, limit: 1))
        XCTAssertFalse(WatchdogPolicy.canRetryDuringStartup(lastError: nil, attempts: 1, limit: 1))
        // The watchdog owns the 2FA retry budget.
        XCTAssertFalse(WatchdogPolicy.canRetryDuringStartup(lastError: .twoFactorTimeout, attempts: 1, limit: 1))
    }
}
