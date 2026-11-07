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
        let clean = last.filter { !$0.isNewline && $0 != "\0" && $0 != ":" }
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
/// share. With none, the phone puts it on Railway and offers it again. Not taken in time, the
/// phone keeps it in its own Downloads.
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
    /// The direct way and Railway can both offer a file: the first one that lands wins.
    private var taken: [String] = []

    var stateJSON: [String: Any] {
        ["last_ago_s": orNull(last.map { Int(Date().timeIntervalSince($0.0)) }),
         "last_name": orNull(last?.1), "last_error": orNull(lastError)]
    }

    /// Main thread.
    func accept(_ files: [FileOffer], ips: [String], relay: Bool) {
        for file in files where !taken.contains(file.id) {
            netInfo("📥 \(file.size) bytes offered by the phone\(relay ? ", on Railway" : "")")
            if relay { fromRelay(file) } else { download(file, from: ips) }
        }
    }

    private func fromRelay(_ file: FileOffer) {
        guard let key = ClipCrypto.key(hex: file.key), let url = URL(string: "\(Config.relayURL)/api/file/\(file.id)") else { return }
        var request = URLRequest(url: url)
        request.setValue(Config.relayToken, forHTTPHeaderField: "X-Bridge-Token")
        session.downloadTask(with: request) { [weak self] temp, response, error in
            guard let self else { return }
            guard let temp, (response as? HTTPURLResponse)?.statusCode == 200, self.store(temp, file, key) else {
                return netInfo("📥 Railway: \(error?.localizedDescription ?? "no usable answer")")
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
            lastError = "no way to the phone"
            return netInfo("📥 no way to the phone for an offered file")
        }
        session.downloadTask(with: url) { [weak self] temp, response, error in
            guard let self else { return }
            if let temp, (response as? HTTPURLResponse)?.statusCode == 200, self.store(temp, file, key) {
                self.session.dataTask(with: URL(string: "http://\(ip):\(Config.phoneStatusPort)/file/done?id=\(file.id)")!).resume()
                return
            }
            netInfo("📥 \(ip): \(error?.localizedDescription ?? "no usable answer")")
            RunLoop.main.perform(inModes: [.common]) { self.download(file, from: Array(ips.dropFirst())) }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }.resume()
    }

    private static func putOnClipboard(_ image: Data) {
        guard let picture = NSImage(data: image) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([picture])
    }

    private func store(_ temp: URL, _ file: FileOffer, _ key: SymmetricKey) -> Bool {
        let fm = FileManager.default
        let plain = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: plain) }
        do {
            try FileFrames.decrypt(temp, to: plain, key: key, expectedSize: file.size)
            guard !taken.contains(file.id) else { return true }
            taken = Array((taken + [file.id]).suffix(64))
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
            last = (Date(), target.lastPathComponent)
            lastError = nil
            netInfo("📥 saved in Downloads, \(file.size) bytes")
            return true
        } catch {
            lastError = "\(error)"
            netInfo("📥 not saved: \(error)")
            return false
        }
    }
}
