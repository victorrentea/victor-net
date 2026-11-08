import CoreLocation
import XCTest
@testable import VictorNet

/// 📶 Both SIMs, place by place: what gets filed, and when capacity is measured.
final class SimLogTests: XCTestCase {
    func testAPlaceIsAboutAKilometre() {
        XCTAssertEqual(SimLogPolicy.place(CLLocationCoordinate2D(latitude: 44.43251, longitude: 26.10389)), "44.43,26.10")
        XCTAssertEqual(SimLogPolicy.place(nil), "?")
    }

    func testMedian() {
        XCTAssertEqual(SimLogPolicy.median([40, 20, 30]), 30)
        XCTAssertEqual(SimLogPolicy.median([10, 20]), 15)
        XCTAssertNil(SimLogPolicy.median([]))
    }

    func testCapacityIsMeasuredOncePerSimPerPlaceAfterTenQuietMinutes() {
        let quiet = SimLogPolicy.settle
        XCTAssertTrue(SimLogPolicy.shouldTestSpeed(nil, stableFor: quiet, recentDown: 0, roaming: false))
        XCTAssertFalse(SimLogPolicy.shouldTestSpeed(nil, stableFor: quiet - 1, recentDown: 0, roaming: false))
        XCTAssertFalse(SimLogPolicy.shouldTestSpeed(nil, stableFor: quiet, recentDown: 200_000, roaming: false))
        var done = SimSpot()
        done.speedAt = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(SimLogPolicy.shouldTestSpeed(done, stableFor: quiet * 100, recentDown: 0, roaming: false))
    }

    func testNeverOnRoamingData() {
        XCTAssertFalse(SimLogPolicy.shouldTestSpeed(nil, stableFor: SimLogPolicy.settle, recentDown: 0, roaming: true))
    }

    func testSimRowsDataFirstWithBarsAndLatency() {
        let sims = SimSignal.parse([["name": "Vic", "data": false, "network": "LTE", "rsrp": -98, "sinr": 14],
                                    ["name": "yoxo", "data": true, "network": "LTE", "rsrp": -85, "sinr": -5],
                                    ["name": "far", "data": false, "level": 0]])
        XCTAssertEqual(SimSignalPolicy.ordered(sims).map(\.name), ["yoxo", "Vic", "far"])
        XCTAssertEqual(sims.map(\.level), [3, 4, 0])
    }

    func testASimIsShownByItsOperator() {
        let sims = SimSignal.parse([["name": "Vic", "operator": "Vodafone RO"], ["name": "yoxo", "operator": "orange"],
                                    ["name": "Maya", "operator": ""]])
        XCTAssertEqual(sims.map(SimSignalPolicy.label), ["Vodafone", "Orange", "Maya"])
    }

    func testSignalAge() {
        let t = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(SimSignalPolicy.age(t, now: t.addingTimeInterval(4.9)), "4s")
        XCTAssertEqual(SimSignalPolicy.age(t, now: t.addingTimeInterval(185)), "3m")
    }
}
