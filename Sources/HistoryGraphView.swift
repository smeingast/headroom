import AppKit

/// Immutable snapshot the graph view draws. Built on the main actor in AppDelegate and
/// never crossing an actor boundary, so it needs no Sendable conformance. `samples` is
/// already sliced to `range` and oldest-first.
struct GraphData {
    var samples: [HistorySample]
    var mode: GraphMode
    var range: HistoryRange
    var colorMode: ColorMode
    var now: Date
    var fiveNow: Double?
    var weekNow: Double?

    /// Cheap identity so the view can skip redraws when nothing meaningful changed
    /// (menuNeedsUpdate fires on every menu-tracking tick). The `now / 30` bucket lets a
    /// held-open menu's window edge advance at most twice a minute, not on every tick.
    /// Includes the current readout values, so a forced refresh inside the sampling
    /// throttle (no new sample) still repaints the "5h NN%" line.
    var signature: String {
        let last = samples.last.map { Int($0.t.timeIntervalSince1970) } ?? 0
        let f = fiveNow.map { Int($0.rounded()) } ?? -1
        let w = weekNow.map { Int($0.rounded()) } ?? -1
        return "\(last)|\(samples.count)|\(mode.rawValue)|\(range.rawValue)|\(colorMode.rawValue)|\(f)|\(w)|\(Int(now.timeIntervalSince1970) / 30)"
    }
}

/// A passive sparkline of 5-hour (headline) and weekly utilization over time, shown as a
/// custom-view row inside the dropdown. Two modes: the raw utilization curve, or the
/// per-sample positive rise ("consumption rate"). Pure renderer: owns no fetch or storage.
@MainActor
final class HistoryGraphView: NSView {
    private var model: GraphData?

    /// A normal step is the 300s poll; above this, treat two samples as a data gap (sleep
    /// or errors): break the utilization line and emit no rate bar across it. Generous
    /// enough that a single slightly-late poll does not fragment the line.
    private let gapTolerance: TimeInterval = 12 * 60

    // Templates, not literal formats: the axis hour follows the user's 12/24-hour
    // clock preference, and the day label follows the locale's month/day order.
    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .current
        f.setLocalizedDateFormatFromTemplate("jmm"); return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .current
        f.setLocalizedDateFormatFromTemplate("MMMd"); return f
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Fill the menu width if a longer text row makes the menu wider than our base size;
        // drawing is responsive to bounds.width either way (the session rows are unbounded,
        // so we cannot pin to "the longest row" at build time).
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    /// Push fresh data; redraw only when the signature actually changed. displayIfNeeded()
    /// forces a synchronous repaint, since needsDisplay alone is not contractually serviced
    /// while a status-item menu is tracking.
    func update(_ d: GraphData) {
        guard d.signature != model?.signature else { return }
        model = d
        needsDisplay = true
        displayIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        // Resolve the dynamic ClaudeCoral (and label colors) against the menu bar's current
        // light/dark appearance at draw time.
        effectiveAppearance.performAsCurrentDrawingAppearance { self.render() }
    }

    // MARK: - Rendering

