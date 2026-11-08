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
}
