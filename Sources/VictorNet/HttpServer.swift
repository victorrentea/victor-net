import AppKit
import Foundation
import Network

/// Headless hooks on `127.0.0.1:55126`, so "what does it think the network is?"
/// is one `curl`. Handlers run on the server's queue; anything that touches the
/// UI hops to the main run loop.
///
///   GET /ping                          → {"ok":true,"app":"victor-net","built":…}
///   GET /phone/battery                 → {"pct":63,"charging":false,"age_s":120} ({"pct":-1} = unknown); read by Victor Addons
///   GET /test/state                    → network, icon, traffic, phone link
///   GET /test/hotspot                  → open the phone's beacon channel now (see HotspotFallback)
///   GET /test/roaming                  → ask the phone over Bluetooth now; answers the previous state
///   GET /test/roaming/simulate/<pct>   → pretend <pct>% is left (`off` clears)
///   GET /test/vodafone/ask             → the menu's "Ask Vodafone" (*123#, over Bluetooth off the hotspot)
///   GET /test/more-row                 → the "More" row (searching / done) drawn to a PNG
///   GET /test/menu/open?close=4        → open the menu as a click would, closing itself (`more=1` unfolds More)
final class HttpServer {
    static let port: UInt16 = 55126

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "victor-net-http", qos: .utility)
    /// The route table lives with the app, which owns every piece it reads.
    private let route: (String, [String: String]) -> (Int, String)

    init(route: @escaping (String, [String: String]) -> (Int, String)) {
        self.route = route
    }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let listener = try? NWListener(using: params) else {
            netError("HTTP: failed to bind port \(Self.port)")
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: netInfo("HTTP test hooks on 127.0.0.1:\(Self.port)")
            case .failed(let err): netError("HTTP server failed: \(err)")
            default: break
            }
        }
        listener.start(queue: queue)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let (path, query) = Self.target(of: raw)
            let (status, body) = self.route(path, query)
            let reason = status == 200 ? "OK" : "Not Found"
            var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n".utf8)
            out.append(Data(body.utf8))
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    /// `GET /a/b?x=1 HTTP/1.1` → (`/a/b`, ["x": "1"]).
    static func target(of request: String) -> (String, [String: String]) {
        let parts = request.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let comps = URLComponents(string: String(parts[1])) else { return ("", [:]) }
        var q: [String: String] = [:]
        comps.queryItems?.forEach { q[$0.name] = $0.value ?? "" }
        return (comps.path, q)
    }

    static func json(_ o: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// `nil` as JSON `null`, without making the compiler infer `?? NSNull()` per literal.
func orNull(_ v: Any?) -> Any { v ?? NSNull() }
