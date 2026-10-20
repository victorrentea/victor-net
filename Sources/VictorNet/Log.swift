import Foundation

// Log format, the same one Victor Addons, Victor Effects and Victor Insomnia write:
//   HH:MM:SS.f  PID  [name      ] info    message
//   HH:MM:SS.f  PID  [name      ] error   message

private let _pid = Int(ProcessInfo.processInfo.processIdentifier)
// name padded to 10 so the message column is always aligned
private let _name = "net       "

func netInfo(_ msg: String) { _netLog("info", msg) }
func netError(_ msg: String) { _netLog("error", msg) }

private func _netLog(_ level: String, _ msg: String) {
    let now = Date()
    let c = Calendar.current
    let ts = String(format: "%02d:%02d:%02d.%d",
                    c.component(.hour, from: now), c.component(.minute, from: now),
                    c.component(.second, from: now), c.component(.nanosecond, from: now) / 100_000_000)
    let lvl = level == "error" ? "error   " : "info    "
    let line = "\(ts) \(String(format: "%5d", _pid))  [\(_name)] \(lvl)\(msg)"
    if level == "error" {
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
    } else {
        print(line)
    }
}
