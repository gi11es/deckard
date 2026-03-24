import AppKit
import KeyboardShortcuts

class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSTextViewDelegate {
    static let shared = SettingsWindowController()

    private enum Pane: String, CaseIterable {
        case general = "General"
        case theme = "Theme"
        case terminal = "Terminal"
        case shortcuts = "Shortcuts"
        case about = "About"

        var icon: NSImage {
            switch self {
            case .general: return NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")!
            case .theme: return NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "Theme")!
            case .terminal: return NSImage(systemSymbolName: "terminal", accessibilityDescription: "Terminal")!
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
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
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
        case .theme: newView = makeThemePane()
        case .terminal: newView = makeTerminalPane()
        case .shortcuts: newView = makeShortcutsPane()
        case .about: newView = makeAboutPane()
        }

        // Force the window to maintain its size — don't let auto layout shrink it
        let frame = window.frame
        window.contentView = newView
        window.setFrame(frame, display: true)
    }

    // MARK: - General Pane

    private func makeGeneralPane() -> NSView {
        let pane = NSView()

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .leading
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

    // MARK: - Theme Pane

    private var themeCollectionScrollView: NSScrollView?
    private var themeCardContainer: FlippedCardContainer?
    private var themeCards: [ThemeCardView] = []
    private var filteredThemeCards: [ThemeCardView] = []
    private var themeSearchField: NSSearchField?

    // MARK: - Terminal Pane

    private var fontNamePopup: NSPopUpButton?
    private var fontSizeField: NSTextField?
    private var fontSizeStepper: NSStepper?
    private var fontPreviewLabel: NSTextField?
    private var scrollbackField: NSTextField?
    private var tmuxOptionsTextView: NSTextView?

    /// A flipped NSView so card layout starts from the top.
    private class FlippedCardContainer: NSView {
        override var isFlipped: Bool { true }
    }

    private func makeThemePane() -> NSView {
        let pane = NSView()

        // Search field
        let searchField = NSSearchField()
        searchField.placeholderString = "Search themes..."
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(themeSearchChanged(_:))
        self.themeSearchField = searchField

        // Build theme cards
        themeCards = []
        let systemCard = ThemeCardView(name: "System Default", path: nil)
        systemCard.onSelect = { [weak self] card in self?.themeCardSelected(card) }
        themeCards.append(systemCard)

        for theme in ThemeManager.shared.availableThemes {
            let card = ThemeCardView(name: theme.name, path: theme.path)
            card.onSelect = { [weak self] card in self?.themeCardSelected(card) }
            themeCards.append(card)
        }
        filteredThemeCards = themeCards

        let currentName = ThemeManager.shared.currentThemeName
        for card in themeCards {
            card.isSelectedTheme = (currentName == nil && card.themePath == nil)
                || (currentName != nil && card.themeName == currentName)
        }

        // Card container inside a scroll view
        let container = FlippedCardContainer()
        container.translatesAutoresizingMaskIntoConstraints = false
        self.themeCardContainer = container

        for card in themeCards { container.addSubview(card) }

        let scrollView = NSScrollView()
        scrollView.documentView = container
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false
        self.themeCollectionScrollView = scrollView

        pane.addSubview(searchField)
        pane.addSubview(scrollView)

        // Badge colors
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(divider)

        let badgeLabel = NSTextField(labelWithString: "Status Indicators:")
        badgeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(badgeLabel)

        let badgeGrid = makeBadgeColorGrid()
        badgeGrid.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(badgeGrid)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: pane.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),
            scrollView.heightAnchor.constraint(equalToConstant: 300),

            container.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),

