import CoreLocation
import Foundation

/// Answers one question: is this Mac at home right now?
///
/// It exists so the hotspot fallback stands down in the one place where a better
/// network is always available and the phone's data plan should not be spent.
/// At home the rule is manual: `tzutze` is preferred and nothing should reach for
/// the phone on its own.
///
/// **A Mac has no GPS** — no model ever has. CoreLocation positions it by the
/// Wi-Fi networks it can see, matched against Apple's database, so accuracy is
/// tens of metres in a city and the fix is unavailable in a place with no known
/// networks around. That is fine for this question, whose answer only has to be
/// right to within a building, but it is why the radius is generous and why an
/// unavailable fix is treated as "not home": failing to suppress the fallback
/// costs a needless hotspot, while wrongly suppressing it strands the Mac
/// offline, and only one of those is recoverable by waiting.
///
/// Home is read from `~/.victor-net/config.env` (`HOME_LAT`,
/// `HOME_LON`, optional `HOME_RADIUS_M`) rather than hardcoded, because this
/// repository is public and where somebody lives is not a build constant.
final class HomeGeofence: NSObject, CLLocationManagerDelegate {

    private static let defaultRadius: CLLocationDistance = 150

    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var _last: CLLocation?
    private var _lastAt: Date?

    /// A fix *measured* longer ago than this is not trusted to answer "am I home
    /// *now*". Measured, not received: CoreLocation hands back its cached fix with
    /// the cached timestamp, and on 29 Oct 2026 a fix from home, stamped on arrival,
    /// answered "home" in the metro twice, eight and twenty minutes after leaving.
    /// Two minutes is a walk out of the 200 m radius; the metro has no Wi-Fi to
    /// position by, so there the fresh fix never comes and the answer is "not home".
    private static let freshness: TimeInterval = 2 * 60
    /// How long `isAtHome(wait:)` gives CoreLocation for a fresh fix.
    static let fixWait: TimeInterval = 10

    private let home: CLLocation?
    private let radius: CLLocationDistance

    override init() {
        let secrets = Config.values
        if let lat = Double(secrets["HOME_LAT"] ?? ""), let lon = Double(secrets["HOME_LON"] ?? "") {
            home = CLLocation(latitude: lat, longitude: lon)
        } else {
            home = nil
        }
        radius = Double(secrets["HOME_RADIUS_M"] ?? "") ?? Self.defaultRadius
        super.init()
        manager.delegate = self
        // Hundred-metre accuracy is both enough and cheaper: asking for best
        // accuracy turns on more radios for an answer that would not change.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        // Significant-change monitoring rather than continuous updates: this is
        // asked a handful of times a day, at wake and on network changes, and a
        // laptop that has not moved does not need a stream of fixes.
        manager.startMonitoringSignificantLocationChanges()
        manager.requestLocation()
        if home == nil {
            netInfo("🏠 No HOME_LAT/HOME_LON in secrets — the geofence is off, the fallback runs everywhere")
        } else {
            netInfo("🏠 Home geofence armed (radius \(Int(radius))m)")
        }
    }

    /// True only when we have a recent fix *and* it is inside the radius.
    /// Everything else — no permission, no fix, a stale fix, no home configured
    /// — answers false, so an unanswerable question never strands the Mac
    /// offline.
    /// With `wait`, a missing or stale fix is asked for and waited on, up to
    /// `fixWait` — only off the main thread, where the delegate answers.
    func isAtHome(wait: Bool = false) -> Bool {
        guard let home else { return false }
        var fix = freshFix()
        if fix == nil {
            let asked = Date()
            DispatchQueue.main.async { self.manager.requestLocation() }
            if wait && !Thread.isMainThread {
                while fix == nil && Date().timeIntervalSince(asked) < Self.fixWait {
                    usleep(250_000)
                    fix = freshFix()
                }
            }
        }
        guard let fix else {
            if wait { netInfo("🏠 No location fix from the last \(Int(Self.freshness))s — treating as not-home") }
            return false
        }
        return fix.distance(from: home) <= radius
    }

    private func freshFix() -> CLLocation? {
        lock.lock(); defer { lock.unlock() }
        guard let l = _last, Date().timeIntervalSince(l.timestamp) < Self.freshness else { return nil }
        return l
    }

    /// The last fix and when it came, for `RoamingDataWatch`'s country lookup.
    func lastFix() -> (CLLocation, Date)? {
        lock.lock(); defer { lock.unlock() }
        guard let l = _last, let at = _lastAt else { return nil }
        return (l, at)
    }

    /// Logged so the coordinates can be read once and written into the secrets
    /// file; there is no UI for setting home, and inventing one for a value that
    /// changes when you move house would be the wrong trade.
    private func note(_ l: CLLocation) {
        let dist = home.map { String(format: "%.0fm from home", l.distance(from: $0)) } ?? "home not set"
        netInfo(String(format: "🏠 Location fix: HOME_LAT=%.6f HOME_LON=%.6f (±%.0fm, %@, measured %.0fs ago)",
                           l.coordinate.latitude, l.coordinate.longitude, l.horizontalAccuracy, dist,
                           Date().timeIntervalSince(l.timestamp)))
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { return }
        // `_lastAt` is when it arrived (for `lastFix`); freshness reads `l.timestamp`.
        lock.lock(); _last = l; _lastAt = Date(); lock.unlock()
        note(l)
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        netInfo("🏠 Location unavailable (\(error.localizedDescription)) — treating as not-home")
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .denied, .restricted:
            netInfo("🏠 Location denied — the geofence cannot suppress the fallback at home")
        case .notDetermined:
            break
        default:
            m.requestLocation()
        }
    }
}
