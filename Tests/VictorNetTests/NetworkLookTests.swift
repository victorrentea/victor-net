import XCTest
@testable import VictorNet

/// The menu bar icon's decision, and the readouts around it.
final class NetworkLookTests: XCTestCase {

    func testCableWinsOverWifi() {
        XCTAssertEqual(NetworkLookPolicy.look(wired: .connected(ip: "10.0.0.2"), ssid: "Hotel", rssi: -50,
                                              hotspotSSID: "phone", phoneLevel: nil), .wired)
    }

    func testCableWithoutAddressIsNotTheRoute() {
        XCTAssertEqual(NetworkLookPolicy.look(wired: .noAddress, ssid: "Hotel", rssi: -50,
                                              hotspotSSID: "phone", phoneLevel: nil), .wifi(strength: 1))
    }

    /// The phone is usually beside the laptop: its Wi-Fi only shows when weak.
    func testHotspotShowsPhoneBarsAndWifiOnlyWhenWeak() {
        XCTAssertEqual(NetworkLookPolicy.look(wired: .disconnected, ssid: "phone", rssi: -45,
                                              hotspotSSID: "phone", phoneLevel: 3), .hotspot(level: 3, weakWifi: nil))
        XCTAssertEqual(NetworkLookPolicy.look(wired: .disconnected, ssid: "phone", rssi: -78,
                                              hotspotSSID: "phone", phoneLevel: 2),
                       .hotspot(level: 2, weakWifi: NetworkLookPolicy.strength(rssi: -78)))
    }

    func testNoAssociationIsOffline() {
        XCTAssertEqual(NetworkLookPolicy.look(wired: .disconnected, ssid: nil, rssi: nil,
                                              hotspotSSID: "phone", phoneLevel: nil), .offline)
    }

    /// No Location permission: associated, but no name — still Wi-Fi, never the hotspot.
    func testUnnamedWifiIsPlainWifi() {
        XCTAssertEqual(NetworkLookPolicy.look(wired: .disconnected, ssid: nil, rssi: -60,
                                              hotspotSSID: "phone", phoneLevel: 4), .wifi(strength: 0.75))
    }

    func testStrengthClamps() {
        XCTAssertEqual(NetworkLookPolicy.strength(rssi: -30), 1)
        XCTAssertEqual(NetworkLookPolicy.strength(rssi: -95), 0)
    }

    func testPhoneRow() {
        let s = PhoneSignal(level: 3, dbm: -97, network: "LTE", operatorName: "Vodafone RO", readAt: Date())
        XCTAssertEqual(NetworkLookPolicy.phoneRow(s, onHotspot: true), "📱 Phone: LTE · 3/4 · -97 dBm · Vodafone RO")
        XCTAssertEqual(NetworkLookPolicy.phoneRow(s, onHotspot: false), "📱 Phone: not on its hotspot")
    }

    func testPhoneStatusParsesSignalAndRoaming() {
        let json = #"{"signal":{"level":7,"dbm":-101,"network":"5G"},"roaming":{"cycleTotal":5000000000,"today":1,"limit":13703000000,"readAt":1760950000000,"guardOff":true}}"#
        let (s, r) = PhoneStatusPolicy.parse(Data(json.utf8), now: Date())
        XCTAssertEqual(s?.level, 4, "clamped to 0…4")
        XCTAssertEqual(s?.network, "5G")
        XCTAssertEqual(r?.remaining, 8_703_000_000)
        XCTAssertEqual(r?.guardOff, true)
    }

    func testConfigParsesCommentsAndSpaces() {
        let c = Config.parse(text: """
        # the phone
        PHONE_BT_ADDRESS = a1-b2-c3-d4-e5-f6   # from System Settings
        HOTSPOT_SSID=my phone
        broken line
        """)
        XCTAssertEqual(c["PHONE_BT_ADDRESS"], "a1-b2-c3-d4-e5-f6")
        XCTAssertEqual(c["HOTSPOT_SSID"], "my phone")
        XCTAssertEqual(c.count, 2)
    }
}

/// The ↓/↑ figures: a 5 s average and the best 5 s average in 10 minutes.
final class RateHistoryTests: XCTestCase {

    func testAverageIsTheLastFiveSamples() {
        var h = RateHistory()
        let t0 = Date()
        for (i, v) in [100.0, 0, 0, 10, 10, 10, 10, 10].enumerated() { h.add(v, at: t0 + Double(i)) }
        XCTAssertEqual(h.average, 10)
    }

    /// One spike is not a sustained rate: the max is of 5-sample means.
    func testMaxIsTheBestFiveSecondMean() {
        var h = RateHistory()
        let t0 = Date()
        for (i, v) in [0.0, 500, 0, 0, 0, 0, 0, 20, 20, 20, 20, 20].enumerated() { h.add(v, at: t0 + Double(i)) }
        XCTAssertEqual(h.maxAverage, 100)
    }

    func testSamplesOlderThanTenMinutesFallOut() {
        var h = RateHistory()
        let t0 = Date()
        h.add(1_000_000, at: t0)
        h.add(5, at: t0 + 601)
        XCTAssertEqual(h.maxAverage, 5)
    }

    func testBookLine() {
        let now = Date()
        let r = NetworkRecord(name: "📱 phone", kind: "hotspot", maxDown: 8_400_000, maxUp: 1_100_000,
                              latencyMs: 38.2, speedDown: 21_000_000, speedAt: now, lastSeen: now - 7200)
        XCTAssertEqual(NetworkBookPolicy.line(r, now: now),
                       "📱 phone — ↓ max 8.4 MB/s · ↑ max 1.1 MB/s · ⚡ 21.0 MB/s · 38 ms · 2 h ago")
    }
}

/// The badge beside the phone's bars, and reading Vodafone's *123# answer.
final class RoamingAlertTests: XCTestCase {
    private func reading(roaming: Bool, blocked: Bool = false, ago: TimeInterval = 60) -> RoamingWarningPolicy.Reading {
        .init(cycleTotal: 0, cycleHotspot: 0, today: 1, roamingNow: roaming, limit: 13_380_000_000,
              lowFraction: 0.1, nextReset: Date(), readAt: Date() - ago, hotspotBlocked: blocked)
    }

    func testUnderFiveGigsWarns() {
        XCTAssertEqual(RoamingAlertPolicy.alert(reading(roaming: true), left: 4_900_000_000, now: Date()), .low)
        XCTAssertNil(RoamingAlertPolicy.alert(reading(roaming: true), left: 5_100_000_000, now: Date()))
    }

    func testNothingLeftOrBlockedIsCapped() {
        XCTAssertEqual(RoamingAlertPolicy.alert(reading(roaming: true), left: 0, now: Date()), .capped)
        XCTAssertEqual(RoamingAlertPolicy.alert(reading(roaming: true, blocked: true), left: 900_000_000, now: Date()), .capped)
    }

    /// At home the same numbers cost nothing; a stale reading says nothing about now.
    func testNoBadgeAtHomeOrOnAStaleReading() {
        XCTAssertNil(RoamingAlertPolicy.alert(reading(roaming: false), left: 0, now: Date()))
        XCTAssertNil(RoamingAlertPolicy.alert(reading(roaming: true, ago: 3600), left: 0, now: Date()))
    }

    func testUssdNumbers() {
        XCTAssertEqual(UssdPolicy.megabytes(in: "Mai ai 12,5 GB in SEE pana la 02.11"), 12_500)
        XCTAssertEqual(UssdPolicy.megabytes(in: "Trafic ramas: 850 MB"), 850)
        XCTAssertNil(UssdPolicy.megabytes(in: "Serviciu indisponibil"))
    }
}
