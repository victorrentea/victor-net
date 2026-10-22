import XCTest
@testable import VictorNet

/// 🛜 On the hotspot with the home Wi-Fi in range — the decision, without a radio.
final class PreferredWifiPolicyTests: XCTestCase {
    private let now = Date()

    private func decide(enabled: Bool = true, current: String? = "phone", scan: [(String, Int)],
                        backoffUntil: Date = .distantPast) -> Int? {
        PreferredWifiPolicy.switchTo(enabled: enabled, preferred: "home", hotspot: "phone", current: current,
                                     scan: scan.map { (ssid: $0.0, rssi: $0.1) }, now: now, backoffUntil: backoffUntil)
    }

    func testOnHotspotWithHomeInRangeMoves() {
        XCTAssertEqual(decide(scan: [("phone", -40), ("home", -60), ("home", -66)]), -60)
    }

    func testHomeAtTheEdgeOfItsRangeIsLeftAlone() {
        XCTAssertNil(decide(scan: [("home", -80)]))
    }

    func testNotOnTheHotspotNothingToDo() {
        XCTAssertNil(decide(current: "home", scan: [("home", -50)]))
        XCTAssertNil(decide(current: "hotel", scan: [("home", -50)]))
        XCTAssertNil(decide(current: nil, scan: [("home", -50)]))
    }

    func testSwitchedOffOrBackingOffNothingToDo() {
        XCTAssertNil(decide(enabled: false, scan: [("home", -50)]))
        XCTAssertNil(decide(scan: [("home", -50)], backoffUntil: now + 60))
    }

    func testHomeNotInRange() {
        XCTAssertNil(decide(scan: [("phone", -40), ("neighbour", -50)]))
    }
}
