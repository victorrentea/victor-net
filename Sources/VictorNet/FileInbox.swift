import AppKit
import CryptoKit
import Foundation

/// One file offered by the phone, inside a sealed `ClipEnvelope`. `FileOutbox.kt` is the other end.
struct FileOffer: Codable, Equatable {
    let id: String
    let name: String
    let size: Int64
    /// 64 hex digits, for this file only.
    let key: String
    /// An image for the clipboard, not for Downloads: a screenshot taken on the phone.
    var clipboard: Bool? = nil
}

/// Frames of `length(4, big endian) + nonce + ciphertext + tag`; each frame's number is
/// authenticated, so they cannot be reordered, and the size in the offer catches a cut-off tail.
enum FileFrames {
    enum Failure: Error { case truncated, wrongSize }

    static func decrypt(_ input: URL, to output: URL, key: SymmetricKey, expectedSize: Int64) throws {
        let source = try FileHandle(forReadingFrom: input)
        defer { try? source.close() }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let sink = try FileHandle(forWritingTo: output)
        defer { try? sink.close() }
        var index: UInt64 = 0
        var written: Int64 = 0
        while let head = try source.read(upToCount: 4), !head.isEmpty {
            guard head.count == 4 else { throw Failure.truncated }
            let length = head.reduce(0) { $0 << 8 | Int($1) }
            // A frame is a 1 MB chunk plus nonce and tag: a 4 GB length read into memory is a
            // sender trying something (security review, 13 Nov 2026).
            guard length <= (1 << 20) + 64 else { throw Failure.truncated }
            guard written + Int64(length) <= expectedSize + 64 * Int64(index + 1) else { throw Failure.wrongSize }
            guard let frame = try source.read(upToCount: length), frame.count == length else { throw Failure.truncated }
            let box = try AES.GCM.SealedBox(combined: frame)
            let plain = try AES.GCM.open(box, using: key, authenticating: withUnsafeBytes(of: index.bigEndian) { Data($0) })
            try sink.write(contentsOf: plain)
            written += Int64(plain.count)
            index += 1
        }
        guard written == expectedSize else { throw Failure.wrongSize }
    }

    /// What the phone sends; only the tests use it here.
    static func encrypt(_ plain: Data, key: SymmetricKey, chunk: Int = 1 << 20) throws -> Data {
        var out = Data()
        var index: UInt64 = 0
        var offset = 0
        while offset < plain.count {
            let end = min(offset + chunk, plain.count)
            let sealed = try AES.GCM.seal(plain[offset..<end], using: key,
                                          authenticating: withUnsafeBytes(of: index.bigEndian) { Data($0) }).combined!
            out.append(contentsOf: withUnsafeBytes(of: UInt32(sealed.count).bigEndian) { Data($0) })
            out.append(sealed)
            offset = end
            index += 1
        }
        return out
    }
}

enum FileInboxPolicy {
    /// The name comes from another device: never a path, never hidden.
    static func safeName(_ name: String) -> String {
        let last = name.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? ""
        // No control or bidi-override characters either: "‮fdp.command" reads as "dnammoc.pdf"
        // (security review, 13 Nov 2026).
        let clean = String(String.UnicodeScalarView(last.unicodeScalars.filter { s in
            !CharacterSet.controlCharacters.contains(s) && s != ":" && !(0x202A...0x202E).contains(s.value)
                && !(0x2066...0x2069).contains(s.value) && s.value != 0x200E && s.value != 0x200F
        }))
        let visible = String(clean.drop { $0 == "." }).trimmingCharacters(in: .whitespaces)
        return visible.isEmpty ? "shared-file" : visible
    }

    /// "a.pdf", then "a (1).pdf", as Safari does.
    static func destination(for name: String, in folder: URL, exists: (String) -> Bool) -> URL {
        let safe = safeName(name)
        guard exists(folder.appendingPathComponent(safe).path) else { return folder.appendingPathComponent(safe) }
        let ext = (safe as NSString).pathExtension
        let stem = (safe as NSString).deletingPathExtension
        var n = 1
        while true {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            if !exists(candidate.path) { return candidate }
            n += 1
        }
    }
}

/// 📥 What the phone shares to "Mac Downloads" lands in ~/Downloads, and its screenshots on the
/// clipboard. Docs: docs/clipboard.md.
///
/// This Mac opens no port, so it pulls: `ClipSync` hands over a sealed offer, and the file comes
/// from the phone's `/file` on any address the offer lists, which works on any network the two
/// share. With none, the phone puts it on Railway and offers it again. Not taken in 3 min, the
/// phone deletes it and asks for another Share.
final class FileInbox {
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 3600
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    private var last: (Date, String)?
    private var lastError: String?

    /// Marked as downloaded, as a browser would: Gatekeeper then asks before anything in it runs
    /// (security review, 13 Nov 2026: any app on the phone can Share a file here).
    static func quarantine(_ url: URL) {
        let value = "0083;\(String(Int(Date().timeIntervalSince1970), radix: 16));Victor Net;\(UUID().uuidString)"
        _ = value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
    }
    /// Fetching or fetched: the direct way, Railway and the 5 s `/status` all offer the same file.
    private var claimed: [String] = []
    private let lock = NSLock()
    /// `GET /test/files/ignore?direct=1&s=` — pretend the phone is out of reach: only Railway
    /// offers (`direct=1`), or nothing at all, which leaves the file to the phone.
    private var ignoreUntil = Date.distantPast
    private var ignoreOnlyDirect = false

