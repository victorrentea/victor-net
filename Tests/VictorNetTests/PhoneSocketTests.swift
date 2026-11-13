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
