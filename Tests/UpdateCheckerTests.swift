import XCTest
import Security
@testable import ClaudeUsageCore

// The pure, dangerous-part-covering half of the updater (UpdateLogic): version
// math, release-JSON decode + exact asset selection, the zip-slip entry guard,
// HTTP-status decisions, relauncher argv construction, the signing-requirement
// string, and the downgrade/tag-mismatch guard. No network, no Process, no
// FileManager writes — everything here is a pure function or an in-memory
// SecRequirement compile. The side-effecting install steps stay out of `swift
// test` by design (design.md, codex #17).
final class UpdateCheckerTests: XCTestCase {

    // MARK: - Version parse / compare

    func testParseVersion() {
        XCTAssertEqual(UpdateLogic.parseVersion("v0.11"), [0, 11])
        XCTAssertEqual(UpdateLogic.parseVersion("0.10.1"), [0, 10, 1])
        XCTAssertEqual(UpdateLogic.parseVersion("1"), [1])
        XCTAssertEqual(UpdateLogic.parseVersion("0.10"), [0, 10])
        // Fail closed on anything that is not dotted integers.
        XCTAssertNil(UpdateLogic.parseVersion("garbage"))
        XCTAssertNil(UpdateLogic.parseVersion("1.2.beta"))
        XCTAssertNil(UpdateLogic.parseVersion("1..2"))   // empty component
        XCTAssertNil(UpdateLogic.parseVersion(""))
        XCTAssertNil(UpdateLogic.parseVersion("v"))
        XCTAssertNil(UpdateLogic.parseVersion("1.2.3-rc1"))
    }

    func testCompareVersionsNumericAndPadded() {
        // Missing components read as 0.
        XCTAssertEqual(UpdateLogic.compareVersions([0, 10], [0, 10, 0]), 0)
        XCTAssertEqual(UpdateLogic.compareVersions([0, 10, 0], [0, 10]), 0)
        // Numeric, not lexical: 9 < 10.
        XCTAssertEqual(UpdateLogic.compareVersions([0, 9], [0, 10]), -1)
        XCTAssertEqual(UpdateLogic.compareVersions([0, 10, 1], [0, 10]), 1)
    }

    func testIsNewerTable() {
        // (tag, running, expected newer?)
        let cases: [(String, String, Bool)] = [
            ("v0.11", "0.10.1", true),      // v-prefix on the tag
            ("0.10.1", "0.10", true),       // extra component beats padded 0
            ("0.10", "0.10.0", false),      // equal (padding)
            ("0.10.0", "0.10", false),      // equal (padding, other direction)
            ("0.9", "0.10", false),         // numeric: 0.9 < 0.10, never nag
            ("0.10", "0.9", true),          // numeric the other way
            ("v0.10", "0.10", false),       // equal despite v-prefix
            ("garbage", "0.10", false),     // unparseable tag → fail closed
            ("0.10.x", "0.10", false),      // unparseable component → fail closed
            ("", "0.10", false),            // empty tag → fail closed
            ("0.11", "garbage", false),     // unparseable running → fail closed
        ]
        for (tag, running, expected) in cases {
            XCTAssertEqual(UpdateLogic.isNewer(tag: tag, than: running), expected,
                           "isNewer(tag: \(tag), than: \(running))")
        }
    }

    func testDisplayVersionStripsV() {
        XCTAssertEqual(UpdateLogic.displayVersion("v0.11"), "0.11")
        XCTAssertEqual(UpdateLogic.displayVersion("0.11"), "0.11")
    }

    // MARK: - Release JSON decode + asset selection

    /// A trimmed but faithful `/releases/latest` response: the real shape (top-level
    /// `tag_name` / `html_url` / `assets[]`, each asset with `name` /
    /// `browser_download_url` / `size`) with the fields the updater ignores present
    /// too, so the decode is exercised against realistic noise.
    private func releaseJSON(tag: String = "v0.11", assets: [String]) -> Data {
        let assetsJSON = assets.joined(separator: ",\n")
        let s = """
        {
          "url": "https://api.github.com/repos/smeingast/headroom/releases/1",
          "html_url": "https://github.com/smeingast/headroom/releases/tag/\(tag)",
          "id": 1,
          "tag_name": "\(tag)",
          "name": "Headroom \(tag)",
          "draft": false,
          "prerelease": false,
          "created_at": "2026-07-13T09:00:00Z",
          "published_at": "2026-07-13T09:05:00Z",
          "assets": [
        \(assetsJSON)
          ],
          "body": "Release notes here."
        }
        """
        return Data(s.utf8)
    }

