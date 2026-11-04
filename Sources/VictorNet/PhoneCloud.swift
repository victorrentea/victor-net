import Foundation

/// 🔋 The phone's battery as it last pushed it to the relay: the only way that works
/// from any network, as long as both have internet. Docs: docs/victor-net.md.
final class PhoneCloud {
    private static let every: TimeInterval = 60

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5
        c.timeoutIntervalForResource = 8
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    private var timer: Timer?
    private var lastAnswer: Date?
    private var lastError: String?

    var onHotspot: () -> Bool = { false }
    /// Main thread.
    var onReading: ((PhoneBattery) -> Void)?

    func start() {
        guard !Config.relayURL.isEmpty, !Config.relayToken.isEmpty else { return }
        let t = Timer(timeInterval: Self.every, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    var stateJSON: [String: Any] {
        ["last_answer_ago_s": orNull(lastAnswer.map { Int(Date().timeIntervalSince($0)) }),
         "last_error": orNull(lastError)]
    }

    private func tick() {
        guard !onHotspot(), let url = URL(string: Config.relayURL + "/api/phone-battery") else { return }
        var request = URLRequest(url: url)
        request.setValue(Config.relayToken, forHTTPHeaderField: "X-Bridge-Token")
        session.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            RunLoop.main.perform(inModes: [.common]) {
                guard let self else { return }
                let reading = status == 200 ? data.flatMap { PhoneBattery.parseCloud($0, now: Date()) } : nil
                if let reading {
                    self.lastAnswer = Date()
                    self.lastError = nil
                    self.onReading?(reading)
                } else {
                    let why = error?.localizedDescription ?? status.map { "HTTP \($0)" } ?? "no answer"
                    if why != self.lastError { netInfo("🔋 phone battery from the relay: \(why)") }
                    self.lastError = why
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }.resume()
    }
}
