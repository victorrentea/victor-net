import XCTest
@testable import VictorNet

/// 🛜 The menu's *Start Hotspot* row, and when the next attempt runs.
final class HotspotRowPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func text(_ p: HotspotProgress) -> String { HotspotRowPolicy.status(p, now: now).text }

    func testOfflineCountsDownToTheNextAttempt() {
        let p = HotspotProgress(offline: true, nextRetryAt: now + 22.4)
        XCTAssertEqual(text(p), "retrying in 23s")
        XCTAssertFalse(HotspotRowPolicy.status(p, now: now).spinning)
    }

    func testCountdownStopsAtZero() {
        XCTAssertEqual(text(HotspotProgress(offline: true, nextRetryAt: now - 5)), "retrying in 0s")
    }

    func testAttemptSpinsWithWhatIsLeftOfItsBudget() {
        let asking = HotspotProgress(phase: .askingPhone(deadline: now + 30), offline: true)
        XCTAssertEqual(text(asking), "asking phone 30s")
        XCTAssertTrue(HotspotRowPolicy.status(asking, now: now).spinning)
        XCTAssertEqual(text(HotspotProgress(phase: .joining(deadline: now + 47))), "joining 47s")
    }

    /// Switched off or at home: offline, but nothing is coming on its own.
    func testNoCountdownWithoutAScheduledAttempt() {
        XCTAssertEqual(text(HotspotProgress(offline: true)), "")
    }

    /// The heartbeat's probe runs every minute online: it must not flicker here.
    func testCheckingShowsOnlyWhileOffline() {
        XCTAssertEqual(text(HotspotProgress(phase: .checking)), "")
        XCTAssertEqual(text(HotspotProgress(phase: .checking, offline: true)), "checking")
    }

    func testStopWhenTheHotspotIsSeenOrInUse() {
        let idle = HotspotProgress()
        XCTAssertTrue(HotspotRowPolicy.showsStop(idle, onHotspot: true, inScan: false, stoppedRecently: false))
        XCTAssertTrue(HotspotRowPolicy.showsStop(idle, onHotspot: false, inScan: true, stoppedRecently: false))
        XCTAssertFalse(HotspotRowPolicy.showsStop(idle, onHotspot: false, inScan: false, stoppedRecently: false))
    }

    func testStartAgainRightAfterAStopAndDuringAnAttempt() {
        let idle = HotspotProgress()
        XCTAssertFalse(HotspotRowPolicy.showsStop(idle, onHotspot: false, inScan: true, stoppedRecently: true))
        var asking = HotspotProgress()
        asking.phase = .askingPhone(deadline: Date())
        XCTAssertFalse(HotspotRowPolicy.showsStop(asking, onHotspot: false, inScan: true, stoppedRecently: false))
    }

    func testHiddenOnlyOnAWorkingHotspot() {
        XCTAssertFalse(HotspotRowPolicy.visible(HotspotProgress(), onHotspot: true))
        XCTAssertTrue(HotspotRowPolicy.visible(HotspotProgress(), onHotspot: false))
        XCTAssertTrue(HotspotRowPolicy.visible(HotspotProgress(offline: true), onHotspot: true))
        XCTAssertTrue(HotspotRowPolicy.visible(HotspotProgress(phase: .joining(deadline: now)), onHotspot: true))
    }

    func testAttemptsKeepTheCooldownApart() {
        let next = HotspotRowPolicy.nextAttempt(lastStart: now, ended: now + 10, cooldown: 45, pause: 15)
        XCTAssertEqual(next, now + 45)
    }

    /// A failed attempt can outlast the cooldown: the phone still gets a pause.
    func testALongAttemptIsFollowedByAPause() {
        let next = HotspotRowPolicy.nextAttempt(lastStart: now, ended: now + 100, cooldown: 45, pause: 15)
        XCTAssertEqual(next, now + 115)
    }

    // MARK: - The button at the top (2026-11-11)

    private func button(_ p: HotspotProgress = HotspotProgress(), on: Bool = false, scan: Bool = false,
                        stopped: Bool = false) -> HotspotButton {
        HotspotRowPolicy.button(p, onHotspot: on, inScan: scan, stoppedRecently: stopped)
    }

    func testButtonWalksStartAskingStartingStop() {
        XCTAssertEqual(button(), .start)
        XCTAssertEqual(button(HotspotProgress(phase: .askingPhone(deadline: now))), .asking)
        // The phone's app took the channel: the hotspot is coming.
        XCTAssertEqual(button(HotspotProgress(phase: .joining(deadline: now)), scan: true), .starting)
        XCTAssertEqual(button(on: true), .stop)
        XCTAssertEqual(button(scan: true), .stop)
    }

    func testAPhoneInAirplaneModeIsNotStartingAnything() {
        var p = HotspotProgress(phase: .idle, offline: true)
        p.phoneInAirplane = true
        XCTAssertEqual(button(p), .airplane)
        // Asking again every 20 s does not flash "Asking the phone…".
        p.phase = .askingPhone(deadline: now)
        XCTAssertEqual(button(p), .airplane)
        // Out of airplane mode the phone takes the signal: now it really is starting.
        p.phase = .joining(deadline: now)
        XCTAssertEqual(button(p), .starting)
        XCTAssertTrue(HotspotButton.airplane.clickable, "a click asks again now")
    }

    func testAfterAStopTheLingeringScanDoesNotBringStopBack() {
        XCTAssertEqual(button(on: true, stopped: true), .stopping)
        XCTAssertEqual(button(scan: true, stopped: true), .start)
    }

    /// 2026-11-11 08:38: the hotspot came up under the cursor and a click meant for it stopped it.
    func testAClickOnALabelThatJustChangedIsDropped() {
        XCTAssertFalse(HotspotRowPolicy.takesClick(shown: .start, now: .stop, shownSince: now - 10, at: now))
        XCTAssertFalse(HotspotRowPolicy.takesClick(shown: .stop, now: .stop, shownSince: now - 0.4, at: now))
        XCTAssertTrue(HotspotRowPolicy.takesClick(shown: .stop, now: .stop, shownSince: now - 1, at: now))
        XCTAssertTrue(HotspotRowPolicy.takesClick(shown: .start, now: .start, shownSince: now - 5, at: now))
        XCTAssertFalse(HotspotRowPolicy.takesClick(shown: .starting, now: .starting, shownSince: now - 5, at: now))
    }

    /// Starting: the bars climb left to right, none to four, and over again.
    func testBarsClimbInALoopWhileStarting() {
        let step = HotspotRowPolicy.climbStep
        let frames = (0..<11).map { HotspotRowPolicy.climbingBars(elapsed: Double($0) * step + step / 2) }
        XCTAssertEqual(frames, [0, 1, 2, 3, 4, 0, 1, 2, 3, 4, 0])
        XCTAssertEqual(HotspotRowPolicy.climbingBars(elapsed: -1), 0)
    }
}
