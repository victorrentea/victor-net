import CryptoKit
import XCTest
@testable import VictorNet

final class ClipSyncTests: XCTestCase {
    private let key = ClipCrypto.key(hex: String(repeating: "ab", count: 32))!
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func clip(from: String = "phone", at: Date? = nil, id: String = "x") -> ClipEnvelope {
        ClipEnvelope(id: id, ts: Int64((at ?? t0).timeIntervalSince1970 * 1000), from: from, text: "4111 ăîș")
    }

    func testASealedClipOpensWithTheSameKey() throws {
        let sealed = try ClipCrypto.seal(clip(), key: key)
        XCTAssertEqual(ClipCrypto.open(sealed, key: key), clip())
    }

    func testTheCiphertextIsSafeInAUrl() throws {
        let sealed = try ClipCrypto.seal(clip(), key: key)
        XCTAssertNil(sealed.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testAnotherKeyOrATamperedCiphertextOpensNothing() throws {
        let sealed = try ClipCrypto.seal(clip(), key: key)
        XCTAssertNil(ClipCrypto.open(sealed, key: ClipCrypto.key(hex: String(repeating: "cd", count: 32))!))
        let flipped = (sealed.first == "A" ? "B" : "A") + sealed.dropFirst()
        XCTAssertNil(ClipCrypto.open(flipped, key: key))
    }

    func testAKeyMustBeSixtyFourHexDigits() {
        XCTAssertNil(ClipCrypto.key(hex: "abcd"))
        XCTAssertNil(ClipCrypto.key(hex: String(repeating: "zz", count: 32)))
    }

    func testOnlyNewRealTextIsSent() {
        XCTAssertTrue(ClipPolicy.shouldSend(text: "new", types: ["public.utf8-plain-text"], lastSynced: "old"))
        XCTAssertFalse(ClipPolicy.shouldSend(text: "same", types: [], lastSynced: "same"))
        XCTAssertFalse(ClipPolicy.shouldSend(text: "", types: [], lastSynced: nil))
        XCTAssertFalse(ClipPolicy.shouldSend(text: nil, types: [], lastSynced: nil))
        XCTAssertFalse(ClipPolicy.shouldSend(text: String(repeating: "x", count: ClipPolicy.maxText + 1), types: [], lastSynced: nil))
    }

    func testAThrowawayCopyIsNotSentButAConcealedOneIs() {
        XCTAssertFalse(ClipPolicy.shouldSend(text: "t", types: ["org.nspasteboard.TransientType"], lastSynced: nil))
        XCTAssertTrue(ClipPolicy.shouldSend(text: "t", types: ["org.nspasteboard.ConcealedType"], lastSynced: nil))
    }

    func testAReplayOrAnEchoIsRefused() {
        XCTAssertTrue(ClipPolicy.believable(clip(at: t0), now: t0, seen: []))
        XCTAssertFalse(ClipPolicy.believable(clip(), now: t0, seen: ["x"]))
        XCTAssertFalse(ClipPolicy.believable(clip(from: "mac"), now: t0, seen: []))
        XCTAssertFalse(ClipPolicy.believable(clip(at: t0.addingTimeInterval(-601)), now: t0, seen: []))
    }
}
