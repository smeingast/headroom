import XCTest
import AppKit
@testable import ClaudeUsageCore

// The Settings window's popup rows come from the pure `SettingsUI.popupModel`,
// the SAME code the real NSPopUpButtons are built from (the predecessor of this
// file mirrored the private v0.9 menu builders, which could drift; the shared
// model cannot). Invariants: every row's raw round-trips through the enum,
// titles match the decoded case, exactly one row is selected, and the selected
// row tracks Settings — including the legacy "claude" -> Brand migration.
final class SettingsPopupModelTests: XCTestCase {

    private let key = "colorMode"
    private var saved: Any?

    override func setUp() { super.setUp(); saved = UserDefaults.standard.object(forKey: key) }
    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    func testRowsRoundTripAndTitlesAreConsistent() {
        for row in SettingsUI.popupModel(selected: Settings.colorMode) {
            let decoded = ColorMode(rawValue: row.raw)
            XCTAssertNotNil(decoded, "the change handler must be able to decode \(row.raw)")
            XCTAssertEqual(decoded!.title, row.title, "title must match the decoded case")
        }
        let brand = SettingsUI.popupModel(selected: Settings.colorMode)
            .first { $0.raw == "brand" }
        XCTAssertNotNil(brand)
        XCTAssertEqual(brand?.title, "Brand")
    }

    func testExactlyOneRowSelectedAndItTracksSettings() {
        for stored in ["brand", "thresholds", "monochrome", "heatmap", "accent"] {
            UserDefaults.standard.set(stored, forKey: key)
            let on = SettingsUI.popupModel(selected: Settings.colorMode).filter(\.selected)
            XCTAssertEqual(on.count, 1, "exactly one row selected for stored \(stored)")
            XCTAssertEqual(on.first?.raw, Settings.colorMode.rawValue)
        }
    }

    func testStoredClaudeSelectsTheBrandRow() {
        // The migration is visible through the popup: a legacy "claude" value
        // leaves the Brand row (and only it) selected.
        UserDefaults.standard.set("claude", forKey: key)
        let on = SettingsUI.popupModel(selected: Settings.colorMode).filter(\.selected)
        XCTAssertEqual(on.count, 1)
        XCTAssertEqual(on.first?.raw, "brand")
        XCTAssertEqual(on.first?.title, "Brand")
    }

    func testEveryChoiceEnumModelsCleanly() {
        // The window builds five popups; each enum must produce a decodable,
        // singly-selected model for every one of its cases.
        func check<T: SettingsChoice>(_ type: T.Type) {
            for c in T.allCases {
                let model = SettingsUI.popupModel(selected: c)
                XCTAssertEqual(model.count, T.allCases.count)
                XCTAssertEqual(model.filter(\.selected).count, 1)
                XCTAssertEqual(model.first(where: \.selected)?.raw, c.rawValue)
                for row in model { XCTAssertNotNil(T(rawValue: row.raw)) }
            }
        }
        check(DisplayStyle.self)
        check(ColorMode.self)
        check(BarShows.self)
        check(GraphsShown.self)
        check(ShowCodex.self)
    }

    func testAboutVersionLine() {
        XCTAssertEqual(SettingsUI.versionLine(short: "0.10", build: "123"),
                       "Version 0.10 (build 123)")
        XCTAssertEqual(SettingsUI.versionLine(short: "0.10", build: nil), "Version 0.10")
        XCTAssertEqual(SettingsUI.versionLine(short: "0.10", build: ""), "Version 0.10")
        XCTAssertEqual(SettingsUI.versionLine(short: nil, build: "123"), "Development build")
        XCTAssertEqual(SettingsUI.versionLine(short: "", build: nil), "Development build")
    }
}
