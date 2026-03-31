import AppKit
import Fuse
import ObjectiveC

/// A chip-based text field for entering Claude CLI arguments with autocomplete.
final class ClaudeArgsField: NSView {

    var onChange: ((String) -> Void)?

    private var chips: [ArgsChip] = []
    private let chipContainer = NSView()
    private let textField = NSTextField()
    private var chipViews: [NSView] = []
    private var selectedChipIndex: Int?
    private var pendingFlag: ClaudeFlag?
    private var chipContainerHeightConstraint: NSLayoutConstraint?
    private var lastLayoutWidth: CGFloat = 0

    var stringValue: String {
        get { ArgsChip.serialize(chips) }
        set { loadChips(from: newValue) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        updateBorderColor()

        chipContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chipContainer)

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textField.focusRingType = .none
        textField.placeholderString = "Type a flag name..."
        textField.delegate = self
        textField.cell?.sendsActionOnEndEditing = false
        addSubview(textField)

        // Re-parse chips when CLI flags finish loading (they load async at startup).
        NotificationCenter.default.addObserver(
            self, selector: #selector(flagsDidLoad),
            name: ClaudeCLIFlags.didLoadNotification, object: nil
        )

        NSLayoutConstraint.activate([
            chipContainer.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            chipContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            chipContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),

            textField.topAnchor.constraint(equalTo: chipContainer.bottomAnchor, constant: 2),
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            textField.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    @objc private func flagsDidLoad() {
        // Re-parse the current value now that we know which flags are boolean vs valued.
        let current = stringValue
        if !current.isEmpty {
            loadChips(from: current)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Chip Management

    private func loadChips(from string: String) {
        chips = ArgsChip.deserialize(string, knownFlags: ClaudeCLIFlags.shared.flags)
        rebuildChipViews()
    }

    func addChip(_ chip: ArgsChip) {
        chips.append(chip)
        rebuildChipViews()
        onChange?(stringValue)
    }

    private func removeChip(at index: Int) {
        guard index >= 0 && index < chips.count else { return }
        chips.remove(at: index)
        selectedChipIndex = nil
        rebuildChipViews()
        onChange?(stringValue)
    }

    private func rebuildChipViews() {
        chipViews.forEach { $0.removeFromSuperview() }
        chipViews.removeAll()

        chipContainerHeightConstraint?.isActive = false

        guard !chips.isEmpty else {
            let zeroHeight = chipContainer.heightAnchor.constraint(equalToConstant: 0)
            zeroHeight.isActive = true
            chipContainerHeightConstraint = zeroHeight
            textField.placeholderString = "Type a flag name..."
            return
        }

        textField.placeholderString = ""

        var x: CGFloat = 0
        var y: CGFloat = 0
        let spacing: CGFloat = 4
        let maxWidth = bounds.width - 12

        for (i, chip) in chips.enumerated() {
            let view = makeChipView(chip, index: i)
            let size = view.fittingSize
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += size.height + spacing
            }
            view.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            chipContainer.addSubview(view)
            chipViews.append(view)
            x += size.width + spacing
        }

        let totalHeight = y + (chipViews.last?.frame.height ?? 0)
        let heightConstraint = chipContainer.heightAnchor.constraint(equalToConstant: totalHeight)
        heightConstraint.isActive = true
        chipContainerHeightConstraint = heightConstraint
    }

    private func makeChipView(_ chip: ArgsChip, index: Int) -> NSView {
        let label: String
        if let value = chip.value {
            label = "\(chip.flag) \(value)"
        } else {
            label = chip.flag
        }

        let button = NSButton(title: label, target: self, action: #selector(chipClicked(_:)))
        button.tag = index
        button.bezelStyle = .inline
        button.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        button.isBordered = true
        button.wantsLayer = true
        button.layer?.cornerRadius = 4

        if selectedChipIndex == index {
            button.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
            button.contentTintColor = .white
        }

        return button
    }

    @objc private func chipClicked(_ sender: NSButton) {
        if selectedChipIndex == sender.tag {
            selectedChipIndex = nil
        } else {
            selectedChipIndex = sender.tag
        }
        rebuildChipViews()
        window?.makeFirstResponder(textField)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        if bounds.width != lastLayoutWidth {
            lastLayoutWidth = bounds.width
            rebuildChipViews()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            hideSuggestions()
        }
        super.viewWillMove(toWindow: newWindow)
    }
}

// MARK: - Suggestion Dropdown

// Associated object keys for extension storage
private enum AssociatedKeys {
    static var suggestionWindowKey: UInt8 = 0
    static var suggestionTableKey: UInt8 = 0
    static var filteredFlagsKey: UInt8 = 0
    static var selectedSuggestionRowKey: UInt8 = 0
    static var enumChoicesKey: UInt8 = 0
    static var fuseInstanceKey: UInt8 = 0
}

extension ClaudeArgsField: NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - Associated Object Accessors

    private var fuse: Fuse {
        if let existing = objc_getAssociatedObject(self, &AssociatedKeys.fuseInstanceKey) as? Fuse {
            return existing
        }
        let instance = Fuse(threshold: 0.4)
        objc_setAssociatedObject(self, &AssociatedKeys.fuseInstanceKey, instance, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return instance
    }

    private var suggestionWindow: NSWindow {
        if let existing = objc_getAssociatedObject(self, &AssociatedKeys.suggestionWindowKey) as? NSWindow {
            return existing
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating

        let effect = NSVisualEffectView(frame: win.contentView!.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 6
        effect.layer?.masksToBounds = true
        win.contentView?.addSubview(effect)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Flag"))
        column.title = ""
        column.resizingMask = .autoresizingMask

        let table = NSTableView()
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 36
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView(frame: effect.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        effect.addSubview(scroll)

        objc_setAssociatedObject(self, &AssociatedKeys.suggestionWindowKey, win, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(self, &AssociatedKeys.suggestionTableKey, table, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return win
    }

    private var suggestionTable: NSTableView? {
        objc_getAssociatedObject(self, &AssociatedKeys.suggestionTableKey) as? NSTableView
    }

    private var filteredFlags: [ClaudeFlag] {
        get {
            (objc_getAssociatedObject(self, &AssociatedKeys.filteredFlagsKey) as? [ClaudeFlag]) ?? []
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.filteredFlagsKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    private var selectedSuggestionRow: Int {
        get {
            (objc_getAssociatedObject(self, &AssociatedKeys.selectedSuggestionRowKey) as? Int) ?? -1
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.selectedSuggestionRowKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// Enum choices being shown (when user selected an enumeration flag).
    private var enumChoices: [String] {
        get {
            (objc_getAssociatedObject(self, &AssociatedKeys.enumChoicesKey) as? [String]) ?? []
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.enumChoicesKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        // Clear chip selection when typing
        if selectedChipIndex != nil {
            selectedChipIndex = nil
            rebuildChipViews()
        }

        let text = textField.stringValue

        // If we have a pending flag, don't show flag suggestions
        if let flag = pendingFlag {
            if case .enumeration(let values) = flag.valueType {
                // Filter enum choices by typed text
                if text.isEmpty {
                    showEnumChoices(values, for: flag)
                } else {
                    let filtered = values.filter {
                        $0.localizedCaseInsensitiveContains(text)
                    }
                    if filtered.isEmpty {
                        hideSuggestions()
                    } else {
                        enumChoices = filtered
                        filteredFlags = [] // Not showing flags
                        suggestionTable?.reloadData()
                        selectedSuggestionRow = 0
                        suggestionTable?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                        showSuggestions()
                    }
                }
            } else {
                hideSuggestions()
            }
            return
        }

        guard !text.isEmpty else {
            hideSuggestions()
            return
        }

        // Strip leading dashes for matching
        let query = text.replacingOccurrences(of: #"^-{0,2}"#, with: "", options: .regularExpression)
        guard !query.isEmpty else {
            // Show all flags if user just typed "--"
            let allFlags = ClaudeCLIFlags.shared.flags.filter { flag in
                !chips.contains(where: { $0.flag == flag.longName })
            }
            if allFlags.isEmpty {
                hideSuggestions()
            } else {
                enumChoices = []
                filteredFlags = allFlags
                suggestionTable?.reloadData()
                selectedSuggestionRow = 0
                suggestionTable?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                showSuggestions()
            }
            return
        }

        // Fuzzy match against available flags
        let addedFlagNames = Set(chips.map(\.flag))
        var scored: [(flag: ClaudeFlag, score: Double)] = []

        for flag in ClaudeCLIFlags.shared.flags {
            // Skip already-added flags
            if addedFlagNames.contains(flag.longName) { continue }

            // Strip -- from flag name for matching
            let flagName = flag.longName.replacingOccurrences(of: #"^--"#, with: "", options: .regularExpression)

            // Try fuzzy match
            let fuseResult = fuse.search(query, in: flagName)
            let descResult = fuse.search(query, in: flag.description)

            // Also try substring match as fallback
            let substringMatch = flagName.localizedCaseInsensitiveContains(query)

            if let score = [fuseResult?.score, descResult?.score].compactMap({ $0 }).min() {
                scored.append((flag, score))
            } else if substringMatch {
                scored.append((flag, 0.5))
            }
        }

        // Sort by score (lower is better)
        scored.sort { $0.score < $1.score }

        let results = scored.map(\.flag)

        if results.isEmpty {
            hideSuggestions()
        } else {
            enumChoices = []
            filteredFlags = results
            suggestionTable?.reloadData()
            selectedSuggestionRow = 0
            suggestionTable?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            showSuggestions()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let isVisible = suggestionWindow.isVisible

        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            guard isVisible else { return false }
            let count = enumChoices.isEmpty ? filteredFlags.count : enumChoices.count
            guard count > 0 else { return false }
            var row = selectedSuggestionRow - 1
            if row < 0 { row = count - 1 }
            selectedSuggestionRow = row
            suggestionTable?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            suggestionTable?.scrollRowToVisible(row)
            return true
        }

        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            guard isVisible else { return false }
            let count = enumChoices.isEmpty ? filteredFlags.count : enumChoices.count
            guard count > 0 else { return false }
            var row = selectedSuggestionRow + 1
            if row >= count { row = 0 }
            selectedSuggestionRow = row
            suggestionTable?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            suggestionTable?.scrollRowToVisible(row)
            return true
        }

        if commandSelector == #selector(NSResponder.insertTab(_:)) ||
            commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if pendingFlag != nil {
                commitPendingFlag()
                return true
            }
            if isVisible && !filteredFlags.isEmpty {
                let row = max(0, selectedSuggestionRow)
                if row < filteredFlags.count {
                    acceptSuggestion(filteredFlags[row])
                }
                return true
            }
            // If text starts with "--" and no suggestions, accept as unknown flag
            let text = textField.stringValue.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("-") && !text.isEmpty {
                acceptUnknownFlag(text)
                return true
            }
            return false
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if pendingFlag != nil {
                pendingFlag = nil
                textField.stringValue = ""
                textField.placeholderString = chips.isEmpty ? "Type a flag name..." : ""
                hideSuggestions()
                return true
            }
            if isVisible {
                hideSuggestions()
                return true
            }
            return false
        }

        if commandSelector == #selector(NSResponder.deleteForward(_:)) {
            if textField.stringValue.isEmpty, let idx = selectedChipIndex {
                removeChip(at: idx)
                return true
            }
            return false
        }

        if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
            if textField.stringValue.isEmpty {
                if let idx = selectedChipIndex {
                    removeChip(at: idx)
                    return true
                }
                if pendingFlag != nil {
                    pendingFlag = nil
                    textField.placeholderString = chips.isEmpty ? "Type a flag name..." : ""
                    hideSuggestions()
                    return true
                }
                if !chips.isEmpty {
                    selectedChipIndex = chips.count - 1
                    rebuildChipViews()
                    return true
                }
            }
            return false
        }

        return false
    }

    // MARK: - Flag Acceptance

    private func acceptSuggestion(_ flag: ClaudeFlag) {
        hideSuggestions()
        textField.stringValue = ""

        switch flag.valueType {
        case .boolean:
            addChip(ArgsChip(flag: flag.longName, value: nil))

        case .enumeration(let values):
            pendingFlag = flag
            textField.stringValue = ""
            showEnumChoices(values, for: flag)

        case .freeText:
            pendingFlag = flag
            textField.stringValue = ""
            textField.placeholderString = flag.valuePlaceholder ?? "<value>"
        }
    }

    private func showEnumChoices(_ values: [String], for flag: ClaudeFlag) {
        enumChoices = values
        filteredFlags = [] // Not showing flags
        suggestionTable?.reloadData()
        selectedSuggestionRow = 0
        suggestionTable?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showSuggestions()
        textField.placeholderString = "Choose \(flag.longName) value..."
    }

    private func commitPendingFlag() {
        guard let flag = pendingFlag else { return }

        let value: String?

        if !enumChoices.isEmpty {
            // Use selected enum choice
            let row = max(0, selectedSuggestionRow)
            if row < enumChoices.count {
                value = enumChoices[row]
            } else {
                value = enumChoices.first
            }
        } else {
            // Use typed text for freeText
            let text = textField.stringValue.trimmingCharacters(in: .whitespaces)
            value = text.isEmpty ? nil : text
        }

        if let value {
            addChip(ArgsChip(flag: flag.longName, value: value))
        } else {
            // No value provided — add flag without value
            addChip(ArgsChip(flag: flag.longName, value: nil))
        }

        pendingFlag = nil
        enumChoices = []
        textField.stringValue = ""
        textField.placeholderString = ""
        hideSuggestions()
    }

    private func acceptUnknownFlag(_ text: String) {
        hideSuggestions()
        textField.stringValue = ""
        addChip(ArgsChip(flag: text, value: nil))
    }

    // MARK: - Suggestion Window Positioning

    private func showSuggestions() {
        guard let parentWindow = window else { return }

        let fieldRect = textField.convert(textField.bounds, to: nil)
        let screenRect = parentWindow.convertToScreen(fieldRect)

        let count = enumChoices.isEmpty ? filteredFlags.count : enumChoices.count
        let rowHeight: CGFloat = 36
        let maxVisible = 6
        let height = min(CGFloat(count), CGFloat(maxVisible)) * rowHeight + 4
        let width = max(bounds.width, 280)

        let winFrame = NSRect(
            x: screenRect.origin.x,
            y: screenRect.origin.y - height - 2,
            width: width,
            height: height
        )
        suggestionWindow.setFrame(winFrame, display: true)

        // Resize the table column to fill the window width.
        if let table = suggestionTable, let col = table.tableColumns.first {
            col.width = width
        }

        if suggestionWindow.parent != parentWindow {
            parentWindow.addChildWindow(suggestionWindow, ordered: .above)
        }
        suggestionWindow.orderFront(nil)
    }

    private func hideSuggestions() {
        guard let win = objc_getAssociatedObject(self, &AssociatedKeys.suggestionWindowKey) as? NSWindow else {
            return
        }
        win.parent?.removeChildWindow(win)
        win.orderOut(nil)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        if !enumChoices.isEmpty {
            return enumChoices.count
        }
        return filteredFlags.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cellID = NSUserInterfaceItemIdentifier("SuggestionCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID

            let titleField = NSTextField(labelWithString: "")
            titleField.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
            titleField.tag = 100
            titleField.lineBreakMode = .byTruncatingTail
            titleField.translatesAutoresizingMaskIntoConstraints = false
            titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let descField = NSTextField(labelWithString: "")
            descField.font = .systemFont(ofSize: 10)
            descField.textColor = .secondaryLabelColor
            descField.tag = 200
            descField.lineBreakMode = .byTruncatingTail
            descField.translatesAutoresizingMaskIntoConstraints = false
            descField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            cell.addSubview(titleField)
            cell.addSubview(descField)
            NSLayoutConstraint.activate([
                titleField.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
                titleField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                titleField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                descField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1),
                descField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                descField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            ])
        }

        let titleField = cell.viewWithTag(100) as? NSTextField
        let descField = cell.viewWithTag(200) as? NSTextField

        if !enumChoices.isEmpty {
            // Showing enum choices
            guard row < enumChoices.count else { return cell }
            let choice = enumChoices[row]
            titleField?.stringValue = choice
            titleField?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            descField?.stringValue = ""
            descField?.isHidden = true
        } else {
            // Showing flag suggestions
            guard row < filteredFlags.count else { return cell }
            let flag = filteredFlags[row]
            var title = flag.longName
            if let short = flag.shortName {
                title += " (\(short))"
            }
            if let placeholder = flag.valuePlaceholder {
                title += " \(placeholder)"
            }
            titleField?.stringValue = title
            titleField?.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
            descField?.stringValue = flag.description
            descField?.isHidden = false
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = suggestionTable else { return }
        let row = table.selectedRow
        if row >= 0 {
            selectedSuggestionRow = row
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        true
    }
}
