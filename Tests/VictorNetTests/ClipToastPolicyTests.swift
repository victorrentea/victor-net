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

    func testThePreviewShowsOnlyTheFirstThreeCharacters() {
        for secret in ["4111 1111 1111 1234", "RO49 AAAA 1B31 0075 9384 0000", "Tr0ub4dor&3x",
                       "Your code is 482913", "pass@word.1", "correct horse battery staple"] {
            let shown = ClipToastPolicy.preview(secret)
            XCTAssertEqual(shown, "\(secret.prefix(3))…")
            XCTAssertFalse(shown.contains("482913") || shown.contains("1234") || shown.contains("ub4"))
        }
    }

    func testAShortClipIsShownWholeOnOneLine() {
        XCTAssertEqual(ClipToastPolicy.preview(" x\n"), "x")
        XCTAssertEqual(ClipToastPolicy.preview("abc"), "abc")
        XCTAssertEqual(ClipToastPolicy.preview("a\nbcdef"), "a b…")
        XCTAssertEqual(ClipToastPolicy.preview("  \n"), "")
    }

    func testTheToastIsOneLine() {
        XCTAssertTrue(ClipToastPolicy.line("Hello secret world") == ("📋 From phone:", "Hel…"))
        XCTAssertTrue(ClipToastPolicy.line("https://example.com/a") == ("🔗 From phone:", "example.com"))
    }
}
