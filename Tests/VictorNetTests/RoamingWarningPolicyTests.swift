import XCTest
@testable import VictorNet

final class RoamingWarningPolicyTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        return c
    }()
    /// 25 Sep 2026, 14:00 in Bucharest.
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 14))! }
    private let limit: Int64 = 13_703_000_000

    private func reading(leftPct: Int64, today: Int64 = 5_000_000, roamingNow: Bool = true,
                         readAgo: TimeInterval = 60) -> RoamingWarningPolicy.Reading {
        RoamingWarningPolicy.Reading(
            cycleTotal: limit - limit * leftPct / 100, cycleHotspot: 0, today: today,
            roamingNow: roamingNow, limit: limit, lowFraction: 0.15,
            nextReset: now.addingTimeInterval(86_400 * 7), readAt: now.addingTimeInterval(-readAgo))
    }

    func testWarnsUnder15PercentOnARoamingDay() {
        XCTAssertTrue(RoamingWarningPolicy.shouldWarn(reading(leftPct: 12), now: now, dismissedDay: nil, calendar: cal))
    }

    func testSilentAtOrAbove15Percent() {
        XCTAssertFalse(RoamingWarningPolicy.shouldWarn(reading(leftPct: 15), now: now, dismissedDay: nil, calendar: cal))
    }

    func testSilentBackHomeAfterARoamingMorning() {
        let backHome = reading(leftPct: 5, today: 4_300_000_000, roamingNow: false)
        XCTAssertFalse(RoamingWarningPolicy.shouldWarn(backHome, now: now, dismissedDay: nil, calendar: cal))
    }

    func testSilentOnADayWithoutRoaming() {
        let home = reading(leftPct: 5, today: 0, roamingNow: false)
        XCTAssertFalse(RoamingWarningPolicy.shouldWarn(home, now: now, dismissedDay: nil, calendar: cal))
    }

    func testRoamingNowCountsBeforeAnyTrafficToday() {
        let morning = reading(leftPct: 5, today: 0, roamingNow: true)
        XCTAssertTrue(RoamingWarningPolicy.shouldWarn(morning, now: now, dismissedDay: nil, calendar: cal))
    }

    func testOverTheCeilingIsZeroLeftAndWarns() {
        let over = RoamingWarningPolicy.Reading(
            cycleTotal: limit + 2_000_000_000, cycleHotspot: 0, today: 1, roamingNow: true, limit: limit,
            lowFraction: 0.15, nextReset: now, readAt: now)
        XCTAssertEqual(over.remaining, 0)
        XCTAssertTrue(RoamingWarningPolicy.shouldWarn(over, now: now, dismissedDay: nil, calendar: cal))
    }

    func testDismissalLastsForTheDayOnly() {
        let r = reading(leftPct: 10)
        XCTAssertFalse(RoamingWarningPolicy.shouldWarn(r, now: now, dismissedDay: "2026-09-25", calendar: cal))
        XCTAssertTrue(RoamingWarningPolicy.shouldWarn(r, now: now, dismissedDay: "2026-09-24", calendar: cal))
    }

    func testStaleOrYesterdaysReadingDoesNotWarn() {
        XCTAssertFalse(RoamingWarningPolicy.shouldWarn(reading(leftPct: 5, readAgo: 2 * 3600), now: now,
                                                       dismissedDay: nil, calendar: cal))
        let justAfterMidnight = cal.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 0, minute: 10))!
        let lateYesterday = reading(leftPct: 5, readAgo: 0)
        XCTAssertFalse(RoamingWarningPolicy.shouldWarn(
            RoamingWarningPolicy.Reading(cycleTotal: lateYesterday.cycleTotal, cycleHotspot: 0, today: 1,
                                         roamingNow: true, limit: limit, lowFraction: 0.15, nextReset: now,
                                         readAt: justAfterMidnight.addingTimeInterval(-20 * 60)),
            now: justAfterMidnight, dismissedDay: nil, calendar: cal))
    }

    func testParsesThePhonesLine() throws {
        let line = #"{"v":1,"cycleTotal":12000000000,"cycleHotspot":9000000000,"today":300000000,"roamingNow":true,"cycleStart":1788300000000,"nextReset":1790892000000,"limit":13703000000,"lowFraction":0.15,"readAt":1790330000000}"#
        let r = try XCTUnwrap(RoamingWarningPolicy.parse(line))
        XCTAssertEqual(r.cycleTotal, 12_000_000_000)
        XCTAssertEqual(r.limit, 13_703_000_000)
        XCTAssertTrue(r.roamingNow)
        XCTAssertEqual(r.readAt.timeIntervalSince1970, 1_790_330_000, accuracy: 0.001)
        XCTAssertEqual(RoamingWarningPolicy.text(r), "📶 Roaming: 1.7 GB left (12%)")
    }

    func testPhoneErrorIsNotAReading() {
        XCTAssertNil(RoamingWarningPolicy.parse(#"{"v":1,"error":"no Usage access"}"#))
        XCTAssertNil(RoamingWarningPolicy.parse("garbage"))
    }

    /// The copy kept on disk reads back as the same reading.
    func testDiskLineRoundTrips() {
        let line = #"{"v":1,"cycleTotal":38276835813,"cycleHotspot":33703322969,"today":0,"roamingNow":false,"nextReset":1793570400000,"limit":49452000000,"lowFraction":0.1,"reserve":1000000000,"hotspotBlocked":false,"guardOff":false,"adjust":36072000000,"planMb":13380,"resetDay":2,"readAt":1792566228681}"#
        let r = RoamingWarningPolicy.parse(line)
        XCTAssertNotNil(r)
        XCTAssertEqual(RoamingWarningPolicy.parse(RoamingWarningPolicy.line(r!)), r)
    }

    /// 11 Nov 2026: one allowance per SIM. The top level is the data SIM's; Vodafone's
    /// `*123#` correction must land on Vodafone's SIM even while yoxo carries the data.
    func testParsesOneAllowancePerSim() throws {
        let vic = #"{"v":1,"sim":"Vic","simKey":"22601","data":false,"cycleTotal":4000000000,"today":0,"limit":13380000000,"readAt":1794437579281,"nextReset":1796166000000,"planMb":13380}"#
        let yoxo = #"{"v":1,"sim":"yoxo","simKey":"22610","data":true,"cycleTotal":1000000000,"today":5,"limit":7370000000,"readAt":1794437579281,"nextReset":1796598000000,"planMb":7370}"#
        let line = #"{"v":1,"sim":"yoxo","simKey":"22610","data":true,"cycleTotal":1000000000,"today":5,"roamingNow":true,"limit":7370000000,"readAt":1794437579281,"nextReset":1796598000000,"planMb":7370,"sims":["# + vic + "," + yoxo + "]}"
        let r = try XCTUnwrap(RoamingWarningPolicy.parse(line))
        XCTAssertEqual(r.simName, "yoxo")
        XCTAssertEqual(r.sims.map { $0.simName }, ["Vic", "yoxo"])
        XCTAssertEqual(r.sims.map { $0.remaining }, [9_380_000_000, 6_370_000_000])
        XCTAssertEqual(r.vodafone.simKey, "22601")
        XCTAssertEqual(r.vodafone.planMb, 13_380)
        XCTAssertEqual(RoamingWarningPolicy.parse(RoamingWarningPolicy.line(r)), r)
    }

    /// A phone app from before 11 Nov 2026: one allowance, which is Vodafone's.
    func testOlderPhoneHasOneAllowance() throws {
        let r = try XCTUnwrap(RoamingWarningPolicy.parse(#"{"v":1,"cycleTotal":1,"today":0,"limit":13380000000,"readAt":1794437579281}"#))
        XCTAssertTrue(r.sims.isEmpty)
        XCTAssertEqual(r.vodafone, r)
    }
}