            divider.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 16),
            divider.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            divider.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),

            badgeLabel.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 12),
            badgeLabel.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),

            badgeGrid.topAnchor.constraint(equalTo: badgeLabel.bottomAnchor, constant: 8),
            badgeGrid.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            badgeGrid.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -16),
        ])

        // Perform initial layout after the view is sized
        DispatchQueue.main.async { [weak self] in
            self?.layoutThemeCards()
        }

        return pane
    }

    private func layoutThemeCards() {
        guard let container = themeCardContainer else { return }
        let padding: CGFloat = 8
        let spacing: CGFloat = 8
        let availableWidth = container.superview?.bounds.width ?? 600
        let cardWidth = floor((availableWidth - padding * 2 - spacing * 2) / 3)
        let cardHeight: CGFloat = 110

        var x = padding, y = padding
        var col = 0
        for card in filteredThemeCards {
            card.frame = NSRect(x: x, y: y, width: cardWidth, height: cardHeight)
            card.isHidden = false
            card.needsDisplay = true
            col += 1
            if col >= 3 {
                col = 0
                x = padding
                y += cardHeight + spacing
            } else {
                x += cardWidth + spacing
            }
        }
        // Hide non-matching cards
        for card in themeCards where !filteredThemeCards.contains(where: { $0 === card }) {
            card.isHidden = true
        }
        // Size container to fit
        let rows = ceil(Double(filteredThemeCards.count) / 3.0)
        let totalHeight = max(CGFloat(rows) * (cardHeight + spacing) + padding, 200)
        container.frame = NSRect(x: 0, y: 0, width: availableWidth, height: totalHeight)
    }

    @objc private func themeSearchChanged(_ sender: NSSearchField) {
        let filter = sender.stringValue
        if filter.isEmpty {
            filteredThemeCards = themeCards
        } else {
            filteredThemeCards = themeCards.filter {
                $0.themeName.localizedCaseInsensitiveContains(filter)
            }
        }
        layoutThemeCards()
    }

    private func themeCardSelected(_ card: ThemeCardView) {
        // Update selection state on all cards
        for c in themeCards {
            c.isSelectedTheme = (c === card)
        }
        // Apply the theme
        if card.themePath == nil {
            ThemeManager.shared.applyTheme(name: nil)
        } else {
            ThemeManager.shared.applyTheme(name: card.themeName)
        }
    }

    // MARK: - Terminal Pane

    private func makeTerminalPane() -> NSView {
        let pane = NSView()

        // Font picker
        let fontLabel = NSTextField(labelWithString: "Font:")
        fontLabel.font = .systemFont(ofSize: 13, weight: .medium)
        fontLabel.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(fontLabel)

        let savedFontName = UserDefaults.standard.string(forKey: "terminalFontName") ?? "SF Mono"
        let savedFontSize = UserDefaults.standard.double(forKey: "terminalFontSize")
        let currentFontSize = savedFontSize > 0 ? savedFontSize : 13.0

        let fontNamePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        fontNamePopup.translatesAutoresizingMaskIntoConstraints = false
        let monoFonts = NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch || family.localizedCaseInsensitiveContains("mono")
                || family.localizedCaseInsensitiveContains("courier")
                || family.localizedCaseInsensitiveContains("menlo")
                || family.localizedCaseInsensitiveContains("consolas")
        }
        for family in monoFonts.sorted() { fontNamePopup.addItem(withTitle: family) }
        if let idx = fontNamePopup.itemTitles.firstIndex(of: savedFontName) {
            fontNamePopup.selectItem(at: idx)
        }
        fontNamePopup.target = self
        fontNamePopup.action = #selector(fontSettingChanged(_:))
        self.fontNamePopup = fontNamePopup
        pane.addSubview(fontNamePopup)

        let sizeLabel = NSTextField(labelWithString: "Size:")
        sizeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(sizeLabel)

        let sizeField = NSTextField(string: String(format: "%.0f", currentFontSize))
        sizeField.translatesAutoresizingMaskIntoConstraints = false
        sizeField.alignment = .center
        let formatter = NumberFormatter()
        formatter.minimum = 8
        formatter.maximum = 36
        formatter.allowsFloats = false
        sizeField.formatter = formatter
        sizeField.target = self
        sizeField.action = #selector(fontSettingChanged(_:))
        self.fontSizeField = sizeField
        pane.addSubview(sizeField)

        let sizeStepper = NSStepper()
        sizeStepper.translatesAutoresizingMaskIntoConstraints = false
        sizeStepper.minValue = 8
        sizeStepper.maxValue = 36
        sizeStepper.increment = 1
        sizeStepper.doubleValue = currentFontSize
        sizeStepper.target = self
        sizeStepper.action = #selector(fontSizeStepperChanged(_:))
        self.fontSizeStepper = sizeStepper
        pane.addSubview(sizeStepper)

        // Font preview
        let previewBox = NSBox()
        previewBox.title = ""
        previewBox.boxType = .custom
        previewBox.borderType = .bezelBorder
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(previewBox)

        let previewText = NSTextField(labelWithString: "ABCDEFGHIJKLM 0123456789\nThe quick brown fox jumps over the lazy dog\n~$ claude --help")
        previewText.maximumNumberOfLines = 3
        previewText.font = NSFont(name: savedFontName, size: CGFloat(currentFontSize))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(currentFontSize), weight: .regular)
        previewText.textColor = .labelColor
        previewText.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(previewText)
        self.fontPreviewLabel = previewText

        // Scrollback
        let scrollLabel = NSTextField(labelWithString: "Scrollback:")
        scrollLabel.font = .systemFont(ofSize: 13, weight: .medium)
        scrollLabel.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(scrollLabel)

        let savedScrollback = UserDefaults.standard.integer(forKey: "terminalScrollback")
        let currentScrollback = savedScrollback > 0 ? savedScrollback : TerminalSurface.defaultScrollback

        let scrollField = NSTextField(string: "\(currentScrollback)")
        scrollField.translatesAutoresizingMaskIntoConstraints = false
        scrollField.alignment = .right
        let scrollFormatter = NumberFormatter()
        scrollFormatter.minimum = 100
        scrollFormatter.maximum = 100_000
        scrollFormatter.allowsFloats = false
        scrollField.formatter = scrollFormatter
        scrollField.target = self
        scrollField.action = #selector(scrollbackChanged(_:))
        self.scrollbackField = scrollField
        pane.addSubview(scrollField)

        let scrollUnit = NSTextField(labelWithString: "lines")
        scrollUnit.font = .systemFont(ofSize: 13)
        scrollUnit.textColor = .secondaryLabelColor
        scrollUnit.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(scrollUnit)

        // tmux section
        let tmuxDivider = NSBox()
        tmuxDivider.boxType = .separator
        tmuxDivider.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(tmuxDivider)

        let tmuxEnabled = UserDefaults.standard.object(forKey: "useTmux") as? Bool ?? true
        let tmuxCheckbox = NSButton(checkboxWithTitle: "Use tmux for session persistence (if installed)", target: self, action: #selector(tmuxToggleChanged(_:)))
        tmuxCheckbox.state = tmuxEnabled ? .on : .off
        tmuxCheckbox.translatesAutoresizingMaskIntoConstraints = false
        if !TerminalSurface.tmuxAvailable {
            tmuxCheckbox.isEnabled = false
            tmuxCheckbox.title = "Use tmux for session persistence (tmux not found)"
        }
        pane.addSubview(tmuxCheckbox)

        let tmuxOptionsLabel = NSTextField(labelWithString: "tmux options:")
        tmuxOptionsLabel.font = .systemFont(ofSize: 13, weight: .medium)
        tmuxOptionsLabel.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(tmuxOptionsLabel)

        let savedOptions = UserDefaults.standard.string(forKey: "tmuxOptions")
            ?? TerminalSurface.defaultTmuxOptions
        let tmuxTextView = NSTextView()
        tmuxTextView.string = savedOptions
        tmuxTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tmuxTextView.isEditable = true
        tmuxTextView.isRichText = false
        tmuxTextView.allowsUndo = true
        tmuxTextView.delegate = self
        tmuxTextView.isAutomaticQuoteSubstitutionEnabled = false
        tmuxTextView.isAutomaticDashSubstitutionEnabled = false
        tmuxTextView.isAutomaticTextReplacementEnabled = false
        self.tmuxOptionsTextView = tmuxTextView

        let tmuxScrollView = NSScrollView()
        tmuxScrollView.documentView = tmuxTextView
        tmuxScrollView.hasVerticalScroller = true
        tmuxScrollView.translatesAutoresizingMaskIntoConstraints = false
        tmuxScrollView.borderType = .bezelBorder
        pane.addSubview(tmuxScrollView)

        let tmuxHelpLabel = NSTextField(labelWithString: "One tmux command per line (set, bind-key, etc.). Lines starting with # are comments. Applied to each new session.")
        tmuxHelpLabel.font = .systemFont(ofSize: 11)
        tmuxHelpLabel.textColor = .secondaryLabelColor
        tmuxHelpLabel.maximumNumberOfLines = 2
        tmuxHelpLabel.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(tmuxHelpLabel)

        let resetTmuxButton = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetTmuxOptions))
        resetTmuxButton.bezelStyle = .rounded
        resetTmuxButton.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(resetTmuxButton)

        NSLayoutConstraint.activate([
            fontLabel.topAnchor.constraint(equalTo: pane.topAnchor, constant: 20),
            fontLabel.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),

            fontNamePopup.centerYAnchor.constraint(equalTo: fontLabel.centerYAnchor),
            fontNamePopup.leadingAnchor.constraint(equalTo: fontLabel.trailingAnchor, constant: 8),
            fontNamePopup.widthAnchor.constraint(equalToConstant: 200),

            sizeLabel.centerYAnchor.constraint(equalTo: fontLabel.centerYAnchor),
            sizeLabel.leadingAnchor.constraint(equalTo: fontNamePopup.trailingAnchor, constant: 16),

            sizeField.centerYAnchor.constraint(equalTo: fontLabel.centerYAnchor),
            sizeField.leadingAnchor.constraint(equalTo: sizeLabel.trailingAnchor, constant: 4),
            sizeField.widthAnchor.constraint(equalToConstant: 40),

            sizeStepper.centerYAnchor.constraint(equalTo: fontLabel.centerYAnchor),
            sizeStepper.leadingAnchor.constraint(equalTo: sizeField.trailingAnchor, constant: 2),

            previewBox.topAnchor.constraint(equalTo: fontLabel.bottomAnchor, constant: 12),
            previewBox.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            previewBox.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),
            previewBox.heightAnchor.constraint(equalToConstant: 60),

            previewText.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 6),
            previewText.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 8),
            previewText.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -8),

            scrollLabel.topAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: 16),
            scrollLabel.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),

            scrollField.centerYAnchor.constraint(equalTo: scrollLabel.centerYAnchor),
            scrollField.leadingAnchor.constraint(equalTo: scrollLabel.trailingAnchor, constant: 8),
            scrollField.widthAnchor.constraint(equalToConstant: 70),

            scrollUnit.centerYAnchor.constraint(equalTo: scrollLabel.centerYAnchor),
            scrollUnit.leadingAnchor.constraint(equalTo: scrollField.trailingAnchor, constant: 4),

            tmuxDivider.topAnchor.constraint(equalTo: scrollLabel.bottomAnchor, constant: 16),
            tmuxDivider.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            tmuxDivider.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),

            tmuxCheckbox.topAnchor.constraint(equalTo: tmuxDivider.bottomAnchor, constant: 12),
            tmuxCheckbox.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),

            tmuxOptionsLabel.topAnchor.constraint(equalTo: tmuxCheckbox.bottomAnchor, constant: 12),
            tmuxOptionsLabel.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),

            tmuxScrollView.topAnchor.constraint(equalTo: tmuxOptionsLabel.bottomAnchor, constant: 4),
            tmuxScrollView.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            tmuxScrollView.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),
            tmuxScrollView.heightAnchor.constraint(equalToConstant: 80),

            tmuxTextView.widthAnchor.constraint(equalTo: tmuxScrollView.contentView.widthAnchor),

            tmuxHelpLabel.topAnchor.constraint(equalTo: tmuxScrollView.bottomAnchor, constant: 4),
            tmuxHelpLabel.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            tmuxHelpLabel.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),

            resetTmuxButton.topAnchor.constraint(equalTo: tmuxHelpLabel.bottomAnchor, constant: 8),
            resetTmuxButton.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            resetTmuxButton.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -20),
        ])

        return pane
    }

    // MARK: - Font Settings

    @objc private func fontSettingChanged(_ sender: Any) {
        applyFontSettings()
    }

    @objc private func fontSizeStepperChanged(_ sender: NSStepper) {
        fontSizeField?.stringValue = String(format: "%.0f", sender.doubleValue)
        applyFontSettings()
    }

    private func applyFontSettings() {
        guard let fontName = fontNamePopup?.titleOfSelectedItem,
              let sizeStr = fontSizeField?.stringValue,
              let size = Double(sizeStr), size >= 8, size <= 36 else { return }

        fontSizeStepper?.doubleValue = size

        UserDefaults.standard.set(fontName, forKey: "terminalFontName")
        UserDefaults.standard.set(size, forKey: "terminalFontSize")

        // Update preview
        let font = NSFont(name: fontName, size: CGFloat(size))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
        fontPreviewLabel?.font = font

        // Notify terminals to update font
        NotificationCenter.default.post(name: .deckardFontChanged, object: nil,
                                        userInfo: ["font": font])
    }

    // MARK: - tmux Settings

    @objc private func tmuxToggleChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "useTmux")
    }

    @objc private func resetTmuxOptions() {
        tmuxOptionsTextView?.string = TerminalSurface.defaultTmuxOptions
        UserDefaults.standard.removeObject(forKey: "tmuxOptions")
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              textView === tmuxOptionsTextView else { return }
        UserDefaults.standard.set(textView.string, forKey: "tmuxOptions")
    }

    // MARK: - Scrollback Settings

    @objc private func scrollbackChanged(_ sender: NSTextField) {
        guard let lines = Int(sender.stringValue), lines >= 100, lines <= 100_000 else { return }
        UserDefaults.standard.set(lines, forKey: "terminalScrollback")
        NotificationCenter.default.post(name: .deckardScrollbackChanged, object: nil,
                                        userInfo: ["lines": lines])
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
        let borderColor = NSColor.separatorColor.cgColor
        let rowHeight: CGFloat = 28
        let colWidths: [CGFloat] = [70, 120, 50, 50]  // section, state, color, blink
        let tableWidth = colWidths.reduce(0, +)

        let allSections: [(title: String, entries: [(state: TabItem.BadgeState, label: String)])] = [
            ("Claude", Self.claudeBadgeEntries),
            ("Terminal", Self.terminalBadgeEntries),
        ]

        // Count total rows: header + all entries
        let totalRows = 1 + allSections.reduce(0) { $0 + $1.entries.count }

        let container = NSView()
        container.wantsLayer = true
        container.layer?.borderColor = borderColor
        container.layer?.borderWidth = 1
        container.layer?.cornerRadius = 4
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: tableWidth),
            container.heightAnchor.constraint(equalToConstant: CGFloat(totalRows) * rowHeight),
        ])

        func makeCell(_ width: CGFloat, y: CGFloat) -> NSView {
            let cell = NSView()
            cell.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(cell)
            NSLayoutConstraint.activate([
                cell.widthAnchor.constraint(equalToConstant: width),
                cell.heightAnchor.constraint(equalToConstant: rowHeight),
            ])
            return cell
        }

        func addHLine(y: CGFloat) {
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = borderColor
            line.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                line.topAnchor.constraint(equalTo: container.topAnchor, constant: y),
                line.heightAnchor.constraint(equalToConstant: 1),
            ])
        }

        func addVLine(x: CGFloat, fromY: CGFloat, toY: CGFloat) {
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = borderColor
            line.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: x),
                line.widthAnchor.constraint(equalToConstant: 1),
                line.topAnchor.constraint(equalTo: container.topAnchor, constant: fromY),
                line.heightAnchor.constraint(equalToConstant: toY - fromY),
            ])
        }

        func placeView(_ view: NSView, x: CGFloat, y: CGFloat, width: CGFloat) {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerYAnchor.constraint(equalTo: container.topAnchor, constant: y + rowHeight / 2),
                view.centerXAnchor.constraint(equalTo: container.leadingAnchor, constant: x + width / 2),
            ])
        }

        func placeLabel(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, bold: Bool = false, align: NSTextAlignment = .center) {
            let label = NSTextField(labelWithString: text)
            label.font = bold ? .systemFont(ofSize: 11, weight: .medium) : .systemFont(ofSize: 12)
            label.textColor = bold ? .secondaryLabelColor : .labelColor
            label.alignment = align
            placeView(label, x: x, y: y, width: width)
        }

        // Header row
        var x: CGFloat = 0
        placeLabel("", x: x, y: 0, width: colWidths[0], bold: true)
        x += colWidths[0]
        placeLabel("State", x: x, y: 0, width: colWidths[1], bold: true)
        x += colWidths[1]
        placeLabel("Color", x: x, y: 0, width: colWidths[2], bold: true)
        x += colWidths[2]
        placeLabel("Blink", x: x, y: 0, width: colWidths[3], bold: true)

        addHLine(y: rowHeight)

        // Vertical lines for all columns
        x = colWidths[0]
        for i in 1..<colWidths.count {
            addVLine(x: x, fromY: 0, toY: CGFloat(totalRows) * rowHeight)
            x += colWidths[i]
        }

        // Data rows
        var row = 1
        for (si, section) in allSections.enumerated() {
            for (ei, entry) in section.entries.enumerated() {
                let y = CGFloat(row) * rowHeight

                // Section label — only on first entry of each section
                if ei == 0 {
                    placeLabel(section.title, x: 0, y: y, width: colWidths[0], bold: true)
                }

                // State label
                placeLabel(entry.label, x: colWidths[0], y: y, width: colWidths[1])

                // Color well
                let well = makeBadgeColorWell(for: entry.state)
                placeView(well, x: colWidths[0] + colWidths[1], y: y, width: colWidths[2])

                // Blink toggle
                let toggle = NSButton(checkboxWithTitle: "", target: self, action: #selector(badgeAnimateChanged(_:)))
                toggle.state = Self.isBadgeAnimated(entry.state) ? .on : .off
                toggle.controlSize = .small
                objc_setAssociatedObject(toggle, &settingsKeyAssoc, entry.state.rawValue, .OBJC_ASSOCIATION_RETAIN)
                placeView(toggle, x: colWidths[0] + colWidths[1] + colWidths[2], y: y, width: colWidths[3])

                addHLine(y: y + rowHeight)
                row += 1
            }

            // Section separator (thicker line between Claude and Terminal)
            if si < allSections.count - 1 {
                // The horizontal line is already drawn — we could make it thicker
                // but the regular 1px line is fine for a spreadsheet look
            }
        }

        // Wrap in a vertical stack with the reset button
        let wrapper = NSStackView()
        wrapper.orientation = .vertical
        wrapper.alignment = .trailing
        wrapper.spacing = 8
        wrapper.addArrangedSubview(container)

        let resetButton = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetBadgeColors))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        wrapper.addArrangedSubview(resetButton)

        return wrapper
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
        switchToPane(.theme)
        if let wc = NSApp.delegate as? AppDelegate {
            wc.windowController?.rebuildSidebar()
            wc.windowController?.rebuildTabBar()
        }
    }

    // MARK: - Shortcuts Pane

    private func makeShortcutsPane() -> NSView {
        let pane = NSView()

        // 4-column grid: label1 | recorder1 | label2 | recorder2
        // Use explicit column widths to prevent random layout shifts.
        let grid = NSGridView(numberOfColumns: 4, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 2).xPlacement = .trailing
        grid.column(at: 3).xPlacement = .leading
        grid.rowSpacing = 8
        grid.columnSpacing = 12

        // Pin column widths so they never shift
        grid.column(at: 0).width = 140
        grid.column(at: 1).width = 100
        grid.column(at: 2).width = 60
        grid.column(at: 3).width = 100

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
            grid.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
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

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let versionLabel = NSTextField(labelWithString: "Version \(version)")
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


private var settingsKeyAssoc: UInt8 = 0
