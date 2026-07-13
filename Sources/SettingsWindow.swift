import AppKit

// The tabbed Settings window (v0.10). Every option that used to live as menu
// rows at the dropdown's tail moves here; the dropdown keeps only actions
// (Refresh Now, Settings…, About Headroom, Quit). Changes apply immediately
// (macOS convention, no OK/Cancel) and fan back into AppDelegate through
// `SettingsHooks`, so AppDelegate's render internals stay private.

/// The settings enums the window renders as popups. Retroactive conformances
/// below; the protocol exists so popup construction and its tests share ONE
/// pure model (codex review A5: a test mirroring private UI code goes stale).
protocol SettingsChoice: CaseIterable, RawRepresentable, Equatable where RawValue == String {
    var title: String { get }
}
extension DisplayStyle: SettingsChoice {}
extension ColorMode: SettingsChoice {}
extension BarShows: SettingsChoice {}
extension GraphsShown: SettingsChoice {}
extension ShowCodex: SettingsChoice {}

/// Pure view-models for the window, separated for testability.
enum SettingsUI {
    struct PopupItem: Equatable {
        var title: String
        var raw: String
        var selected: Bool
    }

    /// The popup rows for a choice setting: declaration order, rawValue as the
    /// stable identity, exactly one row selected (the current setting).
    static func popupModel<T: SettingsChoice>(selected: T) -> [PopupItem] {
        T.allCases.map { PopupItem(title: $0.title, raw: $0.rawValue, selected: $0 == selected) }
    }

    /// The About tab's version line from Info.plist values. The bare executable
    /// (swift test, swiftc without the bundle) has neither key; call that what
    /// it is rather than showing empty parentheses.
    static func versionLine(short: String?, build: String?) -> String {
        guard let short, !short.isEmpty else { return "Development build" }
        guard let build, !build.isEmpty else { return "Version \(short)" }
        return "Version \(short) (build \(build))"
    }
}

/// How settings changes fan back into the app. Kept as closures so the window
/// never sees AppDelegate's internals.
@MainActor
struct SettingsHooks {
    /// Display style / Bar Shows: the bar re-renders, the panel is untouched.
    var barChanged: () -> Void
    /// Color mode: bar plus the panel's repaint fan-out (rings, pills, dots).
    var colorChanged: () -> Void
    /// Show Codex / Graphs: bar now; panel row structure resolves on next open.
    var codexChanged: () -> Void
    /// Dock icon: re-apply the activation policy.
    var dockChanged: () -> Void
}

/// Escape closes the window. A titled window does not do this by itself; the
/// responder chain delivers Escape as `cancelOperation` (codex review A3).
private final class SettingsPanel: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// Keeps the window title tracking the selected tab (title propagation is not
/// automatic for status-item apps without a window-controller document setup).
private final class SettingsTabsViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        view.window?.title = tabViewItem?.label ?? "Settings"
    }
}