    private func asset(name: String, url: String, size: Int) -> String {
        """
          {
            "name": "\(name)",
            "content_type": "application/zip",
            "size": \(size),
            "browser_download_url": "\(url)"
          }
        """
    }

    func testDecodeReleaseAndExactAssetPresent() {
        let data = releaseJSON(assets: [
            asset(name: "Headroom-v0.11.zip",
                  url: "https://github.com/smeingast/headroom/releases/download/v0.11/Headroom-v0.11.zip",
                  size: 3_500_000),
            asset(name: "Source code (zip)",
                  url: "https://github.com/smeingast/headroom/archive/v0.11.zip", size: 900_000),
        ])
        let release = UpdateLogic.decodeRelease(from: data)
        XCTAssertNotNil(release)
        XCTAssertEqual(release?.tagName, "v0.11")
        XCTAssertEqual(release?.htmlURL, "https://github.com/smeingast/headroom/releases/tag/v0.11")
        XCTAssertEqual(release?.assets.count, 2)

        let picked = UpdateLogic.installableAsset(for: release!)
        XCTAssertEqual(picked?.url.absoluteString,
                       "https://github.com/smeingast/headroom/releases/download/v0.11/Headroom-v0.11.zip")
        XCTAssertEqual(picked?.size, 3_500_000)
    }

    func testAssetSelectionMisnamedIsBrowserOnly() {
        // Present but not exactly Headroom-<tag>.zip → no in-app install.
        let data = releaseJSON(assets: [
            asset(name: "Headroom.zip",
                  url: "https://github.com/smeingast/headroom/releases/download/v0.11/Headroom.zip",
                  size: 3_500_000),
        ])
        let release = UpdateLogic.decodeRelease(from: data)!
        XCTAssertNil(UpdateLogic.installableAsset(for: release))
    }

    func testAssetSelectionMissingIsBrowserOnly() {
        let data = releaseJSON(assets: [
            asset(name: "Source code (zip)",
                  url: "https://github.com/smeingast/headroom/archive/v0.11.zip", size: 900_000),
        ])
        let release = UpdateLogic.decodeRelease(from: data)!
        XCTAssertNil(UpdateLogic.installableAsset(for: release))
    }

    func testAssetSelectionNonHTTPSIsBrowserOnly() {
        // Correct name, but an http (not https) URL must not be installed in-app.
        let data = releaseJSON(assets: [
            asset(name: "Headroom-v0.11.zip",
                  url: "http://github.com/smeingast/headroom/releases/download/v0.11/Headroom-v0.11.zip",
                  size: 3_500_000),
        ])
        let release = UpdateLogic.decodeRelease(from: data)!
        XCTAssertNil(UpdateLogic.installableAsset(for: release))
    }

    func testDecodeGarbageJSONReturnsNil() {
        XCTAssertNil(UpdateLogic.decodeRelease(from: Data("{ not json".utf8)))
        XCTAssertNil(UpdateLogic.decodeRelease(from: Data("{}".utf8)))   // missing required keys
    }

    // MARK: - Zip entry-list validation (zip-slip guard)

    private let cleanEntries = [
        "Headroom.app/",
        "Headroom.app/Contents/",
        "Headroom.app/Contents/Info.plist",
        "Headroom.app/Contents/MacOS/",
        "Headroom.app/Contents/MacOS/ClaudeUsage",
        "Headroom.app/Contents/_CodeSignature/CodeResources",
    ]

    func testZipCleanListAccepts() {
        XCTAssertTrue(UpdateLogic.zipEntriesValid(cleanEntries))
    }

    func testZipRejectsAbsolutePath() {
        XCTAssertFalse(UpdateLogic.zipEntriesValid(cleanEntries + ["/etc/passwd"]))
    }

    func testZipRejectsDotDot() {
        XCTAssertFalse(UpdateLogic.zipEntriesValid(cleanEntries + ["Headroom.app/../evil"]))
        XCTAssertFalse(UpdateLogic.zipEntriesValid(["../evil"]))
    }

    func testZipRejectsSecondTopLevel() {
        XCTAssertFalse(UpdateLogic.zipEntriesValid(cleanEntries + ["Other.app/run"]))
        XCTAssertFalse(UpdateLogic.zipEntriesValid(["Foo.app/x"]))   // wrong single root
    }

