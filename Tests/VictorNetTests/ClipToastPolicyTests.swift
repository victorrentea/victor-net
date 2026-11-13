import XCTest
@testable import VictorNet

final class ClipToastPolicyTests: XCTestCase {
    func testAWebAddressAloneIsALink() {
        XCTAssertEqual(ClipToastPolicy.link(in: "https://example.com/a?b=1")?.absoluteString, "https://example.com/a?b=1")
        XCTAssertEqual(ClipToastPolicy.link(in: "  http://example.com\n")?.host, "example.com")
        XCTAssertEqual(ClipToastPolicy.link(in: "www.example.com/x")?.absoluteString, "https://www.example.com/x")
    }

    func testTextAroundAnAddressOrOtherSchemesAreNotLinks() {
        XCTAssertNil(ClipToastPolicy.link(in: "see https://example.com"))
        XCTAssertNil(ClipToastPolicy.link(in: "file:///etc/passwd"))
        XCTAssertNil(ClipToastPolicy.link(in: "javascript:alert(1)"))
        XCTAssertNil(ClipToastPolicy.link(in: "https://localhost"))
        XCTAssertNil(ClipToastPolicy.link(in: "hello"))
        XCTAssertNil(ClipToastPolicy.link(in: ""))
    }

    func testThePreviewIsOneShortLine() {
        XCTAssertEqual(ClipToastPolicy.preview("hello\nworld"), "hello")
        XCTAssertEqual(ClipToastPolicy.preview("a   b\tc"), "a b c")
        let long = ClipToastPolicy.preview(String(repeating: "x", count: 200))
        XCTAssertEqual(long.count, ClipToastPolicy.maxPreview)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testACardNumberShowsOnlyItsLastFourDigits() {
        XCTAssertEqual(ClipToastPolicy.preview("4111 1111 1111 1234"), "•••• 1234")
        XCTAssertEqual(ClipToastPolicy.preview("4111-1111-1111-1234"), "•••• 1234")
        XCTAssertEqual(ClipToastPolicy.preview("0720 123 456"), "0720 123 456")
    }

    func testNoSpacingTrickShowsAWholeCard() {
        XCTAssertEqual(ClipToastPolicy.preview("4111 1111 1111 1234\n"), "•••• 1234")
        XCTAssertEqual(ClipToastPolicy.preview("4111\u{00A0}1111\u{00A0}1111\u{00A0}1234"), "•••• 1234")
        XCTAssertEqual(ClipToastPolicy.preview("4111111111111234\t12/29 123"), "•••• 1234")
    }

    func testAnIbanPasswordOrCodeIsHidden() {
        XCTAssertEqual(ClipToastPolicy.preview("RO49 AAAA 1B31 0075 9384 0000"), "IBAN •••• 0000")
        XCTAssertEqual(ClipToastPolicy.preview("Tr0ub4dor&3x"), "••••••••")
        XCTAssertEqual(ClipToastPolicy.preview("482913"), "••••••••")
        // Ordinary clips stay readable.
        XCTAssertEqual(ClipToastPolicy.preview("victor@example.com"), "victor@example.com")
        XCTAssertEqual(ClipToastPolicy.preview("Bucharest"), "Bucharest")
        XCTAssertEqual(ClipToastPolicy.preview("2026"), "••••••••")
    }
}
