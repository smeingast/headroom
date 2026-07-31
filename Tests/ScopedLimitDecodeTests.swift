import XCTest
@testable import ClaudeUsageCore

/// Decoding the usage endpoint's `limits[]` array. The array's shape is observed
/// from live payloads, not documented, so the decoder's job is to take what it
/// recognises and drop the rest without ever failing the whole response.
final class ScopedLimitDecodeTests: XCTestCase {

    private func decode(_ json: String) -> UsageSnapshot? {
        UsageClient.decodeUsage(Data(json.utf8), fetchedAt: utcDate(2026, 1, 2, 13, 40))
    }

    /// The payload observed on a live Pro account, 2026-07-31: the pool at 82%,
    /// Fable at 98%, and every legacy per-model field null.
    private let live = """
    {"five_hour":{"utilization":15,"resets_at":"2026-07-31T12:30:00.565339+00:00"},
     "seven_day":{"utilization":82,"resets_at":"2026-08-02T00:59:59.565409+00:00"},
     "seven_day_opus":null,"seven_day_sonnet":null,"seven_day_omelette":null,
     "limits":[
       {"kind":"session","group":"session","percent":15,"severity":"normal","scope":null,"is_active":false},
       {"kind":"weekly_all","group":"weekly","percent":82,"severity":"warning","scope":null,"is_active":false},
       {"kind":"weekly_scoped","group":"weekly","percent":98,"severity":"critical",
        "scope":{"model":{"id":null,"display_name":"Fable"}},"is_active":true}]}
    """

    func testLivePayloadYieldsTheCapTheLegacyFieldsMiss() {
        let s = decode(live)
        XCTAssertEqual(s?.fiveHour?.utilization, 15)
        XCTAssertEqual(s?.sevenDay?.utilization, 82)
        XCTAssertEqual(s?.scoped.count, 1)
        XCTAssertEqual(s?.scoped.first?.modelName, "Fable")
        XCTAssertEqual(s?.scoped.first?.utilization, 98)
        XCTAssertEqual(s?.scoped.first?.severity, "critical")
        XCTAssertEqual(s?.scoped.first?.isActive, true)
    }

    func testOnlyWeeklyScopedEntriesBecomeCaps() {
        // A `weekly_all` entry inside limits[] must never render as a second
        // weekly row beside the pool it already describes.
        XCTAssertEqual(decode(live)?.scoped.map(\.modelName), ["Fable"])
    }

    func testTopLevelWindowsWinOverTheArray() {
        let json = """
        {"five_hour":{"utilization":15},"seven_day":{"utilization":82},
         "limits":[{"kind":"weekly_all","percent":99}]}
        """
        XCTAssertEqual(decode(json)?.sevenDay?.utilization, 82)
    }

    func testArrayStandsInForANullTopLevelWindow() {
        let json = """
        {"five_hour":null,"seven_day":null,
         "limits":[{"kind":"session","percent":15},{"kind":"weekly_all","percent":82}]}
        """
        XCTAssertEqual(decode(json)?.fiveHour?.utilization, 15)
        XCTAssertEqual(decode(json)?.sevenDay?.utilization, 82)
    }

    func testAllScopedEntriesUnusableFallsBackRatherThanShowingNothing() {
        // Entries exist but none can be read: that is a shape we failed to parse,
        // not the server saying there are no caps. Suppressing the legacy fields
        // there would silently take away a window the user can see today.
        let json = """
        {"seven_day":{"utilization":82},"seven_day_opus":{"utilization":41},
         "limits":[{"kind":"weekly_scoped","percent":98,"scope":{"model":{"display_name":null}}}]}
        """
        XCTAssertEqual(decode(json)?.scoped.map(\.modelName), ["Opus"])
    }

    func testAnEntryWeCannotDecodeAtAllAlsoCountsAsUnusable() {
        // A wrong-typed percent fails LimitDTO entirely, so the entry never
        // reaches the kind filter. Calling that "no scoped entries" would be a
        // claim about an array we only half-read.
        let json = """
        {"seven_day":{"utilization":82},"seven_day_opus":{"utilization":41},
         "limits":[{"kind":"weekly_scoped","percent":"bad","scope":{"model":{"display_name":"Fable"}}}]}
        """
        XCTAssertEqual(decode(json)?.scoped.map(\.modelName), ["Opus"])
    }