    func testZipRejectsEmptyList() {
        XCTAssertFalse(UpdateLogic.zipEntriesValid([]))
        XCTAssertFalse(UpdateLogic.zipEntriesValid(["", ""]))   // only blank entries
    }

    func testZipEntryCap() {
        let atCap = (0..<10_000).map { "Headroom.app/f\($0)" }
        XCTAssertTrue(UpdateLogic.zipEntriesValid(atCap))
        let overCap = (0..<10_001).map { "Headroom.app/f\($0)" }
        XCTAssertFalse(UpdateLogic.zipEntriesValid(overCap))
    }

    // MARK: - HTTP status decision

    func testCheckDecisionByStatus() {
        XCTAssertEqual(UpdateLogic.checkDecision(forStatus: 200), .proceed)
        for status in [301, 304, 401, 403, 404, 429, 500, 502, 503] {
            XCTAssertEqual(UpdateLogic.checkDecision(forStatus: status), .failed,
                           "HTTP \(status) should be a failed check")
        }
    }

    // MARK: - Relauncher argv

    func testRelauncherArgvKeepsHostilePathOutOfScript() {
        // A path with a quote, spaces, and a command substitution: it must land as a
        // positional argv element, NEVER be spliced into the -c script.
        let path = "/tmp/We\"ird $(rm -rf ~) '/Headroom.app"
        let args = UpdateLogic.relauncherArguments(pid: 4242, bundlePath: path)

        XCTAssertEqual(args[0], "-c")
        XCTAssertEqual(args[1], UpdateLogic.relauncherScript)
        XCTAssertEqual(args[2], "relaunch")   // $0
        XCTAssertEqual(args[3], "4242")       // $1
        XCTAssertEqual(args[4], path)         // $2, verbatim
        XCTAssertEqual(args.last, path)

        // The script references only $1 / $2; neither pid nor path (nor its payload)
        // is interpolated into it.
        XCTAssertFalse(UpdateLogic.relauncherScript.contains(path))
        XCTAssertFalse(UpdateLogic.relauncherScript.contains("4242"))
        XCTAssertFalse(UpdateLogic.relauncherScript.contains("rm -rf"))
        XCTAssertTrue(UpdateLogic.relauncherScript.contains("\"$1\""))
        XCTAssertTrue(UpdateLogic.relauncherScript.contains("\"$2\""))
    }

    // MARK: - Signing requirement string

    func testRequirementCompilesAndPinsTeamAndBundle() {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            UpdateLogic.developerIDRequirement as CFString, [], &requirement)
        XCTAssertEqual(status, errSecSuccess, "requirement string must compile")
        XCTAssertNotNil(requirement)

        // Substring pins rather than brittle full-string equality (codex #18).
        XCTAssertTrue(UpdateLogic.developerIDRequirement.contains("X69YW5X9BW"))
        XCTAssertTrue(UpdateLogic.developerIDRequirement.contains("eu.smeingast.claude-menubar-usage"))
        XCTAssertTrue(UpdateLogic.developerIDRequirement.contains("anchor apple generic"))
        // Comment-free: an inline comment would change the compiled requirement.
        XCTAssertFalse(UpdateLogic.developerIDRequirement.contains("/*"))
        XCTAssertFalse(UpdateLogic.developerIDRequirement.contains("//"))
    }

    // MARK: - Downgrade / tag-mismatch guard

    func testInstalledVersionAcceptableTable() {
        // (bundleVersion, tag, running, expected)
        let cases: [(String, String, String, Bool)] = [
            ("0.11", "v0.11", "0.10.1", true),     // matches tag, beats running
            ("0.11.0", "v0.11", "0.10.1", true),   // 0.11.0 == 0.11
            ("0.11", "v0.11", "0.11", false),      // not newer than running
            ("0.10", "v0.11", "0.10", false),      // bundle != tag (tampered pointer)
            ("0.11", "v0.11", "0.12", false),      // downgrade: running is newer
            ("garbage", "v0.11", "0.10", false),   // bundle unparseable → fail closed
            ("0.11", "garbage", "0.10", false),    // tag unparseable → fail closed
        ]
        for (bundle, tag, running, expected) in cases {
            XCTAssertEqual(
                UpdateLogic.installedVersionAcceptable(bundleVersion: bundle, tag: tag, running: running),
                expected,
                "installedVersionAcceptable(bundle: \(bundle), tag: \(tag), running: \(running))")
        }
    }
}
