import Foundation

/// Deterministic conversion from a LOCAL wall-clock date/time (what the model emits as text) to
/// epoch seconds, in the user's timezone. The model never computes epochs; this does it exactly.
/// Mirror of the macOS app's `ScheduleTime` (kept separate per-target, same semantics).
public enum ScheduleTime {
    /// `date` = "yyyy-MM-dd"; `time` = "HH:mm" (24h) or nil → midnight. Returns nil on bad input.
    public static func epoch(date: String, time: String?, tz: TimeZone) -> Double? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        if let time, !time.isEmpty {
            f.dateFormat = "yyyy-MM-dd HH:mm"
            if let d = f.date(from: "\(date) \(time)") { return d.timeIntervalSince1970 }
        }
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: date)?.timeIntervalSince1970
    }
}
