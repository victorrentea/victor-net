import XCTest
@testable import VictorNet

final class PhoneSocketTests: XCTestCase {
    func testAQuestionFreesTheChannelTheHotspotRequestHolds() {
        let socket = PhoneSocket(settle: 0)
        var released = 0
        XCTAssertTrue(socket.take("hotspot request", timeout: 1))
        socket.done(holding: { released += 1 })
        XCTAssertTrue(socket.take("beacon (/clip)", timeout: 1))
        XCTAssertEqual(released, 1)
        socket.done()
        XCTAssertTrue(socket.take("beacon (/status)", timeout: 1))
        XCTAssertEqual(released, 1, "freed once, not again")
        socket.done()
    }

    func testOneTurnAtATime() {
        let socket = PhoneSocket(settle: 0)
        XCTAssertTrue(socket.take("hotspot request", timeout: 1))
        XCTAssertFalse(socket.take("beacon (/clip)", timeout: 0.2), "the open is still in flight")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { socket.done() }
        XCTAssertTrue(socket.take("beacon (/clip)", timeout: 2))
        socket.done()
    }

    func testWaitsOutThePhonesReListenAfterAHangUp() {
        let socket = PhoneSocket(settle: 0.3)
        XCTAssertTrue(socket.take("beacon (/status)", timeout: 1))
        socket.done()
        let began = Date()
        XCTAssertTrue(socket.take("hotspot request", timeout: 1))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), 0.25)
        socket.done()
    }

    func testTheLogGetsTheRouteNotTheCiphertext() {
        XCTAssertEqual(PhoneRoamingMonitor.shortPath("/clip?c=abc&auth=1.2"), "/clip")
        XCTAssertEqual(PhoneRoamingMonitor.shortPath("/status"), "/status")
    }
}
