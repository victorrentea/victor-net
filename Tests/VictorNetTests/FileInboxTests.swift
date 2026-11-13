import CryptoKit
import XCTest
@testable import VictorNet

final class FileInboxTests: XCTestCase {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID())")
    private let key = SymmetricKey(size: .bits256)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func roundTrip(_ wire: Data, size: Int64, key: SymmetricKey? = nil) throws -> Data {
        let input = dir.appendingPathComponent("wire"), output = dir.appendingPathComponent("plain")
        try wire.write(to: input)
        try FileFrames.decrypt(input, to: output, key: key ?? self.key, expectedSize: size)
        return try Data(contentsOf: output)
    }

    func testDecryptsAcrossFrames() throws {
        let plain = Data((0..<2500).map { UInt8($0 % 251) })
        XCTAssertEqual(try roundTrip(FileFrames.encrypt(plain, key: key, chunk: 1000), size: 2500), plain)
    }

    func testAnEmptyFileIsAFile() throws {
        XCTAssertEqual(try roundTrip(Data(), size: 0), Data())
    }

    func testRefusesACutOffTail() throws {
        let plain = Data(repeating: 7, count: 2500)
        let wire = try FileFrames.encrypt(plain, key: key, chunk: 1000)
        XCTAssertThrowsError(try roundTrip(wire.prefix(1032), size: 2500))
        XCTAssertThrowsError(try roundTrip(wire.prefix(wire.count - 3), size: 2500))
    }

    func testRefusesReorderedFrames() throws {
        let first = try FileFrames.encrypt(Data(repeating: 1, count: 10), key: key, chunk: 5)
        let frame = first.count / 2
        let swapped = first.suffix(frame) + first.prefix(frame)
        XCTAssertThrowsError(try roundTrip(Data(swapped), size: 10))
    }

    func testRefusesAnotherKey() throws {
        let wire = try FileFrames.encrypt(Data(repeating: 1, count: 10), key: key)
        XCTAssertThrowsError(try roundTrip(wire, size: 10, key: SymmetricKey(size: .bits256)))
    }

    func testANameCannotEscapeDownloads() {
        XCTAssertEqual(FileInboxPolicy.safeName("../../.ssh/authorized_keys"), "authorized_keys")
        XCTAssertEqual(FileInboxPolicy.safeName("..\\..\\x.pdf"), "x.pdf")
        XCTAssertEqual(FileInboxPolicy.safeName(".hidden"), "hidden")
        XCTAssertEqual(FileInboxPolicy.safeName("photo\u{202E}gpj.command"), "photogpj.command")
        XCTAssertEqual(FileInboxPolicy.safeName(".."), "shared-file")
        XCTAssertEqual(FileInboxPolicy.safeName("factură mai.pdf"), "factură mai.pdf")
    }

    func testATakenNameGetsANumber() {
        let taken: Set<String> = ["/d/a.pdf", "/d/a (1).pdf", "/d/b"]
        let folder = URL(fileURLWithPath: "/d")
        func path(_ n: String) -> String { FileInboxPolicy.destination(for: n, in: folder) { taken.contains($0) }.path }
        XCTAssertEqual(path("a.pdf"), "/d/a (2).pdf")
        XCTAssertEqual(path("b"), "/d/b (1)")
        XCTAssertEqual(path("c.pdf"), "/d/c.pdf")
    }

    func testAnOfferDecodesFromThePhonesEnvelope() throws {
        let json = #"{"id":"e","ts":1,"from":"phone","text":"","files":[{"id":"f","name":"a.pdf","size":3,"key":"00"}],"ips":["10.0.0.1"]}"#
        let clip = try JSONDecoder().decode(ClipEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(clip.files?.first?.name, "a.pdf")
        XCTAssertEqual(clip.ips, ["10.0.0.1"])
    }

    func testARelayedScreenshotDecodes() throws {
        let json = #"{"id":"e","ts":1,"from":"phone","text":"","relay":true,"files":[{"id":"f","name":"s.png","size":3,"key":"00","clipboard":true}]}"#
        let clip = try JSONDecoder().decode(ClipEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(clip.relay, true)
        XCTAssertEqual(clip.files?.first?.clipboard, true)
    }

    func testAPlainClipStillDecodes() throws {
        let json = #"{"id":"e","ts":1,"from":"phone","text":"hi"}"#
        XCTAssertNil(try JSONDecoder().decode(ClipEnvelope.self, from: Data(json.utf8)).files)
    }
}
