import AppKit

/// Burn-rate forecast for the 5-hour window: the last hour's positive rise,
/// projected forward to the window's reset. Same lower-bound framing as
/// HistoryGraphView.rateBars (the reset-spanning undercount caveat applies).
///
/// The sampling window is clipped at the CURRENT 5-hour window's start
/// (resetsAt − 5 h): a plain "last hour" would count the pre-reset climb after
/// a reset and, with ~5 fresh hours to project across, fire spurious pace
/// warnings for up to an hour after every reset that follows heavy use.
struct Forecast {
    var ratePerHour: Double          // %-points per hour, ≥ 0
    var projected: Double            // capped to 100, never below current
    var crosses: Bool                // projection reaches 100 before the reset
    var crossTime: Date?             // when it does (nil unless crosses)

    static let gapTolerance: TimeInterval = 12 * 60   // matches HistoryGraphView
    static let fiveWindow: TimeInterval = 5 * 3600

    static func compute(samples: [HistorySample], now: Date,
                        current: Double?, resetsAt: Date?) -> Forecast? {
        guard let current else { return nil }
        var windowStart = now.addingTimeInterval(-3600)
        if let resetsAt {
            windowStart = max(windowStart, resetsAt.addingTimeInterval(-fiveWindow))
        }
        let pts = samples.filter { $0.t > windowStart && $0.five != nil }

        var rise = 0.0
        for i in 1..<max(1, pts.count) {
            let dt = pts[i].t.timeIntervalSince(pts[i - 1].t)
            if dt > 0, dt <= gapTolerance {
                rise += max(0, pts[i].five! - pts[i - 1].five!)
            }
        }
        // Fold in the freshest reading: a fetch inside the sampling throttle
        // updates `current` without appending a sample, and a sharp burn in
        // that gap must not be invisible to the rate.
        var spanEnd = pts.last?.t
        if let last = pts.last, let lastFive = last.five {
            let dt = now.timeIntervalSince(last.t)
            if dt > 0, dt <= gapTolerance {
                rise += max(0, current - lastFive)
                spanEnd = now
            }
        }
        let span = (pts.first?.t).flatMap { first in spanEnd?.timeIntervalSince(first) } ?? 0
        // One poll interval of history minimum — a shorter baseline is noise.
        let rate = span >= 240 ? rise / span * 3600 : 0

        guard let resetsAt, resetsAt > now else {
            return Forecast(ratePerHour: rate, projected: current, crosses: false, crossTime: nil)
        }
        let toResetHr = resetsAt.timeIntervalSince(now) / 3600
        let uncapped = current + rate * toResetHr
        // `current` can legitimately exceed 100 (the API reports 100+): the
        // projection then holds at current, and "crossing" is meaningless.
        let projected = current >= 100 ? current : min(100, max(current, uncapped))
        let crosses = current < 100 && uncapped > 100 && rate > 0
        var crossTime: Date?
        if crosses {
            let frac = max(0, min(1, (100 - current) / (uncapped - current)))
            crossTime = now.addingTimeInterval(resetsAt.timeIntervalSince(now) * frac)
        }
        return Forecast(ratePerHour: rate, projected: projected, crosses: crosses, crossTime: crossTime)
    }
}

/// The panel's single derived state. Precedence: the auth states first, then
/// rate-limited BEFORE data-stale (an active 429 cooldown also makes the data
/// stale — the cause is more informative than the symptom), then usage states.
///
/// Note: tokenWait (our UsageError.stale — token expired, a Claude Code is
/// alive, we politely wait) is deliberately distinct from dataStale (no fetch
/// landed in a while, e.g. after sleep). The design handoff conflated them;
/// they need opposite copy.
enum PanelState: Equatable {
    case signedOut
    case tokenWait
    case rateLimited(until: Date)
    case dataStale(minutes: Int)
    case red
    case pace
    case watch
    case normal

    struct Inputs {
        var needsAuth: Bool
        var tokenWait: Bool
        var cooldownUntil: Date
        var fetchedAt: Date?
        var five: Double?
        var forecast: Forecast?
        var now: Date
    }

    static let staleAfter: TimeInterval = 12 * 60    // > 2 poll windows

    static func derive(_ i: Inputs) -> PanelState {
        if i.needsAuth { return .signedOut }
        if i.tokenWait { return .tokenWait }
        if i.cooldownUntil > i.now { return .rateLimited(until: i.cooldownUntil) }
        if let at = i.fetchedAt, i.now.timeIntervalSince(at) > staleAfter {
            return .dataStale(minutes: Int(i.now.timeIntervalSince(at) / 60))
        }
        if let five = i.five, five >= 90 { return .red }
        if i.forecast?.crosses == true { return .pace }
        if let five = i.five, five >= 70 { return .watch }
        return .normal
    }

    /// The state dot's color. Hard rule from the design: red only for a real
    /// ≥ 90%; amber only on forecast-flavored states; coral otherwise.
    var dotColor: NSColor {
        switch self {
        case .red:                      return .systemRed
        case .pace, .watch, .rateLimited: return .systemOrange
        case .signedOut, .tokenWait, .dataStale: return .tertiaryLabelColor
        case .normal:                   return StatusRenderer.claudeCoral
        }
    }

    /// One banner sentence. `hm`/`rel` are display formatters supplied by the
    /// caller so all time strings share the app's locale-aware formatting.
    func message(five: Double?, forecast: Forecast?, resetsAt: Date?, now: Date,
                 hm: (Date) -> String, rel: (TimeInterval) -> String) -> String {
        func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }
        switch self {
        case .signedOut:
            return "Signed out. Claude Code isn't sharing a token — open Claude Code, sign in, then reopen this menu."
        case .tokenWait:
            return "Waiting for Claude Code to refresh the sign-in token. Numbers may lag until it does."
        case .rateLimited(let until):
            return "Rate-limited by the server, backing off. Next check ~\(hm(until)); the reading can trail by a few minutes."
        case .dataStale(let minutes):
            return "Last reading \(minutes) min ago; your Mac may have slept. It refreshes on open and every ~5 min."
        case .red:
            guard let five, let resetsAt else { return "Red zone on the 5-hour window." }
            return "Red zone — \(pct(max(0, 100 - five))) headroom left on the 5-hour window. Resets \(hm(resetsAt)), in \(rel(resetsAt.timeIntervalSince(now)))."
        case .pace:
            guard let cross = forecast?.crossTime, let resetsAt else { return "On pace to reach the 5-hour cap before it resets." }
            return "At this pace you reach 100% around \(hm(cross)) — \(rel(resetsAt.timeIntervalSince(cross))) before the \(hm(resetsAt)) reset. Ease off to coast in."
        case .watch:
            guard let five else { return "Above 70% of the 5-hour window." }
            if let projected = forecast?.projected, let resetsAt {
                return "\(pct(five)) used, \(pct(100 - five)) to go. At this pace about \(pct(projected)) by the \(hm(resetsAt)) reset — still clear."
            }
            return "\(pct(five)) of the 5-hour window used."
        case .normal:
            guard let five else { return "Waiting for the first reading…" }
            if let projected = forecast?.projected, let resetsAt, resetsAt > now {
                return "At this pace the 5-hour window settles near \(pct(projected)) before it resets at \(hm(resetsAt)). Plenty of headroom."
            }
            return "\(pct(five)) of the 5-hour window used. Plenty of headroom."
        }
    }
}
