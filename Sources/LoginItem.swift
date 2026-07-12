import Foundation
import ServiceManagement

/// "Launch at Login" via the modern ServiceManagement API (macOS 13+).
///
/// `SMAppService.mainApp` registers the app itself with launchd and tracks the
/// bundle, so launch-at-login survives the app being moved and stays in sync with
/// the System Settings › Login Items toggle. The old approach hand-wrote a
/// LaunchAgent plist and inferred "enabled" from that file's mere existence —
/// which went stale the moment the user flipped the switch in System Settings.
enum LoginItem {
    private static var service: SMAppService { .mainApp }

    /// True only when launch-at-login is active right now — not merely registered
    /// but awaiting the user's approval in System Settings.
    static var isEnabled: Bool {
        service.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                guard service.status != .enabled else { return }
                try service.register()
            } else {
                // Unregister from ANY registered state, not just .enabled: a
                // registration stuck in .requiresApproval would otherwise survive
                // "off" as a pending System Settings entry while the UI reads off.
                guard service.status != .notRegistered else { return }
                try service.unregister()
            }
        } catch {
            NSLog("ClaudeUsage: login-item \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }

    /// On the very first launch, turn launch-at-login on once (the app's default).
    /// After that we respect whatever the user sets — here or in System Settings.
    static func enableOnFirstLaunchIfNeeded() {
        let key = "didApplyDefaultLoginItem"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        // Upgrades from pre-SMAppService builds carry no marker, and a user who
        // had deliberately turned launch-at-login OFF there left no plist either
        // (disable() deleted it) — indistinguishable from a fresh install by the
        // marker alone. Any pre-existing app preference identifies such an
        // upgrade, so respect the off state; users who had it ON were already
        // re-registered by migrateLegacyAgentIfNeeded. (A legacy user who never
        // touched any setting still gets the default — no signal to go on.)
        let preexisting = ["displayStyle", "colorMode", "historyRange", "graphMode", "showDockIcon"]
        guard !preexisting.contains(where: { defaults.object(forKey: $0) != nil }) else { return }
        setEnabled(true)
    }

    /// One-time upgrade from pre-SMAppService versions, which wrote their own
    /// LaunchAgent plist. If that file is present the user had launch-at-login on,
    /// so re-register under the modern API and delete the stale plist — otherwise
    /// launchd would keep a second, now-unmanaged copy starting at login.
    static func migrateLegacyAgentIfNeeded() {
        let legacy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/eu.smeingast.claude-menubar-usage.plist")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        setEnabled(true)                                 // preserve the user's "on" state
        try? FileManager.default.removeItem(at: legacy)  // drop the now-redundant plist
    }
}