/// A tab pane wrapping a pre-built view. `preferredContentSize` drives the
/// toolbar-style tab-switch resize animation, so it is fixed at creation from
/// the constraint system's fitting size (codex review A4).
private final class SettingsPaneViewController: NSViewController {
    private let content: NSView
    init(title: String, content: NSView) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }
    override func loadView() {
        view = content
        preferredContentSize = content.fittingSize
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    enum Tab: String { case general, menuBar, codex, about }

    private let hooks: SettingsHooks
    private let codexRootPath: String
    private let updater: UpdateChecker
    private let tabs = SettingsTabsViewController()

    // All panes exist for the controller's lifetime; only the Codex pane's
    // MEMBERSHIP in the tab bar and the General pane's "Bar shows" row change
    // (resolved on every show(), same root-stat-only gate as the old settings
    // rows: under Show Codex = Off the tab must stay reachable, or Off would
    // hide its own undo path).
    private var generalItem: NSTabViewItem!
    private var menuBarItem: NSTabViewItem!
    private var codexItem: NSTabViewItem!
    private var aboutItem: NSTabViewItem!

    // Controls that need re-reading on show (state can change elsewhere:
    // System Settings for login, the strip's Lead button does not touch these
    // but a future surface might).
    private var loginCheckbox: NSButton!
    private var dockCheckbox: NSButton!
    private var stylePopup: NSPopUpButton!
    private var colorPopup: NSPopUpButton!
    private var showCodexPopup: NSPopUpButton!
    private var barShowsPopup: NSPopUpButton!
    private var graphsPopup: NSPopUpButton!

    // The General grid and its "Bar shows" rows (control + caption), so the
    // two-provider control can hide on a Claude-only machine (Stefan wants it
    // under General, not on the gated Codex tab).
    private var generalGrid: NSGridView!
    private static let barShowsRowIndices = [3, 4]

    // About-tab update controls, re-rendered from the checker's state on show and on
    // every onChange (the status label wraps, so its height can change the pane's
    // fitting size — recomputed like resolveCodexSurfaces does for General).
    private var updateStatusLabel: NSTextField!
    private var updateButton: NSButton!
    private var autoUpdateCheckbox: NSButton!

    private var centeredOnce = false

    init(hooks: SettingsHooks, codexRootPath: String, updater: UpdateChecker) {
        self.hooks = hooks
        self.codexRootPath = codexRootPath
        self.updater = updater

        let window = SettingsPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        super.init(window: window)

        tabs.tabStyle = .toolbar
        buildTabs()
        window.contentViewController = tabs
        window.title = tabs.tabViewItems[tabs.selectedTabViewItemIndex].label
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    /// Bring the window up on `tab` (nil keeps the last-selected tab), with
    /// control state and Codex-tab membership re-resolved.
    func show(tab: Tab?) {
        resolveCodexSurfaces()
        refreshControls()
        if let tab, let item = tabItem(for: tab), tabs.tabViewItems.contains(item) {
            tabs.selectedTabViewItemIndex = tabs.tabViewItems.firstIndex(of: item)!
        }
        window?.title = tabs.tabViewItems[tabs.selectedTabViewItemIndex].label
        if !centeredOnce { window?.center(); centeredOnce = true }
        // Accessory apps do not come forward on makeKey alone.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func tabItem(for tab: Tab) -> NSTabViewItem? {
        switch tab {
        case .general: return generalItem
        case .menuBar: return menuBarItem
        case .codex:   return codexItem
        case .about:   return aboutItem
        }
    }

    private func resolveCodexSurfaces() {
        let installed = FileManager.default.fileExists(atPath: codexRootPath)
        let present = tabs.tabViewItems.contains(codexItem)
        if installed && !present {
            // Keep the fixed order General / Menu Bar / Codex / About.
            tabs.insertTabViewItem(codexItem, at: 2)
        } else if !installed && present {
            tabs.removeTabViewItem(codexItem)   // AppKit reselects a neighbor
        }
        // "Bar shows" lives in General but is a two-provider control: same gate.
        for i in Self.barShowsRowIndices { generalGrid.row(at: i).isHidden = !installed }
        if let vc = generalItem.viewController {
            vc.preferredContentSize = vc.view.fittingSize
        }
    }

    private func refreshControls() {
        loginCheckbox.state = LoginItem.isEnabled ? .on : .off
        dockCheckbox.state = UserDefaults.standard.bool(forKey: "showDockIcon") ? .on : .off
        select(stylePopup, raw: Settings.style.rawValue)
        select(colorPopup, raw: Settings.colorMode.rawValue)
        select(showCodexPopup, raw: Settings.showCodex.rawValue)
        select(barShowsPopup, raw: Settings.barShows.rawValue)
        select(graphsPopup, raw: Settings.graphs.rawValue)
        refreshUpdateControls()
    }

    /// Re-render the About tab's update status, button, and auto-check box from the
    /// checker's current state. Called on show() and from AppDelegate on every
    /// onChange. The status label wraps, so recompute the About pane's
    /// preferredContentSize (fixed once at loadView) when its height may have moved.
    func refreshUpdateControls() {
        updateStatusLabel.stringValue = updater.aboutStatusText()
        updateButton.title = updater.aboutButtonTitle()
        updateButton.isEnabled = updater.aboutButtonEnabled()
        autoUpdateCheckbox.state = UpdateChecker.autoCheckEnabled ? .on : .off
        if let vc = aboutItem.viewController {
            vc.preferredContentSize = vc.view.fittingSize
        }
    }

    private func select(_ popup: NSPopUpButton, raw: String) {
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == raw }) {
            popup.select(item)
        }
    }

    // MARK: - Tab construction

    private func buildTabs() {
        generalItem = NSTabViewItem(viewController:
            SettingsPaneViewController(title: "General", content: buildGeneralPane()))
        generalItem.label = "General"
        generalItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")

        menuBarItem = NSTabViewItem(viewController:
            SettingsPaneViewController(title: "Menu Bar", content: buildMenuBarPane()))
        menuBarItem.label = "Menu Bar"
        menuBarItem.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "Menu Bar")

        codexItem = NSTabViewItem(viewController:
            SettingsPaneViewController(title: "Codex", content: buildCodexPane()))
        codexItem.label = "Codex"
        codexItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Codex")

        aboutItem = NSTabViewItem(viewController:
            SettingsPaneViewController(title: "About", content: buildAboutPane()))
        aboutItem.label = "About"
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About")

        tabs.addTabViewItem(generalItem)
        tabs.addTabViewItem(menuBarItem)
        tabs.addTabViewItem(codexItem)      // membership re-resolved on show()
        tabs.addTabViewItem(aboutItem)
    }

    private func buildGeneralPane() -> NSView {
        loginCheckbox = NSButton(checkboxWithTitle: "Start Headroom at login",
                                 target: self, action: #selector(loginToggled(_:)))
        dockCheckbox = NSButton(checkboxWithTitle: "Show Dock icon",
                                target: self, action: #selector(dockToggled(_:)))
        barShowsPopup = popup(model: SettingsUI.popupModel(selected: Settings.barShows),
                              action: #selector(barShowsChanged(_:)))
        // Row layout is load-bearing: barShowsRowIndices names the last two rows.
        let grid = formGrid(rows: [
            ("Startup:", loginCheckbox, nil),
            ("Dock:", dockCheckbox, "Headroom lives in the menu bar either way."),
            ("Bar shows:", barShowsPopup, "What the menu-bar readout draws."),
        ])
        generalGrid = grid
        return padded(grid, width: 420, verticalInset: 20)
    }

    private func buildMenuBarPane() -> NSView {
        stylePopup = popup(model: SettingsUI.popupModel(selected: Settings.style),
                           action: #selector(styleChanged(_:)))
        // The style popup carries the same live thumbnails the old submenu had.
        for item in stylePopup.itemArray {
            if let raw = item.representedObject as? String, let s = DisplayStyle(rawValue: raw) {
                item.image = StatusRenderer.previewImage(for: s)
            }
        }
        colorPopup = popup(model: SettingsUI.popupModel(selected: Settings.colorMode),
                           action: #selector(colorChanged(_:)))
        return form(rows: [
            ("Style:", stylePopup, nil),
            ("Color:", colorPopup, "Applies to the menu-bar readout and the panel."),
        ])
    }

    private func buildCodexPane() -> NSView {
        showCodexPopup = popup(model: SettingsUI.popupModel(selected: Settings.showCodex),
                               action: #selector(showCodexChanged(_:)))
        graphsPopup = popup(model: SettingsUI.popupModel(selected: Settings.graphs),
                            action: #selector(graphsChanged(_:)))
        return form(rows: [
            ("Show Codex:", showCodexPopup, "Auto shows Codex only while ~/.codex exists."),
            ("Graphs:", graphsPopup, "Which usage graphs the dropdown stacks."),
        ])
    }

    private func buildAboutPane() -> NSView {
        let info = Bundle.main.infoDictionary
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let name = NSTextField(labelWithString: "Headroom")
        name.font = .systemFont(ofSize: 20, weight: .semibold)

        let version = NSTextField(labelWithString: SettingsUI.versionLine(
            short: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String))
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor

        // Update status sits directly under the version line; it wraps so a long
        // error message stays inside the pane (refreshUpdateControls fills it in).
        updateStatusLabel = NSTextField(wrappingLabelWithString: "")
        updateStatusLabel.font = .systemFont(ofSize: 11)
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.alignment = .center
        updateStatusLabel.isSelectable = false
        updateStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        updateStatusLabel.widthAnchor.constraint(equalToConstant: 340).isActive = true

        let tagline = NSTextField(labelWithString: "Claude & Codex usage limits in your menu bar.")
        tagline.font = .systemFont(ofSize: 12)

        let link = NSButton(title: "github.com/smeingast/headroom",
                            target: self, action: #selector(openRepo(_:)))
        link.isBordered = false
        link.contentTintColor = .linkColor
        link.font = .systemFont(ofSize: 12)

        let license = NSTextField(labelWithString: "MIT License · © 2026 Stefan Meingast")
        license.font = .systemFont(ofSize: 11)
        license.textColor = .tertiaryLabelColor

        // One stateful button (Check → Install/View → Downloading/Installing →
        // Retry) plus the auto-check preference. Both driven by the checker.
        updateButton = NSButton(title: "Check for Updates…",
                                target: self, action: #selector(updateButtonClicked(_:)))
        updateButton.bezelStyle = .rounded
        autoUpdateCheckbox = NSButton(checkboxWithTitle: "Check for updates automatically",
                                      target: self, action: #selector(autoUpdateToggled(_:)))

        let stack = NSStackView(views: [icon, name, version, updateStatusLabel,
                                        tagline, link, license, updateButton, autoUpdateCheckbox])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(10, after: icon)
        stack.setCustomSpacing(2, after: name)
        stack.setCustomSpacing(4, after: version)
        stack.setCustomSpacing(12, after: updateStatusLabel)
        stack.setCustomSpacing(12, after: link)
        stack.setCustomSpacing(16, after: license)
        stack.setCustomSpacing(8, after: updateButton)
        // Seed the initial values here (aboutItem is not built yet, so the pane's
        // fitting size at loadView already reflects real text); refreshControls()
        // and onChange re-render and recompute the pane height from then on.
        updateStatusLabel.stringValue = updater.aboutStatusText()
        updateButton.title = updater.aboutButtonTitle()
        updateButton.isEnabled = updater.aboutButtonEnabled()
        autoUpdateCheckbox.state = UpdateChecker.autoCheckEnabled ? .on : .off
        return padded(stack, width: 420, verticalInset: 24)
    }

    @objc private func updateButtonClicked(_ sender: NSButton) {
        updater.performAboutAction()
    }

    @objc private func autoUpdateToggled(_ sender: NSButton) {
        UpdateChecker.autoCheckEnabled = (sender.state == .on)
    }

    // MARK: - Layout helpers

    /// One label-and-control row per entry, with an optional caption under the
    /// control; right-aligned labels, the standard preferences form.
    private func form(rows: [(label: String, control: NSView, caption: String?)]) -> NSView {
        padded(formGrid(rows: rows), width: 420, verticalInset: 20)
    }

    private func formGrid(rows: [(label: String, control: NSView, caption: String?)]) -> NSGridView {
        var gridRows: [[NSView]] = []
        for row in rows {
            let label = NSTextField(labelWithString: row.label)
            gridRows.append([label, row.control])
            if let caption = row.caption {
                let c = NSTextField(wrappingLabelWithString: caption)
                c.font = .systemFont(ofSize: 11)
                c.textColor = .secondaryLabelColor
                c.isSelectable = false
                gridRows.append([NSGridCell.emptyContentView, c])
            }
        }
        let grid = NSGridView(views: gridRows)
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        // Tighten each caption to its control.
        for (i, row) in gridRows.enumerated() where row[1] is NSTextField && i > 0 {
            if (row[1] as? NSTextField)?.font?.pointSize == 11 {
                grid.row(at: i).topPadding = -4
            }
        }
        return grid
    }

    /// Wrap `content` in a fixed-width container (all tabs share one width, so
    /// only the height animates on tab switches) with standard insets.
    private func padded(_ content: NSView, width: CGFloat, verticalInset: CGFloat) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            content.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: verticalInset),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: verticalInset),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
        ])
        return container
    }

    private func popup(model: [SettingsUI.PopupItem], action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        for m in model {
            let item = NSMenuItem(title: m.title, action: nil, keyEquivalent: "")
            item.representedObject = m.raw
            p.menu?.addItem(item)
            if m.selected { p.select(item) }
        }
        p.target = self
        p.action = action
        // One shared width across every popup (Stefan: differing widths per
        // content read as untidy); 200 clears the longest title with room.
        p.translatesAutoresizingMaskIntoConstraints = false
        p.widthAnchor.constraint(equalToConstant: 200).isActive = true
        return p
    }

    private func selectedRaw(_ sender: NSPopUpButton) -> String? {
        sender.selectedItem?.representedObject as? String
    }

    // MARK: - Actions (write the setting, fan out through hooks)

    @objc private func loginToggled(_ sender: NSButton) {
        LoginItem.setEnabled(sender.state == .on)
        // Registration can land in "requires approval"; reflect reality, not the click.
        sender.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func dockToggled(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "showDockIcon")
        hooks.dockChanged()
    }

    @objc private func styleChanged(_ sender: NSPopUpButton) {
        guard let raw = selectedRaw(sender), let v = DisplayStyle(rawValue: raw) else { return }
        Settings.style = v
        hooks.barChanged()
    }

    @objc private func colorChanged(_ sender: NSPopUpButton) {
        guard let raw = selectedRaw(sender), let v = ColorMode(rawValue: raw) else { return }
        Settings.colorMode = v
        hooks.colorChanged()
    }

    @objc private func showCodexChanged(_ sender: NSPopUpButton) {
        guard let raw = selectedRaw(sender), let v = ShowCodex(rawValue: raw) else { return }
        Settings.showCodex = v
        hooks.codexChanged()
    }

    @objc private func barShowsChanged(_ sender: NSPopUpButton) {
        guard let raw = selectedRaw(sender), let v = BarShows(rawValue: raw) else { return }
        Settings.barShows = v
        hooks.barChanged()
    }

    @objc private func graphsChanged(_ sender: NSPopUpButton) {
        guard let raw = selectedRaw(sender), let v = GraphsShown(rawValue: raw) else { return }
        Settings.graphs = v
        hooks.codexChanged()
    }

    @objc private func openRepo(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/smeingast/headroom")!)
    }
}
