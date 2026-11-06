import XCTest
@testable import VictorNet

final class JoinFailureTests: XCTestCase {
    private let tmpErr = "Failed to join network tzutze.\nError: -3900  The operation couldn\u{2019}t be completed. tmpErr"

    func testTmpErrWithoutAPasswordAsksForOne() {
        XCTAssertTrue(JoinFailure.lacksPassword(tmpErr, typedOne: false))
    }

    func testAPasswordThatFailedIsNotAskedForAgain() {
        XCTAssertFalse(JoinFailure.lacksPassword(tmpErr, typedOne: true))
    }

    func testOtherFailuresAreJustShown() {
        XCTAssertFalse(JoinFailure.lacksPassword("Could not find network tzutze.", typedOne: false))
    }
}
