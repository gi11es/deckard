import AppKit
import KeyboardShortcuts

class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    private enum Pane: String, CaseIterable {
        case general = "General"
        case shortcuts = "Shortcuts"
        case about = "About"

        var icon: NSImage {
            switch self {
            case .general: return NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")!
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

        let versionLabel = NSTextField(labelWithString: "Version 0.1.4")
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
