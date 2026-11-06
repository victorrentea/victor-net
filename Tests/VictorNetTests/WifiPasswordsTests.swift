import XCTest
@testable import VictorNet

final class WifiPasswordsTests: XCTestCase {
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("wifi-passwords-\(UUID()).json")

    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    func testKeepsAPasswordExactlyPerNetwork() {
        WifiPasswords.store(" a #b= ", for: "home", in: url)
        WifiPasswords.store("other", for: "office", in: url)
        XCTAssertEqual(WifiPasswords.password(for: "home", in: url), " a #b= ")
        XCTAssertEqual(WifiPasswords.password(for: "office", in: url), "other")
        XCTAssertNil(WifiPasswords.password(for: "cafe", in: url))
    }

    func testTheFileIsOwnerOnly() throws {
        WifiPasswords.store("x", for: "home", in: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}
