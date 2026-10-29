import XCTest
@testable import VictorNet

/// 📱 The phone's charge, as `/status` carries it to the tablet's top bar.
final class PhoneBatteryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testReadsChargeFromStatus() {
        let body = #"{"signal":{"level":3},"battery":{"pct":63,"charging":true}}"#
        XCTAssertEqual(PhoneBattery.parse(Data(body.utf8), now: now),
                       PhoneBattery(pct: 63, charging: true, readAt: now))
    }

    /// A phone older than 29 Oct 2026 sends no battery: unknown, not 0%.
    func testOlderPhoneHasNoBattery() {
        XCTAssertNil(PhoneBattery.parse(Data(#"{"signal":{"level":3}}"#.utf8), now: now))
        XCTAssertEqual(PhoneBattery.json(nil, now: now)["pct"] as? Int, -1)
    }

    func testOutOfRangeIsIgnored() {
        XCTAssertNil(PhoneBattery.parse(Data(#"{"battery":{"pct":-1}}"#.utf8), now: now))
    }

    func testJsonCarriesAge() {
        let b = PhoneBattery(pct: 40, charging: false, readAt: now.addingTimeInterval(-125))
        let o = PhoneBattery.json(b, now: now)
        XCTAssertEqual(o["pct"] as? Int, 40)
        XCTAssertEqual(o["charging"] as? Bool, false)
        XCTAssertEqual(o["age_s"] as? Int, 125)
    }
}
