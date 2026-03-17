import AppKit
import KeyboardShortcuts

class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    private enum Pane: String, CaseIterable {
        case general = "General"
        case appearance = "Appearance"
        case shortcuts = "Shortcuts"
        case about = "About"

        var icon: NSImage {
            switch self {
            case .general: return NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")!
            case .appearance: return NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "Appearance")!
            case .shortcuts: return NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Shortcuts")!
            case .about: return NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About")!
            }
        }

        var toolbarItemIdentifier: NSToolbarItem.Identifier {
            NSToolbarItem.Identifier(rawValue)
        }
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()

        super.init(window: window)

        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = Pane.general.toolbarItemIdentifier
        window.toolbar = toolbar
        window.toolbarStyle = .preference

        switchToPane(.general)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = Pane(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.rawValue
        item.image = pane.icon
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.toolbarItemIdentifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.toolbarItemIdentifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.toolbarItemIdentifier)
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        guard let pane = Pane(rawValue: sender.itemIdentifier.rawValue) else { return }
        switchToPane(pane)
    }

    private func switchToPane(_ pane: Pane) {
        guard let window = window else { return }

        window.title = pane.rawValue

        let newView: NSView
        switch pane {
        case .general: newView = makeGeneralPane()
        case .appearance: newView = makeAppearancePane()
        case .shortcuts: newView = makeShortcutsPane()
        case .about: newView = makeAboutPane()
        }

        // Resize window to fit the new pane content
        let newSize = newView.fittingSize
        let oldFrame = window.frame
        let contentRect = window.contentRect(forFrameRect: oldFrame)
        let chromeHeight = oldFrame.height - contentRect.height
        var newFrame = oldFrame
        newFrame.size.height = newSize.height + chromeHeight
        newFrame.size.width = max(newSize.width, 480)
        newFrame.origin.y += oldFrame.height - newFrame.height

        window.contentView = newView
        window.setFrame(newFrame, display: true, animate: window.isVisible)
    }

    // MARK: - General Pane

    private func makeGeneralPane() -> NSView {
        let pane = NSView()

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.rowSpacing = 6
        grid.columnSpacing = 8

        // Extra arguments
        let extraArgsLabel = NSTextField(labelWithString: "Extra arguments:")
        extraArgsLabel.alignment = .right

        let extraArgsField = NSTextField()
        extraArgsField.stringValue = UserDefaults.standard.string(forKey: "claudeExtraArgs") ?? ""
        extraArgsField.placeholderString = "--dangerously-skip-permissions"
        extraArgsField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        objc_setAssociatedObject(extraArgsField, &settingsKeyAssoc, "claudeExtraArgs", .OBJC_ASSOCIATION_RETAIN)
        extraArgsField.target = self
        extraArgsField.action = #selector(textFieldChanged(_:))

        grid.addRow(with: [extraArgsLabel, extraArgsField])

        let extraArgsHelp = NSTextField(labelWithString: "Arguments passed to every new Claude Code session.")
        extraArgsHelp.font = .systemFont(ofSize: 11)
        extraArgsHelp.textColor = .secondaryLabelColor
        grid.addRow(with: [NSGridCell.emptyContentView, extraArgsHelp])

        // Spacer
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 8).isActive = true
        grid.addRow(with: [NSGridCell.emptyContentView, spacer])

        // Default tabs
        let tabConfigLabel = NSTextField(labelWithString: "Default tabs:")
        tabConfigLabel.alignment = .right

        let tabConfigField = NSTextField()
        tabConfigField.stringValue = UserDefaults.standard.string(forKey: "defaultTabConfig") ?? "claude, terminal"
        tabConfigField.placeholderString = "claude, terminal"
        tabConfigField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        objc_setAssociatedObject(tabConfigField, &settingsKeyAssoc, "defaultTabConfig", .OBJC_ASSOCIATION_RETAIN)
        tabConfigField.target = self
        tabConfigField.action = #selector(textFieldChanged(_:))

        if UserDefaults.standard.string(forKey: "defaultTabConfig") == nil {
            UserDefaults.standard.set("claude, terminal", forKey: "defaultTabConfig")
        }

        grid.addRow(with: [tabConfigLabel, tabConfigField])

        let tabConfigHelp = NSTextField(labelWithString: "Comma-separated list: claude, terminal")
        tabConfigHelp.font = .systemFont(ofSize: 11)
        tabConfigHelp.textColor = .secondaryLabelColor
        grid.addRow(with: [NSGridCell.emptyContentView, tabConfigHelp])

        pane.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: pane.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 40),
            grid.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -40),
            grid.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -20),
        ])

        return pane
    }

    // MARK: - Appearance Pane

    private var themeTableView: NSTableView?
    private var themeSearchField: NSSearchField?
    private var filteredThemes: [ThemeManager.ThemeInfo] = []
    private var allThemeEntries: [(name: String, info: ThemeManager.ThemeInfo?)] = []  // nil info = System Default
    private var suppressThemeSelection = false

    private func makeAppearancePane() -> NSView {
        let pane = NSView()

        let label = NSTextField(labelWithString: "Theme:")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        let searchField = NSSearchField()
        searchField.placeholderString = "Search themes..."
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(themeSearchChanged(_:))
        self.themeSearchField = searchField

        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("theme"))
        column.title = "Theme"
        tableView.addTableColumn(column)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(themeRowClicked)
        self.themeTableView = tableView

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .bezelBorder

        pane.addSubview(label)
        pane.addSubview(searchField)
        pane.addSubview(scrollView)

        // Divider between theme picker and badge colors
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(divider)

        // Status indicators section
        let badgeLabel = NSTextField(labelWithString: "Status Indicators:")
        badgeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(badgeLabel)

        let badgeGrid = makeBadgeColorGrid()
        badgeGrid.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(badgeGrid)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: pane.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),

            searchField.topAnchor.constraint(equalTo: pane.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),

            divider.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 20),
            divider.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            divider.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),

            badgeLabel.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 16),
            badgeLabel.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),

            badgeGrid.topAnchor.constraint(equalTo: badgeLabel.bottomAnchor, constant: 8),
            badgeGrid.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            badgeGrid.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),
            badgeGrid.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -16),
        ])

        // Populate theme list
        rebuildThemeList(filter: "")

        // Select current theme without triggering applyTheme
        suppressThemeSelection = true
        if let current = ThemeManager.shared.currentThemeName {
            if let idx = allThemeEntries.firstIndex(where: { $0.name == current }) {
                tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                tableView.scrollRowToVisible(idx)
            }
        } else {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        suppressThemeSelection = false

        return pane
    }

    private func rebuildThemeList(filter: String) {
        var entries: [(name: String, info: ThemeManager.ThemeInfo?)] = []
        entries.append((name: "System Default", info: nil))

        for theme in ThemeManager.shared.availableThemes {
            if filter.isEmpty || theme.name.localizedCaseInsensitiveContains(filter) {
                entries.append((name: theme.name, info: theme))
            }
        }
        allThemeEntries = entries
        themeTableView?.reloadData()
    }

    @objc private func themeSearchChanged(_ sender: NSSearchField) {
        rebuildThemeList(filter: sender.stringValue)
    }

    private func applySelectedTheme() {
        guard !suppressThemeSelection else { return }
        guard let tableView = themeTableView else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < allThemeEntries.count else { return }

        let entry = allThemeEntries[row]
        ThemeManager.shared.applyTheme(name: entry.info?.name)
    }

    @objc private func themeRowClicked() {
        applySelectedTheme()
    }

    // MARK: - Badge Color Grid

    private static let claudeBadgeEntries: [(state: TabItem.BadgeState, label: String)] = [
        (.idle, "Idle"),
        (.thinking, "Thinking"),
        (.waitingForInput, "Ready"),
        (.needsPermission, "Needs Permission"),
        (.error, "Error"),
    ]

    private static let terminalBadgeEntries: [(state: TabItem.BadgeState, label: String)] = [
        (.terminalIdle, "Idle"),
        (.terminalActive, "Busy"),
        (.terminalError, "Error"),
    ]

    /// Default animation settings per state.
    static let defaultBadgeAnimated: Set<TabItem.BadgeState> = [.thinking, .terminalActive]

    static func isBadgeAnimated(_ state: TabItem.BadgeState) -> Bool {
        if let saved = UserDefaults.standard.object(forKey: "badgeAnimate.\(state.rawValue)") as? Bool {
            return saved
        }
        return defaultBadgeAnimated.contains(state)
    }

    private func makeBadgeColorGrid() -> NSView {
        // 6-column grid: [label] [well] [pulse] [label] [well] [pulse]
        let grid = NSGridView(numberOfColumns: 6, rows: 0)
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 2).xPlacement = .center
        grid.column(at: 3).xPlacement = .trailing
        grid.column(at: 4).xPlacement = .leading
        grid.column(at: 5).xPlacement = .center
        grid.rowSpacing = 4
        grid.columnSpacing = 6

        func makeEntryViews(_ entry: (state: TabItem.BadgeState, label: String)) -> (NSView, NSView, NSView) {
            let label = NSTextField(labelWithString: entry.label)
            label.alignment = .right
            label.font = .systemFont(ofSize: 12)
            let well = makeBadgeColorWell(for: entry.state)
            let toggle = NSButton(checkboxWithTitle: "", target: self, action: #selector(badgeAnimateChanged(_:)))
            toggle.state = Self.isBadgeAnimated(entry.state) ? .on : .off
            objc_setAssociatedObject(toggle, &settingsKeyAssoc, entry.state.rawValue, .OBJC_ASSOCIATION_RETAIN)
            return (label, well, toggle)
        }

        func addSection(_ title: String, entries: [(state: TabItem.BadgeState, label: String)]) {
            // Section header as its own row, left-aligned
            let header = NSTextField(labelWithString: title)
            header.font = .systemFont(ofSize: 10, weight: .semibold)
            header.textColor = .tertiaryLabelColor
            header.alignment = .left
            let headerRow = grid.addRow(with: [header, NSView(), NSView(), NSView(), NSView(), NSView()])
            headerRow.mergeCells(in: NSRange(location: 0, length: 6))

            let rows = (entries.count + 1) / 2
            for r in 0..<rows {
                let leftIdx = r
                let rightIdx = r + rows
                let (ll, lw, lt) = makeEntryViews(entries[leftIdx])

                if rightIdx < entries.count {
                    let (rl, rw, rt) = makeEntryViews(entries[rightIdx])
                    grid.addRow(with: [ll, lw, lt, rl, rw, rt])
                } else {
                    grid.addRow(with: [ll, lw, lt, NSView(), NSView(), NSView()])
                }
            }
        }

        addSection("CLAUDE", entries: Self.claudeBadgeEntries)

        // Separator
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        let sepRow = grid.addRow(with: [sep, NSView(), NSView(), NSView(), NSView(), NSView()])
        sepRow.mergeCells(in: NSRange(location: 0, length: 6))

        addSection("TERMINAL", entries: Self.terminalBadgeEntries)

        // Reset button
        let resetButton = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetBadgeColors))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        grid.addRow(with: [NSView(), NSView(), NSView(), NSView(), NSView(), resetButton])

        return grid
    }

    private func makeBadgeColorWell(for state: TabItem.BadgeState) -> NSColorWell {
        let well: NSColorWell
        if #available(macOS 14.0, *) {
            well = NSColorWell(style: .minimal)
        } else {
            well = NSColorWell()
        }
        well.color = VerticalTabRowView.colorForBadge(state)
        well.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            well.widthAnchor.constraint(equalToConstant: 36),
            well.heightAnchor.constraint(equalToConstant: 24),
        ])
        well.tag = state.hashValue
        objc_setAssociatedObject(well, &settingsKeyAssoc, state.rawValue, .OBJC_ASSOCIATION_RETAIN)
        well.target = self
        well.action = #selector(badgeColorChanged(_:))
        return well
    }

    @objc private func badgeColorChanged(_ sender: NSColorWell) {
        guard let stateRaw = objc_getAssociatedObject(sender, &settingsKeyAssoc) as? String else { return }
        UserDefaults.standard.set(sender.color.toHex(), forKey: "badgeColor.\(stateRaw)")
        // Trigger immediate UI update
        if let wc = NSApp.delegate as? AppDelegate {
            wc.windowController?.rebuildSidebar()
            wc.windowController?.rebuildTabBar()
        }
    }

    @objc private func badgeAnimateChanged(_ sender: NSButton) {
        guard let stateRaw = objc_getAssociatedObject(sender, &settingsKeyAssoc) as? String else { return }
        UserDefaults.standard.set(sender.state == .on, forKey: "badgeAnimate.\(stateRaw)")
        if let wc = NSApp.delegate as? AppDelegate {
            wc.windowController?.rebuildSidebar()
            wc.windowController?.rebuildTabBar()
        }
    }

    @objc private func resetBadgeColors() {
        for entry in Self.claudeBadgeEntries + Self.terminalBadgeEntries {
            UserDefaults.standard.removeObject(forKey: "badgeColor.\(entry.state.rawValue)")
            UserDefaults.standard.removeObject(forKey: "badgeAnimate.\(entry.state.rawValue)")
        }
        // Refresh the pane to show default colors
        switchToPane(.appearance)
        if let wc = NSApp.delegate as? AppDelegate {
            wc.windowController?.rebuildSidebar()
            wc.windowController?.rebuildTabBar()
        }
    }

    // MARK: - Shortcuts Pane

    private func makeShortcutsPane() -> NSView {
        let pane = NSView()

        // 4-column grid: label1 | recorder1 | label2 | recorder2
        let grid = NSGridView(numberOfColumns: 4, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 2).xPlacement = .trailing
        grid.column(at: 3).xPlacement = .leading
        grid.rowSpacing = 8
        grid.columnSpacing = 12

        // Lay out entries in two columns
        let entries = configurableShortcuts
        let rows = (entries.count + 1) / 2
        for row in 0..<rows {
            let leftIdx = row
            let rightIdx = row + rows

            let leftLabel = NSTextField(labelWithString: entries[leftIdx].label)
            leftLabel.alignment = .right
            let leftRecorder = KeyboardShortcuts.RecorderCocoa(for: entries[leftIdx].name)

            if rightIdx < entries.count {
                let rightLabel = NSTextField(labelWithString: entries[rightIdx].label)
                rightLabel.alignment = .right
                let rightRecorder = KeyboardShortcuts.RecorderCocoa(for: entries[rightIdx].name)
                grid.addRow(with: [leftLabel, leftRecorder, rightLabel, rightRecorder])
            } else {
                grid.addRow(with: [leftLabel, leftRecorder, NSView(), NSView()])
            }
        }

        // Reset button spanning the right side
        let resetButton = NSButton(title: "Reset All to Defaults", target: self, action: #selector(resetShortcuts))
        resetButton.bezelStyle = .rounded
        grid.addRow(with: [NSView(), NSView(), NSView(), resetButton])

        pane.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: pane.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -20),
        ])

        return pane
    }

    @objc private func resetShortcuts() {
        for entry in configurableShortcuts {
            KeyboardShortcuts.reset(entry.name)
        }
        // Rebuild the pane to reflect reset values
        switchToPane(.shortcuts)
    }

    // MARK: - About Pane

    private func makeAboutPane() -> NSView {
        let pane = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let iconPath = Bundle.main.resourceURL?.appendingPathComponent("AppIcon.icns").path,
           let icon = NSImage(contentsOfFile: iconPath) {
            let imageView = NSImageView(image: icon)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 64),
                imageView.heightAnchor.constraint(equalToConstant: 64),
            ])
            stack.addArrangedSubview(imageView)
            stack.setCustomSpacing(12, after: imageView)
        }

        let nameLabel = NSTextField(labelWithString: "Deckard")
        nameLabel.font = .boldSystemFont(ofSize: 14)
        stack.addArrangedSubview(nameLabel)

        let versionLabel = NSTextField(labelWithString: "Version 0.1.7")
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(versionLabel)

        let descLabel = NSTextField(labelWithString: "Multi-session Claude Code terminal manager")
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(descLabel)

        pane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            stack.topAnchor.constraint(equalTo: pane.topAnchor, constant: 30),
            stack.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -30),
        ])

        return pane
    }

    @objc private func textFieldChanged(_ sender: NSTextField) {
        guard let key = objc_getAssociatedObject(sender, &settingsKeyAssoc) as? String else { return }
        UserDefaults.standard.set(sender.stringValue, forKey: key)
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Theme Table DataSource/Delegate

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        allThemeEntries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ThemeCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField
            ?? {
                let tf = NSTextField(labelWithString: "")
                tf.identifier = id
                tf.lineBreakMode = .byTruncatingTail
                return tf
            }()
        let entry = allThemeEntries[row]
        cell.stringValue = entry.name
        cell.font = entry.info == nil ? .systemFont(ofSize: 13, weight: .medium) : .systemFont(ofSize: 13)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        applySelectedTheme()
    }
}

private var settingsKeyAssoc: UInt8 = 0
