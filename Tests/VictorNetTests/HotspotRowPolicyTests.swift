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
}
