import XCTest
@testable import ClaudeUsageCore

/// Model-scoped weekly caps (v0.12): the `limits[]` decode, the ordering and id
/// rules the menu rows depend on, and the three surfaces that report a cap —
/// the rows, the header's binding-cap run, and the collapsed strip.
final class ScopedCapTests: XCTestCase {
    private let fetched = utcDate(2026, 1, 2, 13, 40)
    private let weekReset = utcDate(2026, 1, 9, 3, 0)

    private func cap(_ name: String, _ util: Double, reset: Date? = nil,
                     id: String? = nil) -> ScopedLimit {
        ScopedLimit(modelID: id, modelName: name, utilization: util,
                    resetsAt: reset, severity: nil, isActive: false)
    }

    private func snap(_ week: Double?, _ caps: [ScopedLimit],
                      weekReset: Date? = nil) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(claude: UsageSnapshot(
            fiveHour: LimitWindow(utilization: 15, resetsAt: nil),
            sevenDay: week.map { LimitWindow(utilization: $0, resetsAt: weekReset) },
            scoped: ScopedLimit.sorted(caps), fetchedAt: fetched))
    }

    // MARK: - Ordering and ids

    func testCapsSortWorstFirstThenByName() {
        let sorted = ScopedLimit.sorted([cap("Sonnet", 12), cap("Fable", 98), cap("Opus", 12)])
        XCTAssertEqual(sorted.map(\.modelName), ["Fable", "Opus", "Sonnet"])
    }

    func testDuplicateNamesGetDistinctIds() {
        // `extra(_:)` returns the FIRST match, so a collision would shadow a cap.
        let windows = ProviderUsageSnapshot.scopedWindows([cap("Fable", 98), cap("Fable", 40)])
        XCTAssertEqual(windows.map(\.id), ["fable", "fable-2"])
        XCTAssertEqual(Set(windows.map(\.id)).count, 2)
    }

    func testServerModelIdWinsOverTheNameSlug() {
        let windows = ProviderUsageSnapshot.scopedWindows([cap("Fable", 98, id: "model_abc")])
        XCTAssertEqual(windows.map(\.id), ["model_abc"])
    }

    func testUnslugabbleNameStillGetsAnId() {
        let windows = ProviderUsageSnapshot.scopedWindows([cap("!!!", 98)])
        XCTAssertEqual(windows.count, 1)
        XCTAssertFalse(windows[0].id.isEmpty)
    }

    // MARK: - The weekly-group cue

    func testWeeklyGroupCappedFromAScopedCapAlone() {
        // The pool is calm; the cap is not. This is the case the whole change exists for.
        XCTAssertTrue(snap(82, [cap("Fable", 98)]).weeklyGroupCapped)
        XCTAssertFalse(snap(82, [cap("Fable", 41)]).weeklyGroupCapped)
    }

    func testWeeklyGroupCappedFromThePoolItself() {
        XCTAssertTrue(snap(92, []).weeklyGroupCapped)
    }

    func testWeeklyGroupCappedUsesTheDisplayedPercentage() {
        XCTAssertTrue(snap(82, [cap("Fable", 89.6)]).weeklyGroupCapped)   // prints "90%"
        XCTAssertFalse(snap(82, [cap("Fable", 89.4)]).weeklyGroupCapped)  // prints "89%"
    }

    // MARK: - Rows

    func testRowsHideZeroCapsAndKeepWorstFirst() {
        let rows = AppDelegate.visibleCaps(snap(82, [cap("Fable", 98), cap("Haiku", 0),
                                                     cap("Opus", 41)])).rows
        XCTAssertEqual(rows.map(\.title), ["Weekly · Fable", "Weekly · Opus"])
    }

    func testOverflowStatesItsCeilingRatherThanABareCount() {
        let caps = (0..<13).map { cap("M\($0)", Double(30 - $0)) }
        let v = AppDelegate.visibleCaps(snap(82, caps))
        XCTAssertEqual(v.rows.count, AppDelegate.capRowCount)
        XCTAssertEqual(v.hidden, 3)
        XCTAssertEqual(v.hiddenCeiling, 25)                 // worst hidden is 20, so "under 25%"
        let title = AppDelegate.capsOverflowTitle(count: v.hidden, ceiling: v.hiddenCeiling).string
        XCTAssertEqual(title, "+3 more  ·  all under 25%")
    }

    func testEveryReturnedRowHasAMenuItemToLiveIn() {
        // The rescue rule can push past the soft budget, so the pool must be the
        // larger number. A row with no item would vanish silently — the exact
        // failure this feature exists to fix.
        XCTAssertGreaterThanOrEqual(AppDelegate.capRowPool, AppDelegate.capRowCount)
        let caps = (0..<40).map { cap("M\($0)", Double(99 - $0)) }   // 30 of them >= 70
        let v = AppDelegate.visibleCaps(snap(82, caps))
        XCTAssertLessThanOrEqual(v.rows.count, AppDelegate.capRowPool)
        XCTAssertEqual(v.rows.count + v.hidden, caps.count, "every cap is shown or counted")
    }

    func testOverflowCeilingIsStrictlyAboveTheWorstHiddenCap() {
        // "all under 20%" must not be printed when something hidden IS 20%.
        var caps = (0..<AppDelegate.capRowCount).map { cap("M\($0)", Double(95 - $0)) }
        caps.append(cap("Edge", 20))
        let v = AppDelegate.visibleCaps(snap(82, caps))
        XCTAssertEqual(v.hidden, 1)
        XCTAssertGreaterThan(Double(v.hiddenCeiling), 20)
    }

    func testLongRowNameIsBoundedToThePanelWidth() {
        let long = "Weekly · Claude Fable 5 Preview Extended Long Context Edition"
        let w = UsageWindow(id: "x", title: long, utilization: 98,
                            windowMinutes: 10080, resetsAt: nil)
        let title = AppDelegate.capRowTitle(w, poolResetsAt: nil, mode: .brand,
                                            resetFormatter: DateFormatter())
        XCTAssertLessThanOrEqual(title.size().width, AppDelegate.capRowWidth + 1,
                                 "a server-controlled name must not widen the menu")
        XCTAssertTrue(title.string.hasSuffix("98%"), "the percentage never truncates")

        // The widest case: a cap whose reset differs, so the row also carries the
        // ~100 pt reset run the other rows drop.
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE HH:mm"
        let odd = UsageWindow(id: "y", title: long, utilization: 98, windowMinutes: 10080,
                              resetsAt: weekReset.addingTimeInterval(86_400))
        let withReset = AppDelegate.capRowTitle(odd, poolResetsAt: weekReset, mode: .brand,
                                                resetFormatter: fmt)
        XCTAssertTrue(withReset.string.contains("resets"), "a differing reset is still stated")
        XCTAssertLessThanOrEqual(withReset.size().width, AppDelegate.capRowWidth + 1)
    }

    func testACapNearTheWallIsNeverHiddenByTheRowBudget() {
        // 12 caps, and the one that would fall past the budget is at 72%. Burying it
        // to keep the menu tidy is the exact blindness this change exists to fix.
        var caps = (0..<AppDelegate.capRowCount).map { cap("M\($0)", Double(95 - $0)) }
        caps.append(cap("Loud", 72))
        caps.append(cap("Quiet", 3))
        let v = AppDelegate.visibleCaps(snap(82, caps))
        XCTAssertTrue(v.rows.contains { $0.title == "Weekly · Loud" })
        XCTAssertEqual(v.rows.count, AppDelegate.capRowCount + 1)
        XCTAssertEqual(v.hidden, 1)                          // only "Quiet" is hidden
    }

    func testCriticalRowIsEmphasizedAndCalmRowIsRecessed() {
        let f = AppDelegate.visibleCaps(snap(82, [cap("Fable", 98), cap("Opus", 41)])).rows
        let hot = AppDelegate.capRowTitle(f[0], poolResetsAt: nil, mode: .monochrome,
                                          resetFormatter: DateFormatter())
        let calm = AppDelegate.capRowTitle(f[1], poolResetsAt: nil, mode: .monochrome,
                                           resetFormatter: DateFormatter())
        func nameColor(_ s: NSAttributedString) -> NSColor? {
            s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        }
        // Monochrome has no severity color at all, so the cue must be the label tier
        // and the weight — not the ink.
        XCTAssertEqual(nameColor(hot), .labelColor)
        XCTAssertEqual(nameColor(calm), .secondaryLabelColor)
        XCTAssertEqual(hot.string, "Weekly · Fable — 98%")
        XCTAssertEqual(calm.string, "Weekly · Opus — 41%")
    }

    func testRowDropsTheResetItSharesWithThePool() {
        let w = UsageWindow(id: "fable", title: "Weekly · Fable", utilization: 98,
                            windowMinutes: 10080, resetsAt: weekReset)
        // Same instant, and the same instant plus server jitter, are both "the pool's".
        XCTAssertNil(AppDelegate.capRowResetText(w, poolResetsAt: weekReset,
                                                 formatter: DateFormatter()))
        XCTAssertNil(AppDelegate.capRowResetText(w, poolResetsAt: weekReset.addingTimeInterval(26),
                                                 formatter: DateFormatter()))
    }

    func testRowKeepsAResetThatGenuinelyDiffers() {
        let w = UsageWindow(id: "fable", title: "Weekly · Fable", utilization: 98,
                            windowMinutes: 10080, resetsAt: weekReset.addingTimeInterval(86_400))
        XCTAssertNotNil(AppDelegate.capRowResetText(w, poolResetsAt: weekReset,
                                                    formatter: DateFormatter()))
        // A cap with no reset of its own says nothing rather than guessing the pool's.
        let noReset = UsageWindow(id: "x", title: "Weekly · X", utilization: 98,
                                  windowMinutes: 10080, resetsAt: nil)
        XCTAssertNil(AppDelegate.capRowResetText(noReset, poolResetsAt: weekReset,
                                                 formatter: DateFormatter()))
    }

    // MARK: - The collapsed strip

    func testStripNamesOneCapAndCountsTheRest() {
        let s = snap(82, [cap("Fable", 98), cap("Opus", 41), cap("Sonnet", 12)])
        let line = AppDelegate.claudeStripSubLine(s, resetsAt: nil, formatter: DateFormatter())
        XCTAssertEqual(line, "Fable 98% \u{00B7} +2 caps")
    }

    func testStripSurvivesAMissingFiveHourReset() {
        // The old line was built entirely inside `if let fiveResetsAt`, so a missing
        // session reset took the caps down with it. They come from limits[], not
        // from the session window.
        let s = snap(82, [cap("Fable", 98)])
        XCTAssertEqual(AppDelegate.claudeStripSubLine(s, resetsAt: nil, formatter: DateFormatter()),
                       "Fable 98%")
    }

    func testStripDropsNamesWhenNothingIsNearTheWall() {
        let s = snap(82, [cap("Opus", 41), cap("Sonnet", 12)])
        XCTAssertEqual(AppDelegate.claudeStripSubLine(s, resetsAt: nil, formatter: DateFormatter()),
                       "2 caps")
    }

    // MARK: - The glyph

    /// The cue has to survive at the size it actually ships at, in EVERY mode —
    /// including the two whose palettes have no severity color, which is the
    /// whole reason it is opacity and not ink.
    func testCappedGlyphDiffersFromCalmAtRealSizeInEveryMode() {
        for mode in ColorMode.allCases {
            let calm = StatusRenderer.image(five: 15, week: 82, style: .concentric,
                                            mode: mode, height: StatusRenderer.barHeight,
                                            weekCapped: false)
            let capped = StatusRenderer.image(five: 15, week: 82, style: .concentric,
                                              mode: mode, height: StatusRenderer.barHeight,
                                              weekCapped: true)
            XCTAssertNotEqual(calm.tiffRepresentation, capped.tiffRepresentation,
                              "\(mode): the scoped-cap cue must be visible at 18 pt")
        }
    }

    func testGlyphIsUnchangedWhenNothingIsCapped() {
        // A calm account must not pay for this feature with a different glyph.
        let a = StatusRenderer.image(five: 15, week: 82, style: .concentric, mode: .brand)
        let b = StatusRenderer.image(five: 15, week: 82, style: .concentric, mode: .brand,
                                     weekCapped: false)
        XCTAssertEqual(a.tiffRepresentation, b.tiffRepresentation)
    }

    // MARK: - Truncation

    func testLongCapNameIsTruncatedInTheMiddle() {
        let long = "Claude Fable 5 Preview Extended Context 98%"
        let out = AppDelegate.middleTruncated(long, budget: AppDelegate.bindingCapBudget)
        XCTAssertTrue(AppDelegate.bindingCapFits(out), "truncation must actually fit the slot")
        XCTAssertTrue(out.contains("…"))
        XCTAssertTrue(out.hasSuffix("98%"), "the percentage must survive truncation")
    }

    func testCompactRelativeTime() {
        XCTAssertEqual(AppDelegate.compactRel(2 * 86_400), "2d")
        XCTAssertEqual(AppDelegate.compactRel(3 * 3_600), "3h")
        XCTAssertEqual(AppDelegate.compactRel(45 * 60), "45m")
        XCTAssertEqual(AppDelegate.compactRel(-10), "0m")
    }
}
