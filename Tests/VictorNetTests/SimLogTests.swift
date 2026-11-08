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
        XCTAssertEqual(SimSignalPolicy.cell(sims[1], latencyMs: 36.4), "LTE\u{2009}⋅\u{2009}-5 dB poor\u{2009}⋅\u{2009}36↕︎ms")
        XCTAssertEqual(SimSignalPolicy.cell(sims[2], latencyMs: nil), "no signal")
    }

    func testSinrWords() {
        XCTAssertEqual(SimSignalPolicy.quality(sinr: 20), "excellent")
        XCTAssertEqual(SimSignalPolicy.quality(sinr: 13), "good")
        XCTAssertEqual(SimSignalPolicy.quality(sinr: 0), "fair")
        XCTAssertEqual(SimSignalPolicy.quality(sinr: -1), "poor")
    }
}
