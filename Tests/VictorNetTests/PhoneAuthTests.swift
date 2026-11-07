import CryptoKit
import XCTest
@testable import VictorNet

final class PhoneAuthTests: XCTestCase {
    private let key = ClipCrypto.key(hex: String(repeating: "0", count: 63) + "1")
    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    /// The same vector as Python's `hmac.new(key, b"1700000000|/hotspot/off", sha256)`,
    /// which is what `RequestAuth.kt` computes on the phone.
    func testMatchesTheReferenceHmac() {
        XCTAssertEqual(PhoneAuth.sign("/hotspot/off", key: key, now: at),
                       "/hotspot/off?auth=1700000000.b483baef9d659cb3bf04210474266e8d40a61747f3a056c976598400a17ab4aa")
    }

    func testAppendsToAnExistingQuery() {
        XCTAssertTrue(PhoneAuth.sign("/media?hold=1", key: key, now: at).hasPrefix("/media?hold=1&auth=1700000000."))
    }

    func testWithoutAKeyThePathIsUnchanged() {
        XCTAssertEqual(PhoneAuth.sign("/ussd", key: nil, now: at), "/ussd")
    }
}
