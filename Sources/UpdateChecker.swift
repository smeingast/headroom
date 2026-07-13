import Foundation
import Security

// In-app update mechanism (v0.11). The trust anchor is Apple's signature +
// notarization, not our plumbing, so the surface here stays small: check the
// GitHub Releases feed, and on an explicit user click stage/verify/swap a
// notarized Headroom.app and relaunch. Foundation + Security ONLY: no AppKit
// reaches this file (relaunch/terminate and open-URL are injected closures), so
// the whole flow is exercisable without a live app, and the swiftc app build and
// `swift test` both compile it. Design + codex review disposition live under
// design/update-mechanism/.

// MARK: - Pure logic

/// Everything decidable without touching the network, a process, or the disk:
/// version math, release-JSON decode, asset selection, archive-entry validation,
/// HTTP-status decisions, relauncher argv, and the signing requirement string.
/// Kept pure so the dangerous parts are unit-testable; the side-effecting methods
/// on `UpdateChecker` call into here for every actual decision.
enum UpdateLogic {

    // MARK: Versions

    /// Dotted-integer components of a version, `nil` if it does not parse. A
    /// leading `v` (the tag form) is dropped first; any non-integer component
    /// fails the whole parse, so garbage tags compare as NOT newer downstream
    /// (fail closed, never nag on a bad release).
    static func parseVersion(_ raw: String) -> [Int]? {
        var s = Substring(raw)
        if s.first == "v" { s = s.dropFirst() }
        guard !s.isEmpty else { return nil }
        var out: [Int] = []
        for part in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(part), n >= 0 else { return nil }
            out.append(n)
        }
        return out.isEmpty ? nil : out
    }

    /// Numeric (not lexical) compare with missing components read as 0, so
    /// 0.10 == 0.10.0 and 0.9 < 0.10. Returns -1 / 0 / 1.
    static func compareVersions(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// True iff `tag` names a strictly newer version than `current`. Either side
    /// unparseable → not newer (fail closed).
    static func isNewer(tag: String, than current: String) -> Bool {
        guard let t = parseVersion(tag), let c = parseVersion(current) else { return false }
        return compareVersions(t, c) > 0
    }

    /// The tag stripped of a leading `v`, for display ("v0.11" → "0.11").
    static func displayVersion(_ tag: String) -> String {
        tag.first == "v" ? String(tag.dropFirst()) : tag
    }

    /// The extracted bundle's version must equal the release tag AND be strictly
    /// newer than the running app (a stale/tampered "latest" pointer or an
    /// outright downgrade fails here even after a valid signature). The bundle id
    /// is already pinned by the signing requirement, so it is not rechecked.
    static func installedVersionAcceptable(bundleVersion: String, tag: String, running: String) -> Bool {
        guard let b = parseVersion(bundleVersion), let t = parseVersion(tag) else { return false }
        guard compareVersions(b, t) == 0 else { return false }
        return isNewer(tag: bundleVersion, than: running)
    }

    // MARK: Release feed

    /// The slice of the GitHub release JSON the updater reads. Sendable so a
    /// decoded release crosses the actor hop into the install task unchanged.
    struct Release: Decodable, Equatable, Sendable {
        let tagName: String
        let htmlURL: String
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    struct Asset: Decodable, Equatable, Sendable {
        let name: String
        let browserDownloadURL: String
        let size: Int
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }

    /// The one installable asset: named EXACTLY `Headroom-<tag>.zip` with an https
    /// download URL. No fuzzy matching, so a missing/misnamed/http asset yields nil
    /// and the UI falls back to the browser (still "update available").
    struct InstallAsset: Equatable, Sendable {
        let url: URL
        let size: Int
    }

    static func decodeRelease(from data: Data) -> Release? {
        try? JSONDecoder().decode(Release.self, from: data)
    }

    static func installableAsset(for release: Release) -> InstallAsset? {
        let expected = "Headroom-\(release.tagName).zip"
        guard let asset = release.assets.first(where: { $0.name == expected }),
              let url = URL(string: asset.browserDownloadURL),
              url.scheme?.lowercased() == "https"
        else { return nil }
        return InstallAsset(url: url, size: asset.size)
    }

    /// GitHub's rate-limit and error responses are just a failed check (state
    /// carries the error, the next auto attempt is a day away, manual retry always
    /// available). Only 200 proceeds to a decode.
    enum CheckDecision: Equatable { case proceed, failed }
    static func checkDecision(forStatus status: Int) -> CheckDecision {
        status == 200 ? .proceed : .failed
    }

    // MARK: Archive validation

    /// A zip-slip guard applied to the `zipinfo -1` entry list BEFORE ditto ever
    /// extracts: every path must be relative (no absolute, no `..` component) and
    /// live under a single top-level `Headroom.app/` root, with a sane entry cap.
    /// This is the codex CRITICAL #1 fix; ditto by itself would happily honor an
    /// escaping path.
    static let maxZipEntries = 10_000
    static func zipEntriesValid(_ entries: [String]) -> Bool {
        let cleaned = entries.filter { !$0.isEmpty }
        guard !cleaned.isEmpty, cleaned.count <= maxZipEntries else { return false }
        var roots = Set<String>()
        for entry in cleaned {
            if entry.hasPrefix("/") { return false }
            let comps = entry.split(separator: "/", omittingEmptySubsequences: true)
            if comps.contains("..") { return false }
            guard let first = comps.first else { return false }
            roots.insert(String(first))
        }
        return roots == ["Headroom.app"]
    }

    // MARK: Relaunch

    /// The relauncher waits for the old pid to die (so the single-instance guard in
    /// main.swift admits the new instance), then opens the new bundle. pid and path
    /// are passed as POSITIONAL argv ($1 / $2), NEVER interpolated into the -c
    /// string: a bundle path can carry quotes, spaces, or `$(...)` (codex MAJOR #5).
    static let relauncherScript =
        #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open "$2""#

    static func relauncherArguments(pid: Int32, bundlePath: String) -> [String] {
        // argv[0] after -c becomes $0 ("relaunch"), then $1 = pid, $2 = path.
        ["-c", relauncherScript, "relaunch", String(pid), bundlePath]
    }

    // MARK: Signing requirement

    /// The Developer ID requirement the on-disk running bundle AND every candidate
    /// update must satisfy: Apple-issued Developer ID Application cert, Stefan's
    /// team, our bundle id. The identifier clause also makes a repackaged foreign
    /// bundle fail. This string is fed verbatim to SecRequirementCreateWithString,
    /// so it MUST stay comment-free and single-line (an inline comment changes the
    /// compiled requirement).
    static let developerIDRequirement =
        "anchor apple generic and identifier \"eu.smeingast.claude-menubar-usage\" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"X69YW5X9BW\""
}

// MARK: - State machine + side effects

/// Owns the updater's single linear state and the network/process/disk methods
/// that drive it. @MainActor: every state mutation and `onChange` fan-out happens
/// on the main actor, while the blocking work (download, zipinfo/ditto/spctl,
/// signature check, the swap) runs off it and hops back only to publish state.
@MainActor
final class UpdateChecker {

    enum State {
        case idle(lastCheck: Date?)
        case checking
        case upToDate
        case available(UpdateLogic.Release)
        case downloading(UpdateLogic.Release)
        case installing(UpdateLogic.Release)
        case failed(message: String, release: UpdateLogic.Release?)
    }

    /// In-app install vs browser fallback. `canInstall` is the on-disk static
    /// validation of the running bundle against the Developer ID requirement plus
    /// the path refusals; `canonicalBundleURL` is the symlink-resolved bundle the
    /// swap targets.
    struct Eligibility {
        var canInstall: Bool
        var reason: String?
        var canonicalBundleURL: URL
    }

    // Own UserDefaults keys, fully separate from the usage-fetch gates (codex #15).
    static let autoCheckDefaultsKey = "autoCheckUpdates"
    static let lastCheckDefaultsKey = "lastUpdateCheck"

    /// Auto-check preference, default ON (an unset key reads true).
    static var autoCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoCheckDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckDefaultsKey) }
    }

    private(set) var state: State
    /// Fans state to both surfaces (AppDelegate menu item + Settings About tab),
    /// mirroring SettingsHooks.
    var onChange: (() -> Void)?

    private let currentVersion: String
    private let terminate: () -> Void
    private let openURL: (URL) -> Void
    private let eligibility: Eligibility

    // ~100 MB ceiling, checked against both the declared asset size and the bytes
    // actually written: a runaway or wrong asset never fills the disk.
    nonisolated private static let maxDownloadBytes = 100 * 1024 * 1024

    private static let releaseAPIURL =
        URL(string: "https://api.github.com/repos/smeingast/headroom/releases/latest")!

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    init(currentVersion: String = UpdateChecker.currentBundleShortVersion(),
         terminate: @escaping () -> Void,
         openURL: @escaping (URL) -> Void) {
        self.currentVersion = currentVersion
        self.terminate = terminate
        self.openURL = openURL
        self.eligibility = UpdateChecker.computeEligibility(bundleURL: Bundle.main.bundleURL)
        self.state = .idle(lastCheck: UserDefaults.standard.object(forKey: UpdateChecker.lastCheckDefaultsKey) as? Date)
    }

    // MARK: Checking

    private var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    /// The automatic, passive check: a no-op unless the preference is on and the
    /// updater's own last-check timestamp is over 24 h old. Called from the 5-min
    /// usage timer and once shortly after launch; it never touches the usage gates.
    func triggerAutoCheck() {
        guard UpdateChecker.autoCheckEnabled else { return }
        if let last = lastCheckDate, Date().timeIntervalSince(last) < 24 * 3600 { return }
        checkNow(userInitiated: false)
    }

    /// Fetch the latest release and resolve to upToDate / available / failed.
    /// Coalesces if a check or install is already underway. Automatic checks fail
    /// QUIETLY: a Mac that wakes offline must not pin "Update Failed" into the
    /// dropdown for a day, and a transient error must not discard an update the
    /// user was already shown — only a user-initiated check surfaces failure.
    func checkNow(userInitiated: Bool = true) {
        guard !isBusy else { return }
        let prior = state
        state = .checking
        onChange?()
        // Record the attempt up front so the 24 h auto gate advances even on a
        // failure (the next automatic attempt is a day away; manual retry stands).
        UserDefaults.standard.set(Date(), forKey: UpdateChecker.lastCheckDefaultsKey)

        let session = self.session
        let current = self.currentVersion
        Task {
            var req = URLRequest(url: UpdateChecker.releaseAPIURL)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("Headroom", forHTTPHeaderField: "User-Agent")   // GitHub rejects UA-less API calls
            var resolved: State?
            var failure = ""
            do {
                let (data, resp) = try await session.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                switch UpdateLogic.checkDecision(forStatus: status) {
                case .failed:
                    failure = "Could not check for updates (HTTP \(status))."
                case .proceed:
                    if let release = UpdateLogic.decodeRelease(from: data) {
                        resolved = UpdateLogic.isNewer(tag: release.tagName, than: current)
                            ? .available(release) : .upToDate
                    } else {
                        failure = "Could not read the update information."
                    }
                }
            } catch {
                failure = "Could not reach GitHub to check for updates."
            }
            if let resolved {
                self.state = resolved
            } else if userInitiated {
                self.state = .failed(message: failure, release: nil)
            } else if case .available = prior {
                self.state = prior
            } else {
                self.state = .idle(lastCheck: self.lastCheckDate)
            }
            self.onChange?()
        }
    }

    // MARK: Installing

    /// Download, verify, and swap the update, then relaunch. Only reachable from an
    /// explicit user click (a menu-bar app that restarts itself unprompted is
    /// rude). Ineligible or browser-only assets divert to the release page.
    func install() {
        guard case .available(let release) = state else { return }
        guard eligibility.canInstall else { openReleasePage(); return }
        guard let asset = UpdateLogic.installableAsset(for: release) else { openReleasePage(); return }

        let session = self.session
        let running = self.currentVersion
        let bundleURL = eligibility.canonicalBundleURL
        let terminate = self.terminate

        state = .downloading(release)
        onChange?()
        Task {
            do {
                let staged = try await UpdateChecker.downloadPhase(
                    asset: asset, session: session, destinationParent: bundleURL.deletingLastPathComponent())
                self.state = .installing(release)
                self.onChange?()
                let installedPath = try await Task.detached(priority: .userInitiated) {
                    try UpdateChecker.installPhase(
                        zipURL: staged.zipURL, stagingDir: staged.stagingDir,
                        release: release, running: running, bundleURL: bundleURL)
                }.value
                // Spawn the detached relauncher, then terminate: it waits for this
                // pid to die before opening the freshly-installed bundle.
                UpdateChecker.spawnRelauncher(
                    pid: ProcessInfo.processInfo.processIdentifier, bundlePath: installedPath)
                terminate()
            } catch let e as InstallError {
                self.state = .failed(message: e.message, release: release)
                self.onChange?()
            } catch {
                self.state = .failed(message: "The update could not be installed.", release: release)
                self.onChange?()
            }
        }
    }

    /// Open the known release's page in the browser (the fallback for ineligible
    /// builds, browser-only assets, and a failure that still knows its release).
    func openReleasePage() {
        let release: UpdateLogic.Release?
        switch state {
        case .available(let r), .downloading(let r), .installing(let r): release = r
        case .failed(_, let r): release = r
        default: release = nil
        }
        guard let release, let url = URL(string: release.htmlURL) else { return }
        openURL(url)
    }

    /// The About tab's single stateful button dispatches here so the decision
    /// (check / install / view release) lives in one place.
    func performAboutAction() {
        switch state {
        case .idle, .upToDate, .failed:
            checkNow()
        case .available:
            eligibility.canInstall ? install() : openReleasePage()
        case .checking, .downloading, .installing:
            break
        }
    }

    // MARK: Presentation

    var lastCheckDate: Date? {
        UserDefaults.standard.object(forKey: UpdateChecker.lastCheckDefaultsKey) as? Date
    }

    /// The dropdown row title, or nil when the row should stay hidden (idle /
    /// checking / up to date). Surfaces downloading and failed states too, so a
    /// menu-bar user can rediscover them (codex #16).
    func menuTitle() -> String? {
        switch state {
        case .available(let r): return "Update Available: Headroom \(UpdateLogic.displayVersion(r.tagName))…"
        case .downloading:      return "Downloading Update…"
        case .installing:       return "Installing Update…"
        case .failed:           return "Update Failed…"
        default:                return nil
        }
    }

    func aboutStatusText() -> String {
        switch state {
        case .idle(let last):
            guard let last else { return "" }
            return "Last checked: \(UpdateChecker.relativeFormatter.localizedString(for: last, relativeTo: Date()))"
        case .checking:          return "Checking…"
        case .upToDate:          return "You're up to date."
        case .available(let r):  return "Headroom \(UpdateLogic.displayVersion(r.tagName)) is available."
        case .downloading:       return "Downloading…"
        case .installing:        return "Installing…"
        case .failed(let m, _):  return m
        }
    }

    func aboutButtonTitle() -> String {
        switch state {
        case .idle, .upToDate:  return "Check for Updates…"
        case .checking:         return "Checking…"
        case .available:        return eligibility.canInstall ? "Install and Relaunch" : "View Release…"
        case .downloading:      return "Downloading…"
        case .installing:       return "Installing…"
        case .failed:           return "Retry Update"
        }
    }

    func aboutButtonEnabled() -> Bool {
        switch state {
        case .checking, .downloading, .installing: return false
        default: return true
        }
    }

    // MARK: - Side-effecting statics (off the main actor)

    /// A failure with a user-facing message. Kept minimal and Sendable so it
    /// crosses back from the detached install task to the main actor as-is.
    struct InstallError: Error { let message: String }

    private struct StagedDownload { let stagingDir: URL; let zipURL: URL }

    nonisolated static func currentBundleShortVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Stage a private directory ON THE DESTINATION'S VOLUME (so the final move is a
    /// same-volume rename, no APFS-layout assumption — codex #6) and download the
    /// asset into it, size-capped against the declared size and the bytes written.
    nonisolated private static func downloadPhase(asset: UpdateLogic.InstallAsset,
                                                  session: URLSession,
                                                  destinationParent: URL) async throws -> StagedDownload {
        guard asset.size <= maxDownloadBytes else {
            throw InstallError(message: "The update is unexpectedly large.")
        }
        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: destinationParent, create: true)

        var req = URLRequest(url: asset.url)
        req.setValue("Headroom", forHTTPHeaderField: "User-Agent")
        let (tmpURL, resp) = try await session.download(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            try? fm.removeItem(at: staging)
            throw InstallError(message: "The update download failed (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)).")
        }
        // The async download's temp file is deleted when this call returns, so move
        // it into the staging dir immediately.
        let zipURL = staging.appendingPathComponent("Headroom.zip")
        do {
            try fm.moveItem(at: tmpURL, to: zipURL)
        } catch {
            try? fm.removeItem(at: staging)
            throw InstallError(message: "The update could not be saved.")
        }
        let bytes = (try? fm.attributesOfItem(atPath: zipURL.path)[.size] as? Int) ?? nil
        if let bytes, bytes > maxDownloadBytes {
            try? fm.removeItem(at: staging)
            throw InstallError(message: "The update is unexpectedly large.")
        }
        return StagedDownload(stagingDir: staging, zipURL: zipURL)
    }

    /// Steps 3-8 of the install flow, all blocking (Process, Security, file ops),
    /// so it runs in a detached task. Returns the installed bundle path on success.
    /// Internal (not private) so tools/update_probe.swift can exercise the real
    /// preflight/verify/swap chain against a scratch bundle; `swift test` still
    /// leaves it alone (it launches processes).
    nonisolated static func installPhase(zipURL: URL, stagingDir: URL,
                                                 release: UpdateLogic.Release, running: String,
                                                 bundleURL: URL) throws -> String {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: stagingDir) }

        // 3. Preflight the archive (zip-slip guard) BEFORE extracting anything.
        let (zStatus, zOut) = runProcess("/usr/bin/zipinfo", ["-1", zipURL.path])
        guard zStatus == 0 else { throw InstallError(message: "The update archive could not be read.") }
        let entries = zOut.split(separator: "\n").map(String.init)
        guard UpdateLogic.zipEntriesValid(entries) else {
            throw InstallError(message: "The update archive failed its safety check.")
        }

        // 4. Extract with ditto (the exact inverse of the release packing step) into
        //    a fresh empty subdir.
        let extractDir = stagingDir.appendingPathComponent("extract", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let (dStatus, _) = runProcess("/usr/bin/ditto", ["-x", "-k", zipURL.path, extractDir.path])
        guard dStatus == 0 else { throw InstallError(message: "The update could not be unpacked.") }
        let extractedApp = extractDir.appendingPathComponent("Headroom.app", isDirectory: true)
        guard fm.fileExists(atPath: extractedApp.path) else {
            throw InstallError(message: "The update did not contain Headroom.")
        }

        // 5. Content trust: the Developer ID signature (HTTPS is only transport
        //    trust — a compromised GitHub account cannot ship an installable update
        //    without Stefan's signing key).
        if let err = codeSignatureError(at: extractedApp) { throw InstallError(message: err) }

        // 6. Gatekeeper assessment (notarization / revocation) — the same authority
        //    build.sh treats as authoritative. Only AFTER both checks pass do we
        //    strip quarantine (stripping earlier would bypass Gatekeeper — codex #3).
        let (sStatus, _) = runProcess("/usr/sbin/spctl", ["--assess", "--type", "execute", extractedApp.path])
        guard sStatus == 0 else { throw InstallError(message: "Gatekeeper rejected the update.") }
        _ = runProcess("/usr/bin/xattr", ["-dr", "com.apple.quarantine", extractedApp.path])

        // 7. Identity cross-check: version must equal the tag AND beat the running one.
        guard let bundleVersion = bundleShortVersion(at: extractedApp) else {
            throw InstallError(message: "The update's version could not be read.")
        }
        guard UpdateLogic.installedVersionAcceptable(bundleVersion: bundleVersion,
                                                     tag: release.tagName, running: running) else {
            throw InstallError(message: "The update's version did not match the release.")
        }

        // 8. Re-check eligibility (the on-disk bundle may have changed since launch),
        //    then swap with a deterministic rename-aside rollback.
        let elig = computeEligibility(bundleURL: bundleURL)
        guard elig.canInstall else {
            throw InstallError(message: elig.reason ?? "This copy of Headroom cannot update itself.")
        }
        try swap(newApp: extractedApp, into: elig.canonicalBundleURL)
        return elig.canonicalBundleURL.path
    }

    /// Rename the current bundle aside within its parent, move the verified bundle
    /// into place, restore the aside copy on failure, and only trash it on success
    /// (a deterministic rollback, not "move to Trash and hope" — codex #8).
    nonisolated private static func swap(newApp: URL, into bundleURL: URL) throws {
        let fm = FileManager.default
        let parent = bundleURL.deletingLastPathComponent()
        let pid = ProcessInfo.processInfo.processIdentifier
        let aside = parent.appendingPathComponent("Headroom.app.replaced-\(pid)")
        try? fm.removeItem(at: aside)   // clear the aside of an earlier retry in this same run

        try fm.moveItem(at: bundleURL, to: aside)
        do {
            try fm.moveItem(at: newApp, to: bundleURL)
        } catch {
            try? fm.moveItem(at: aside, to: bundleURL)   // restore
            throw InstallError(message: "The update could not replace the running app.")
        }
        // Sweep ALL asides, ours and any a prior crashed attempt left behind (the
        // pid suffix never collides across runs, so they would linger forever).
        // Trash keeps a user-visible rollback; plain-delete if the Trash refuses.
        let siblings = (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [aside]
        for url in siblings where url.lastPathComponent.hasPrefix("Headroom.app.replaced-") {
            if (try? fm.trashItem(at: url, resultingItemURL: nil)) == nil {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// The detached relauncher: /bin/sh with pid and path as positional argv.
    nonisolated private static func spawnRelauncher(pid: Int32, bundlePath: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = UpdateLogic.relauncherArguments(pid: pid, bundlePath: bundlePath)
        try? proc.run()   // do NOT wait: we terminate immediately after
    }

    // MARK: Eligibility + signature

    /// Whether the ON-DISK running bundle may install over itself: it must satisfy
    /// the Developer ID requirement (so dev/ad-hoc builds see the browser instead of
    /// clobbering themselves — codex #14) and sit in a writable, non-translocated,
    /// non-symlinked location. Computed at startup and re-checked before the swap.
    nonisolated static func computeEligibility(bundleURL: URL) -> Eligibility {
        let fm = FileManager.default
        let canonical = bundleURL.resolvingSymlinksInPath()

        // Read-only translocation mount: the app must move to /Applications first.
        if canonical.path.contains("/AppTranslocation/") {
            return Eligibility(canInstall: false,
                               reason: "Move Headroom to Applications, then check for updates.",
                               canonicalBundleURL: canonical)
        }
        // Only a bundle sitting in an Applications folder (system or per-user) may
        // replace itself. The signature gate below cannot tell an installed release
        // from the maintainer's dev build — build.sh signs with the same Developer
        // ID whenever the cert is present — and build/Headroom.app must never
        // clobber itself with a release.
        if canonical.deletingLastPathComponent().lastPathComponent != "Applications" {
            return Eligibility(canInstall: false,
                               reason: "Move Headroom to Applications to update in place.",
                               canonicalBundleURL: canonical)
        }
        // A symlinked bundle path or parent is refused rather than raced (codex #7:
        // a user who can write a symlink into /Applications owns the app anyway, so
        // full inode-pinning buys nothing; refusing keeps the swap honest).
        if isSymlink(bundleURL) || isSymlink(bundleURL.deletingLastPathComponent()) {
            return Eligibility(canInstall: false,
                               reason: "This copy of Headroom cannot update itself.",
                               canonicalBundleURL: canonical)
        }
        if !fm.isWritableFile(atPath: canonical.deletingLastPathComponent().path) {
            return Eligibility(canInstall: false,
                               reason: "Headroom's folder is not writable; download the update instead.",
                               canonicalBundleURL: canonical)
        }
        if codeSignatureError(at: canonical) != nil {
            return Eligibility(canInstall: false,
                               reason: "This is not a signed release build; download the update instead.",
                               canonicalBundleURL: canonical)
        }
        return Eligibility(canInstall: true, reason: nil, canonicalBundleURL: canonical)
    }

    nonisolated private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    /// Static validation against the Developer ID requirement, comment-free and
    /// compiled with SecRequirementCreateWithString, checked with strict + nested +
    /// all-architectures. Returns a user-facing message on failure, nil on success
    /// (codex #13). Notarization/revocation is a SEPARATE spctl gate at the call site.
    nonisolated static func codeSignatureError(at url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return "The signature of the update could not be read."
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(UpdateLogic.developerIDRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            return "The update requirement could not be compiled."
        }
        let flags = SecCSFlags(rawValue:
            kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "code signature invalid"
            return "The update is not a trusted Headroom build: \(detail)"
        }
        return nil
    }

    nonisolated private static func bundleShortVersion(at appURL: URL) -> String? {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    /// Run a helper and capture stdout. Reads the pipe to EOF before waiting so a
    /// large listing (zipinfo) cannot deadlock on a full pipe buffer.
    @discardableResult
    nonisolated private static func runProcess(_ launchPath: String, _ args: [String]) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        // Discard stderr via the null device, NOT an unread Pipe: a tool spewing
        // more than the pipe buffer to a pipe nobody drains would deadlock us.
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return (-1, "")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
