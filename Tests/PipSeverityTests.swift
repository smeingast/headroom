import XCTest
import AppKit
@testable import ClaudeUsageCore

// Amendment 5's complete severity -> color mapping. Since v0.10 (corner pip
// removed) the only consumers are the PANEL's banner and strip dots, which
// depend on exactly this table.
final class PipSeverityTests: XCTestCase {

    func testRedIsSystemRed() {
        // The only place red is allowed: a real >= 90 on that provider's 5-hour window.
        XCTAssertEqual(StatusRenderer.pipColor(.red), .systemRed)
    }

    func testAmberIsSystemOrange() {
        // watch / pace, and the attention states (Claude signed out, Claude
        // stale, Codex inferred-zero) all resolve to amber.
        XCTAssertEqual(StatusRenderer.pipColor(.amber), .systemOrange)
    }

    func testCalmIsTheProvidersOwnAccent() {
        XCTAssertTrue(StatusRenderer.pipColor(.calm(.claude)) === StatusRenderer.claudeCoral)
        XCTAssertTrue(StatusRenderer.pipColor(.calm(.codex)) === StatusRenderer.codexTeal)
    }

    func testMutedIsTertiaryLabel() {
        // Codex noData and aged-idle.
        XCTAssertEqual(StatusRenderer.pipColor(.muted), .tertiaryLabelColor)
    }

    func testHiddenDrawsNoPip() {
        XCTAssertNil(StatusRenderer.pipColor(.hidden))
    }
}