    var stateJSON: [String: Any] {
        ["last_ago_s": orNull(last.map { Int(Date().timeIntervalSince($0.0)) }),
         "last_name": orNull(last?.1), "last_error": orNull(lastError),
         "ignoring_s": max(0, Int(ignoreUntil.timeIntervalSinceNow)), "ignoring_only_direct": ignoreOnlyDirect]
    }

    func ignore(onlyDirect: Bool, for seconds: TimeInterval) {
        ignoreOnlyDirect = onlyDirect
        ignoreUntil = Date() + seconds
    }

    /// Main thread.
    func accept(_ files: [FileOffer], ips: [String], relay: Bool) {
        if Date() < ignoreUntil, !ignoreOnlyDirect || !relay { return }
        for file in files where claim(file.id) {
            netInfo("📥 \(file.size) bytes offered by the phone\(relay ? ", on Railway" : "")")
            if relay { fromRelay(file) } else { download(file, from: ips) }
        }
    }

    private func claim(_ id: String) -> Bool {
        lock.withLock {
            guard !claimed.contains(id) else { return false }
            claimed = Array((claimed + [id]).suffix(128))
            return true
        }
    }

    /// Failed: the next offer may try again.
    private func release(_ id: String) {
        lock.withLock { claimed.removeAll { $0 == id } }
    }

    private func fromRelay(_ file: FileOffer) {
        guard let key = ClipCrypto.key(hex: file.key), let url = URL(string: "\(Config.relayURL)/api/file/\(file.id)") else { return }
        var request = URLRequest(url: url)
        request.setValue(Config.relayToken, forHTTPHeaderField: "X-Bridge-Token")
        session.downloadTask(with: request) { [weak self] temp, response, error in
            guard let self else { return }
            guard let temp, (response as? HTTPURLResponse)?.statusCode == 200, self.store(temp, file, key) else {
                self.release(file.id)
                return netInfo("📥 Railway: \(error.map { "\(($0 as NSError).code)" } ?? "no usable answer")")
            }
            var done = URLRequest(url: url)
            done.httpMethod = "DELETE"
            done.setValue(Config.relayToken, forHTTPHeaderField: "X-Bridge-Token")
            self.session.dataTask(with: done).resume()
        }.resume()
    }

    private func download(_ file: FileOffer, from ips: [String]) {
        guard let ip = ips.first, let key = ClipCrypto.key(hex: file.key),
              let url = URL(string: "http://\(ip):\(Config.phoneStatusPort)/file?id=\(file.id)") else {
            release(file.id)
            lastError = "no way to the phone"
            return netInfo("📥 no way to the phone for an offered file")
        }
        session.downloadTask(with: url) { [weak self] temp, response, error in
            guard let self else { return }
            if let temp, (response as? HTTPURLResponse)?.statusCode == 200, self.store(temp, file, key) {
                let done = PhoneAuth.sign("/file/done?id=\(file.id)", key: Self.signingKey)
                self.session.dataTask(with: URL(string: "http://\(ip):\(Config.phoneStatusPort)\(done)")!).resume()
                return
            }
            netInfo("📥 \(ip): \(error.map { "\(($0 as NSError).code)" } ?? "no usable answer")")
            RunLoop.main.perform(inModes: [.common]) { self.download(file, from: Array(ips.dropFirst())) }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }.resume()
    }

    private static let signingKey = ClipCrypto.key(hex: Config.clipKey)

    /// Concealed, like a text clip: clipboard managers do not keep it, and a screenshot can
    /// hold a code or a bank balance.
    private static func putOnClipboard(_ image: Data) {
        guard let tiff = NSImage(data: image)?.tiffRepresentation else { return }
        let png = image.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes((png ? [.png] : []) + [.tiff, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        if png { pb.setData(image, forType: .png) }
        pb.setData(tiff, forType: .tiff)
    }

    private func store(_ temp: URL, _ file: FileOffer, _ key: SymmetricKey) -> Bool {
        let fm = FileManager.default
        let plain = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: plain) }
        do {
            try FileFrames.decrypt(temp, to: plain, key: key, expectedSize: file.size)
            if file.clipboard == true {
                let image = try Data(contentsOf: plain)
                RunLoop.main.perform(inModes: [.common]) { Self.putOnClipboard(image) }
                CFRunLoopWakeUp(CFRunLoopGetMain())
                netInfo("📥 screenshot on the clipboard, \(file.size) bytes")
                return true
            }
            let folder = try fm.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let target = FileInboxPolicy.destination(for: file.name, in: folder, exists: fm.fileExists(atPath:))
            try fm.moveItem(at: plain, to: target)
            Self.quarantine(target)
            last = (Date(), target.lastPathComponent)
            lastError = nil
            netInfo("📥 saved in Downloads, \(file.size) bytes")
            return true
        } catch {
            // The code only: a description can carry the file's name into the log.
            lastError = "\((error as NSError).domain) \((error as NSError).code)"
            netInfo("📥 not saved: \(lastError ?? "")")
            return false
        }
    }
}