    private func render() {
        guard let m = model else { return }
        let b = bounds
        let leftGutter: CGFloat = 28, bottomAxis: CGFloat = 12, topPad: CGFloat = 5, rightPad: CGFloat = 8
        let plot = CGRect(x: b.minX + leftGutter, y: b.minY + bottomAxis,
                          width: max(1, b.width - leftGutter - rightPad),
                          height: max(1, b.height - bottomAxis - topPad))

        let fivePts = m.samples.compactMap { s in s.five.map { (s.t, $0) } }
        let weekPts = m.samples.compactMap { s in s.week.map { (s.t, $0) } }

        // Need at least two points in one drawable series; a lone sample (even with both
        // values) has nothing to connect, so keep showing the collecting state.
        if max(fivePts.count, weekPts.count) < 2 {
            drawCentered("Collecting history…", in: b, color: .secondaryLabelColor)
            return
        }

        let t0 = m.now.addingTimeInterval(-m.range.duration)
        func X(_ t: Date) -> CGFloat {
            plot.minX + CGFloat(max(0, min(1, t.timeIntervalSince(t0) / m.range.duration))) * plot.width
        }

        // Coral in Claude mode; neutral otherwise (tinting a whole time series by a single
        // current value is not meaningful for thresholds/heatmap). The readout still carries
        // the colored cue in every mode.
        let claude = m.colorMode == .claude
        let fiveColor = claude ? StatusRenderer.claudeCoral : NSColor.labelColor
        let weekColor = (claude ? StatusRenderer.claudeCoral : NSColor.labelColor).withAlphaComponent(0.5)

        if m.mode == .utilization {
            let peak = max(100.0, (fivePts + weekPts).map { $0.1 }.max() ?? 0)
            func Y(_ v: Double) -> CGFloat { plot.minY + CGFloat(min(v, peak) / peak) * plot.height }
            strokeHLine(at: Y(0), from: plot.minX, to: plot.maxX, color: .quaternaryLabelColor)
            strokeHLine(at: Y(100), from: plot.minX, to: plot.maxX, color: .tertiaryLabelColor, dashed: true)
            drawText("100", at: CGPoint(x: plot.minX - 26, y: Y(100) - 5), color: .tertiaryLabelColor)
            // weekly behind (thin line), 5-hour in front (line + faint fill)
            drawLine(weekPts, x: X, y: Y, color: weekColor, width: 1.0)
            drawLine(fivePts, x: X, y: Y, color: fiveColor, width: 1.5,
                     fillTo: claude ? plot.minY : nil, fillColor: fiveColor.withAlphaComponent(0.16))
        } else {
            let fiveBars = rateBars(fivePts)
            let weekBars = rateBars(weekPts)
            let peak = max(1.0, (fiveBars + weekBars).map { $0.1 }.max() ?? 1)
            func Y(_ v: Double) -> CGFloat { plot.minY + CGFloat(min(v, peak) / peak) * plot.height }
            strokeHLine(at: plot.minY, from: plot.minX, to: plot.maxX, color: .quaternaryLabelColor)
            drawBars(weekBars, x: X, y: Y, baseY: plot.minY, color: weekColor, width: 1.0)
            drawBars(fiveBars, x: X, y: Y, baseY: plot.minY, color: fiveColor, width: 1.5)
        }

        drawReadout(m, in: b)
        drawTimeAxis(m, plot: plot, t0: t0)
    }

    /// Stroke a polyline (optionally filled to a baseline), broken into segments at data
    /// gaps so sleep/outage gaps are not bridged with a fake line.
    private func drawLine(_ pts: [(Date, Double)], x X: (Date) -> CGFloat, y Y: (Double) -> CGFloat,
                          color: NSColor, width: CGFloat, fillTo baseY: CGFloat? = nil,
                          fillColor: NSColor? = nil) {
        var seg: [(Date, Double)] = []
        func flush() {
            defer { seg = [] }
            guard seg.count >= 1 else { return }
            if let baseY, let fc = fillColor, seg.count >= 2 {
                let fill = NSBezierPath()
                fill.move(to: CGPoint(x: X(seg[0].0), y: baseY))
                for p in seg { fill.line(to: CGPoint(x: X(p.0), y: Y(p.1))) }
                fill.line(to: CGPoint(x: X(seg[seg.count - 1].0), y: baseY))
                fill.close()
                fc.setFill(); fill.fill()
            }
            let path = NSBezierPath()
            path.lineWidth = width; path.lineJoinStyle = .round; path.lineCapStyle = .round
            for (i, p) in seg.enumerated() {
                let pt = CGPoint(x: X(p.0), y: Y(p.1))
                if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
            }
            color.setStroke(); path.stroke()
        }
        var prev: Date?
        for p in pts {
            if let pr = prev, p.0.timeIntervalSince(pr) > gapTolerance { flush() }
            seg.append(p); prev = p.0
        }
        flush()
    }

