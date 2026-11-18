import XCTest
@testable import VictorNet

final class RoamingGbNoticeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_791_000_000)
    private let limit: Int64 = 13_380_000_000

    private func reading(used: Int64, key: String? = "22601", name: String? = "Vic",
                         resetIn days: Double = 13.5) -> RoamingWarningPolicy.Reading {
        RoamingWarningPolicy.Reading(
            cycleTotal: used, cycleHotspot: 0, today: 1, roamingNow: true, limit: limit,
            lowFraction: 0.10, nextReset: now.addingTimeInterval(days * 86_400), readAt: now,
            simKey: key, simName: name)
    }

    private func mark(_ r: RoamingWarningPolicy.Reading, gb: Int64) -> RoamingGbNoticePolicy.Mark {
        .init(cycle: Int64(r.nextReset.timeIntervalSince1970), gb: gb)
    }

    func testCrossingIntoTheNextGbAnnouncesOnceThenStaysQuiet() {
        let r = reading(used: 5_050_000_000)
        let (m, announce) = RoamingGbNoticePolicy.check(r, mark: mark(r, gb: 4))
        XCTAssertTrue(announce)
        XCTAssertEqual(m.gb, 5)
        XCTAssertFalse(RoamingGbNoticePolicy.check(reading(used: 5_900_000_000), mark: m).announce)
    }

    func testTheFirstReadingAndANewCycleOnlyTakeABaseline() {
        let r = reading(used: 5_050_000_000)
        XCTAssertFalse(RoamingGbNoticePolicy.check(r, mark: nil).announce)
        let lastCycle = RoamingGbNoticePolicy.Mark(cycle: 1, gb: 2)
        let (m, announce) = RoamingGbNoticePolicy.check(r, mark: lastCycle)
        XCTAssertFalse(announce)
        XCTAssertEqual(m, mark(r, gb: 5))
    }

    func testACorrectionDownwardsLowersTheMarkSoTheNextGbIsAnnouncedAgain() {
        let r = reading(used: 3_200_000_000)
        let (m, announce) = RoamingGbNoticePolicy.check(r, mark: mark(r, gb: 5))
        XCTAssertFalse(announce)
        XCTAssertEqual(m.gb, 3)
        XCTAssertTrue(RoamingGbNoticePolicy.check(reading(used: 4_000_000_000), mark: m).announce)
    }

    func testTheTextSaysSimGbLeftPercentAndDays() {
        XCTAssertEqual(RoamingGbNoticePolicy.text(reading(used: 5_000_000_000), now: now),
                       "✈️ vdf: 8.4 GB left · 62% · 14 days")
        XCTAssertEqual(RoamingGbNoticePolicy.text(reading(used: 7_000_000_000, key: "22610", name: "yoxo",
                                                          resetIn: 0.4), now: now),
                       "✈️ yoxo: 6.4 GB left · 47% · 1 day")
    }

    func testEachSimKeepsItsOwnMarkAcrossRestarts() {
        let defaults = UserDefaults(suiteName: "RoamingGbNoticeTests")!
        defaults.removePersistentDomain(forName: "RoamingGbNoticeTests")
        var shown: [String] = []
        func both(vdf: Int64, yoxo: Int64) -> RoamingWarningPolicy.Reading {
            var r = reading(used: vdf)
            r.sims = [reading(used: vdf), reading(used: yoxo, key: "22610", name: "yoxo")]
            return r
        }
        RoamingGbNotice(defaults: defaults) { shown.append($0) }.accept(both(vdf: 4_900_000_000, yoxo: 100_000_000), now: now)
        XCTAssertEqual(shown, [])
        // A restart: a new instance, the same defaults.
        RoamingGbNotice(defaults: defaults) { shown.append($0) }.accept(both(vdf: 5_100_000_000, yoxo: 200_000_000), now: now)
        XCTAssertEqual(shown, ["✈️ vdf: 8.3 GB left · 61% · 14 days"])
    }
}