    func testAbsurdPercentageIsRenderedNotCrashedOn() {
        // Int(_:) traps past Int.max and these numbers come off the wire.
        let json = """
        {"limits":[{"kind":"weekly_scoped","percent":1e30,"scope":{"model":{"display_name":"Runaway"}}}]}
        """
        let s = decode(json)
        XCTAssertEqual(s?.scoped.count, 1)
        XCTAssertFalse(AppDelegate.percent(s?.scoped.first?.utilization).isEmpty)
        XCTAssertTrue(Severity.isCritical(s?.scoped.first?.utilization ?? 0))
    }

    func testOneMalformedEntryDoesNotCostTheResponse() {
        let json = """
        {"seven_day":{"utilization":82},
         "limits":[{"kind":"weekly_scoped","percent":"not a number","scope":{"model":{"display_name":"Broken"}}},
                   {"kind":"weekly_scoped","percent":98,"scope":{"model":{"display_name":"Fable"}}}]}
        """
        XCTAssertEqual(decode(json)?.scoped.map(\.modelName), ["Fable"])
        XCTAssertEqual(decode(json)?.sevenDay?.utilization, 82)
    }

    func testUnnamedOrNonFiniteScopesAreDropped() {
        let json = """
        {"limits":[{"kind":"weekly_scoped","percent":98,"scope":{"model":{"display_name":null}}},
                   {"kind":"weekly_scoped","percent":-5,"scope":{"model":{"display_name":"Negative"}}},
                   {"kind":"weekly_scoped","percent":12,"scope":null},
                   {"kind":"weekly_scoped","percent":40,"scope":{"model":{"display_name":"  "}}}]}
        """
        XCTAssertEqual(decode(json)?.scoped.count, 0)
    }

    func testUnknownKindsAreIgnoredNotFatal() {
        let json = """
        {"seven_day":{"utilization":82},
         "limits":[{"kind":"monthly_something_new","percent":50,"group":"future"},
                   {"kind":"weekly_scoped","percent":98,"scope":{"model":{"display_name":"Fable"}}}]}
        """
        XCTAssertEqual(decode(json)?.scoped.map(\.modelName), ["Fable"])
    }

    func testCapsComeBackWorstFirst() {
        let json = """
        {"limits":[{"kind":"weekly_scoped","percent":12,"scope":{"model":{"display_name":"Sonnet"}}},
                   {"kind":"weekly_scoped","percent":98,"scope":{"model":{"display_name":"Fable"}}},
                   {"kind":"weekly_scoped","percent":41,"scope":{"model":{"display_name":"Opus"}}}]}
        """
        XCTAssertEqual(decode(json)?.scoped.map(\.modelName), ["Fable", "Opus", "Sonnet"])
    }

    // MARK: - The legacy fallback

    func testLegacyFieldsCoverAnAccountWithoutTheArray() {
        // Including omelette, which is Fable's slot under its internal codename.
        let json = """
        {"seven_day":{"utilization":82},
         "seven_day_opus":{"utilization":41},"seven_day_sonnet":{"utilization":12},
         "seven_day_omelette":{"utilization":98}}
        """
        XCTAssertEqual(decode(json)?.scoped.map(\.modelName), ["Fable", "Opus", "Sonnet"])
        XCTAssertEqual(decode(json)?.scoped.first?.utilization, 98)
    }

    func testAnEmptyArrayMeansNoCapsRatherThanFallBack() {
        // Present-and-empty is the server saying "this account has no scoped caps".
        // Resurrecting the legacy fields there would invent caps it just denied.
        let json = """
        {"seven_day":{"utilization":82},"seven_day_opus":{"utilization":41},"limits":[]}
        """
        XCTAssertEqual(decode(json)?.scoped.count, 0)
    }

    func testAnArrayWithoutScopedEntriesAlsoMeansNoCaps() {
        // Same rule as the empty array: once limits[] exists it is the authority on
        // scoped caps, so the legacy fields do not get to contradict it.
        let json = """
        {"seven_day":{"utilization":82},"seven_day_opus":{"utilization":41},
         "limits":[{"kind":"session","percent":15},{"kind":"weekly_all","percent":82}]}
        """
        XCTAssertEqual(decode(json)?.scoped.count, 0)
    }
}
