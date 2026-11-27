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

    /// The permanent question channel (2026-11-27): its own questions keep it, without a settle.
    func testTheSessionsOwnQuestionKeepsItsChannel() {
        let socket = PhoneSocket(settle: 0.5)
        var closed = 0
        let tag = PhoneRoamingMonitor.sessionTag
        XCTAssertTrue(socket.take("beacon (/session)", timeout: 1, keeping: tag))
        socket.done(holding: { closed += 1 }, by: tag)
        let began = Date()
        XCTAssertTrue(socket.take("beacon (/media)", timeout: 1, keeping: tag))
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.2, "no settle: nothing was hung up")
        XCTAssertEqual(closed, 0)
        socket.done(holding: { closed += 1 }, by: tag)
        XCTAssertTrue(socket.take("hotspot request", timeout: 2))
        XCTAssertEqual(closed, 1, "the hotspot request frees the permanent channel")
        socket.done()
    }

    /// A late close of the hotspot's old channel must not forget the session holding the socket now.
    func testALateHangUpOfAnotherChannelKeepsTheSession() {
        let socket = PhoneSocket(settle: 0)
        var closed = 0
        let tag = PhoneRoamingMonitor.sessionTag
        XCTAssertTrue(socket.take("beacon (/session)", timeout: 1, keeping: tag))
        socket.done(holding: { closed += 1 }, by: tag)
        socket.hungUp()   // the fallback's channel, closing late
        XCTAssertTrue(socket.take("hotspot request", timeout: 1))
        XCTAssertEqual(closed, 1, "still known, so still freed")
        socket.done()
    }

    func testTheSessionHandshakeIsReadStrictly() {
        XCTAssertEqual(PhoneRoamingMonitor.handshake(#"{"session":true}"#), .open)
        XCTAssertEqual(PhoneRoamingMonitor.handshake(#"{"error":"not found"}"#), .unsupported, "an older phone")
        XCTAssertEqual(PhoneRoamingMonitor.handshake(#"{"error":"unsigned"}"#), .unsupported, "an older phone")
        if case .failed = PhoneRoamingMonitor.handshake("#go") {} else { XCTFail("the R came late: not an older phone") }
        if case .failed = PhoneRoamingMonitor.handshake(#"{"sess"#) {} else { XCTFail("a cut line") }
    }

    func testOnlyReadsAndSettingsAreAskedTwice() {
        XCTAssertTrue(PhoneRoamingMonitor.repeatable("/status?auth=1.2"))
        XCTAssertTrue(PhoneRoamingMonitor.repeatable("/media?hold=1&ttl=90&auth=1.2"))
        XCTAssertFalse(PhoneRoamingMonitor.repeatable("/ussd?auth=1.2"), "dials *123# again")
        XCTAssertFalse(PhoneRoamingMonitor.repeatable("/clip?c=x&auth=1.2"))
        XCTAssertFalse(PhoneRoamingMonitor.repeatable("/chime?k=plain&auth=1.2"))
    }

    func testOnlyAConnectFailureOverTheWiFiFallsBackToBluetooth() {
        XCTAssertTrue(PhoneLink.neverReached(URLError(.cannotConnectToHost)))
        XCTAssertFalse(PhoneLink.neverReached(URLError(.timedOut)), "may have reached the phone")
        XCTAssertFalse(PhoneLink.neverReached(nil))
    }

    func testOnlyASignedStatusVouchesForTheAddress() {
        XCTAssertFalse(PhoneLan.isSignedAnswer(Data(#"{"battery":80,"signal":3,"airplane":false}"#.utf8)))
        XCTAssertTrue(PhoneLan.isSignedAnswer(Data(#"{"battery":80,"roaming":{}}"#.utf8)))
    }

    func testTheLogGetsTheRouteNotTheCiphertext() {
        XCTAssertEqual(PhoneRoamingMonitor.shortPath("/clip?c=abc&auth=1.2"), "/clip")
        XCTAssertEqual(PhoneRoamingMonitor.shortPath("/status"), "/status")
    }
}

final class HttpServerBrowserGuardTests: XCTestCase {
    private func req(_ headers: String) -> String { "GET /test/hotspot/start HTTP/1.1\r\n\(headers)\r\n\r\n" }

    func testCurlAndTheSiblingAppsGetThrough() {
        XCTAssertFalse(HttpServer.fromBrowserOrForeignHost(req("Host: 127.0.0.1:55126\r\nUser-Agent: curl/8.7.1\r\nAccept: */*")))
        XCTAssertFalse(HttpServer.fromBrowserOrForeignHost(req("Host: localhost:55126")))
    }

    func testABrowserNavigationOrImageIsRefused() {
        XCTAssertTrue(HttpServer.fromBrowserOrForeignHost(req("Host: 127.0.0.1:55126\r\nSec-Fetch-Site: cross-site\r\nSec-Fetch-Mode: navigate")))
        XCTAssertTrue(HttpServer.fromBrowserOrForeignHost(req("Host: 127.0.0.1:55126\r\nOrigin: https://evil.example")))
        XCTAssertTrue(HttpServer.fromBrowserOrForeignHost(req("Host: 127.0.0.1:55126\r\nReferer: https://evil.example/")))
    }

    func testAHeadTooLongToReadWholeIsRefused() {
        XCTAssertTrue(HttpServer.completeHead(req("Host: 127.0.0.1:55126")))
        let long = "GET /test/hotspot/start?pad=\(String(repeating: "A", count: 70_000)) HTTP/1.1\r\nSec-Fetch-Site: cross-site\r\n"
        XCTAssertFalse(HttpServer.completeHead(long), "headers cut off by the read")
        XCTAssertFalse(HttpServer.completeHead(long + "\r\n"), "over 16 KB")
    }

    func testDnsRebindingIsRefused() {
        XCTAssertTrue(HttpServer.fromBrowserOrForeignHost(req("Host: attacker.example:55126")))
    }
}
