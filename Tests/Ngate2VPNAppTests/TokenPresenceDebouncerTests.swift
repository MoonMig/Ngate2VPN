import XCTest
@testable import Ngate2VPNApp

final class TokenPresenceDebouncerTests: XCTestCase {
    func testInitialPresentReportsImmediately() {
        var d = TokenPresenceDebouncer()
        XCTAssertEqual(d.observe(present: true), .report(true))
    }

    func testInitialAbsentReportsImmediately() {
        var d = TokenPresenceDebouncer()
        XCTAssertEqual(d.observe(present: false), .report(false))
    }

    func testRepeatingTheSameRawStateReportsNothingMore() {
        var d = TokenPresenceDebouncer()
        XCTAssertEqual(d.observe(present: true), .report(true))
        XCTAssertEqual(d.observe(present: true), .none)
        XCTAssertEqual(d.observe(present: true), .none)
    }

    func testGenuineRemovalSchedulesThenReportsAfterTheCheck() {
        var d = TokenPresenceDebouncer()
        _ = d.observe(present: true)                                   // token present at launch
        XCTAssertEqual(d.observe(present: false), .scheduleRemovalCheck)
        XCTAssertEqual(d.removalCheckFired(presentNow: false), .report(false))
    }

    func testRepeatedRemovalObservationsKeepRescheduling() {
        // A composite reader can expose more than one matching USB interface,
        // so a single physical unplug can arrive as two separate IOKit
        // notifications a moment apart. Each still-absent observation before
        // the check fires restarts the debounce window — the real
        // `TokenMonitor` cancels and reschedules its timer idempotently, so
        // this only delays the eventual report, it never duplicates it.
        var d = TokenPresenceDebouncer()
        _ = d.observe(present: true)
        XCTAssertEqual(d.observe(present: false), .scheduleRemovalCheck)
        XCTAssertEqual(d.observe(present: false), .scheduleRemovalCheck)
    }

    func testOnceRemovalIsConfirmedFurtherAbsentSignalsDoNotRescheduleOrRereport() {
        var d = TokenPresenceDebouncer()
        _ = d.observe(present: true)
        _ = d.observe(present: false)
        XCTAssertEqual(d.removalCheckFired(presentNow: false), .report(false))
        XCTAssertEqual(d.observe(present: false), .none)
        XCTAssertEqual(d.observe(present: false), .none)
    }

    func testBlipThatComesBackBeforeTheCheckIsNeverReported() {
        var d = TokenPresenceDebouncer()
        _ = d.observe(present: true)
        XCTAssertEqual(d.observe(present: false), .scheduleRemovalCheck)
        // Token reappears on its own before the debounce window elapses.
        XCTAssertEqual(d.observe(present: true), .none)   // still "present" — nothing changed
        // The stale scheduled check eventually fires anyway (its DispatchWorkItem
        // was not necessarily cancelled in time); it must not report a removal
        // for a token that is, right now, present again.
        XCTAssertEqual(d.removalCheckFired(presentNow: true), .none)
    }

    func testCheckFiringAfterRemovalPendingWasAlreadyClearedDoesNothing() {
        var d = TokenPresenceDebouncer()
        _ = d.observe(present: true)
        _ = d.observe(present: false)      // schedules
        _ = d.observe(present: true)       // clears removalPending
        // A duplicate / late-arriving check call (owner forgot to cancel the
        // timer, or two timers raced) must not fire a report twice.
        XCTAssertEqual(d.removalCheckFired(presentNow: false), .none)
    }

    func testFlickerBackToAbsentAfterReappearingSchedulesAgain() {
        var d = TokenPresenceDebouncer()
        _ = d.observe(present: true)
        _ = d.observe(present: false)                                   // schedule #1
        _ = d.observe(present: true)                                    // cancel it, back to present
        XCTAssertEqual(d.observe(present: false), .scheduleRemovalCheck) // genuinely absent again
        XCTAssertEqual(d.removalCheckFired(presentNow: false), .report(false))
    }

    func testReinsertionAfterAConfirmedRemovalReportsPresentAgain() {
        var d = TokenPresenceDebouncer()
        _ = d.observe(present: true)
        _ = d.observe(present: false)
        _ = d.removalCheckFired(presentNow: false)   // confirmed removed
        XCTAssertEqual(d.observe(present: true), .report(true))
    }

    func testInitialAbsentThenPresentReportsBothWithNoDebounceOnTheFirstOne() {
        var d = TokenPresenceDebouncer()
        XCTAssertEqual(d.observe(present: false), .report(false))
        XCTAssertEqual(d.observe(present: true), .report(true))
    }
}
