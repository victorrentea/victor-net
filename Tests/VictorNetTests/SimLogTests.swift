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

    func testTheRowPutsTheSimInUseFirst() {
        var yoxo = SimSpot(); yoxo.latency = [30, 36, 40]; yoxo.speed = 2_100_000
        var vic = SimSpot(); vic.latency = [53]
        let row = SimLogPolicy.row(["yoxo": yoxo, "Vic": vic], current: "Vic")
        XCTAssertEqual(row, "📶 Here: • Vic 53 ms ⋅ —   yoxo 36 ms ⋅ \(TrafficPolicy.rate(2_100_000))")
        XCTAssertNil(SimLogPolicy.row([:], current: "Vic"))
    }
}
