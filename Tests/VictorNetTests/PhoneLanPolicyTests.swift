import XCTest
@testable import VictorNet

final class PhoneLanPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testAsksAtOnceTheFirstTime() {
        XCTAssertTrue(PhoneLanPolicy.due(now: t0, lastAttempt: nil, networkChanged: false))
    }

    func testOnceInTenMinutes() {
        XCTAssertFalse(PhoneLanPolicy.due(now: t0.addingTimeInterval(599), lastAttempt: t0, networkChanged: false))
        XCTAssertTrue(PhoneLanPolicy.due(now: t0.addingTimeInterval(600), lastAttempt: t0, networkChanged: false))
    }

    func testANewNetworkAsksSoonerButNeverTwiceInAMinute() {
        XCTAssertFalse(PhoneLanPolicy.due(now: t0.addingTimeInterval(59), lastAttempt: t0, networkChanged: true))
        XCTAssertTrue(PhoneLanPolicy.due(now: t0.addingTimeInterval(60), lastAttempt: t0, networkChanged: true))
    }

    func testEveryHostOfTheSubnetButThisMac() {
        let hosts = PhoneLanPolicy.hosts(ip: "192.168.1.188", mask: "255.255.255.0")
        XCTAssertEqual(hosts.count, 253)
        XCTAssertEqual(hosts.first, "192.168.1.1")
        XCTAssertEqual(hosts.last, "192.168.1.254")
        XCTAssertFalse(hosts.contains("192.168.1.188"))
    }

    func testNoSweepOnAWiderNetwork() {
        XCTAssertEqual(PhoneLanPolicy.hosts(ip: "10.1.2.3", mask: "255.255.0.0"), [])
        XCTAssertEqual(PhoneLanPolicy.hosts(ip: "nonsense", mask: "255.255.255.0"), [])
    }
}