    /// Per-sample positive rise, normalized to "% points per ~5 min" so the unit is
    /// consistent across a short dt (Refresh Now) and across ranges. Suppressed across
    /// non-positive dt and gaps. A reset or aging produces a negative delta, which max(0,)
    /// discards, so no explicit reset detection is needed.
    ///
    /// Known, disclosed limitation: the single bar spanning a reset undercounts, because
    /// the rise is measured from the pre-reset value rather than from 0. Bounded and rare
    /// (weekly: once a week); fixing it cleanly needs the resets_at semantics we are
    /// instrumenting first, so it is deferred. Consistent with the lower-bound framing.
    private func rateBars(_ pts: [(Date, Double)]) -> [(Date, Double)] {
        var out: [(Date, Double)] = []
        guard pts.count >= 2 else { return out }
        for i in 1..<pts.count {
            let (pt, pv) = pts[i - 1]; let (ct, cv) = pts[i]
            let dt = ct.timeIntervalSince(pt)
            guard dt > 0, dt <= gapTolerance else { continue }
            out.append((ct, max(0, cv - pv) * 300 / dt))
        }
        return out
    }

    private func drawBars(_ bars: [(Date, Double)], x X: (Date) -> CGFloat, y Y: (Double) -> CGFloat,
                          baseY: CGFloat, color: NSColor, width: CGFloat) {
        color.setStroke()
        for (t, v) in bars where v > 0 {
            let xx = X(t)
            let p = NSBezierPath()
            p.lineWidth = width; p.lineCapStyle = .round
            p.move(to: CGPoint(x: xx, y: baseY))
            p.line(to: CGPoint(x: xx, y: Y(v)))
            p.stroke()
        }
    }

    private func strokeHLine(at y: CGFloat, from x0: CGFloat, to x1: CGFloat,
                             color: NSColor, dashed: Bool = false) {
        let p = NSBezierPath(); p.lineWidth = 0.5
        if dashed { p.setLineDash([2, 2], count: 2, phase: 0) }
        p.move(to: CGPoint(x: x0, y: y)); p.line(to: CGPoint(x: x1, y: y))
        color.setStroke(); p.stroke()
    }

    private func drawReadout(_ m: GraphData, in rect: CGRect) {
        let f = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let s = NSMutableAttributedString()
        func add(_ label: String, _ v: Double?) {
            s.append(NSAttributedString(string: label,
                attributes: [.font: f, .foregroundColor: NSColor.secondaryLabelColor]))
            let vs = v == nil ? "—" : "\(Int(v!.rounded()))%"
            let col = v == nil ? NSColor.secondaryLabelColor : StatusRenderer.color(v!, m.colorMode)
            s.append(NSAttributedString(string: vs, attributes: [.font: f, .foregroundColor: col]))
        }
        add("5h ", m.fiveNow)
        s.append(NSAttributedString(string: "   ", attributes: [.font: f]))
        add("wk ", m.weekNow)
        let sz = s.size()
        s.draw(at: CGPoint(x: rect.maxX - sz.width - 8, y: rect.maxY - sz.height - 1))
    }

    private func drawTimeAxis(_ m: GraphData, plot: CGRect, t0: Date) {
        let fmt = (m.range == .last5h || m.range == .last24h) ? Self.hmFormatter : Self.dayFormatter
        let f = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        drawText(fmt.string(from: t0), at: CGPoint(x: plot.minX, y: 0), color: .tertiaryLabelColor, font: f)
        let right = "now"
        let rw = (right as NSString).size(withAttributes: [.font: f]).width
        drawText(right, at: CGPoint(x: plot.maxX - rw, y: 0), color: .tertiaryLabelColor, font: f)
        let cap = (m.mode == .utilization ? "Utilization" : "Rise/5m") + " · " + m.range.title
        let cw = (cap as NSString).size(withAttributes: [.font: f]).width
        drawText(cap, at: CGPoint(x: plot.midX - cw / 2, y: 0), color: .quaternaryLabelColor, font: f)
    }

    private func drawText(_ s: String, at p: CGPoint, color: NSColor, font: NSFont? = nil) {
        let f = font ?? NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        (s as NSString).draw(at: p, withAttributes: [.font: f, .foregroundColor: color])
    }

    private func drawCentered(_ s: String, in rect: CGRect, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                    .foregroundColor: color]
        let sz = (s as NSString).size(withAttributes: attrs)
        (s as NSString).draw(at: CGPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2),
                             withAttributes: attrs)
    }
}
