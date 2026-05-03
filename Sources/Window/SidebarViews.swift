import AppKit

// MARK: - VerticalTabRowView

class VerticalTabRowView: NSView, NSTextFieldDelegate, NSDraggingSource {
    var title: String {
        didSet { label.stringValue = title }
    }
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }
    /// Badge info for each Claude tab in this workspace, shown as right-aligned dots.
    var badgeInfos: [(state: TabItem.BadgeState, name: String, activity: ProcessMonitor.ActivityInfo?)] = [] {
        didSet { updateBadgeDots() }
    }
    var onRename: ((String) -> Void)?
    var onClearName: (() -> Void)?
    var onReorder: ((Int, Int) -> Void)?
    var onContextMenu: ((NSEvent) -> NSMenu?)?
    let index: Int
    private let label: NSTextField
    private let badgeContainer: NSStackView
    private let shortcutOverlay: NSTextField
    private weak var target: AnyObject?
    private let action: Selector
    private var dragStartPoint: NSPoint?
    private var leadingConstraint: NSLayoutConstraint?

    /// Leading indent (used for workspaces inside groups).
    var indent: CGFloat = 0 {
        didSet { leadingConstraint?.constant = 8 + indent }
    }

    /// Show a shortcut number over the badge dots, or restore dots when nil.
    var shortcutBadge: String? {
        didSet {
            if let badge = shortcutBadge {
                shortcutOverlay.stringValue = badge
                shortcutOverlay.isHidden = false
                badgeContainer.alphaValue = 0
            } else {
                shortcutOverlay.isHidden = true
                badgeContainer.alphaValue = 1
            }
        }
    }

    init(title: String, bold: Bool, index: Int, target: AnyObject, action: Selector) {
        self.title = title
        self.index = index
        self.target = target
        self.action = action

        label = NSTextField(labelWithString: title)
        label.font = bold ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        label.textColor = ThemeManager.shared.currentColors.primaryText
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        badgeContainer = NSStackView()
        badgeContainer.orientation = .horizontal
        badgeContainer.spacing = 3
        badgeContainer.setContentHuggingPriority(.required, for: .horizontal)

        shortcutOverlay = NSTextField(labelWithString: "")
        shortcutOverlay.font = .systemFont(ofSize: 10)
        shortcutOverlay.textColor = .white
        shortcutOverlay.isHidden = true

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.toolTip = shortcutTooltip("Close Workspace", for: .closeWorkspace)
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        shortcutOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(badgeContainer)
        addSubview(shortcutOverlay)

        let lc = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        self.leadingConstraint = lc

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            lc,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badgeContainer.leadingAnchor, constant: -4),
            badgeContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badgeContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutOverlay.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            shortcutOverlay.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            ThemeManager.shared.currentColors.selectedBackground.setFill()
            bounds.fill()
        }
    }


    private func updateBadgeDots() {
        badgeContainer.arrangedSubviews.forEach {
            $0.layer?.removeAllAnimations()
            $0.removeFromSuperview()
        }
        for info in badgeInfos where info.state != .none {
            let dot = BadgeShapeView(
                shape: Self.shapeForBadge(info.state),
                color: Self.colorForBadge(info.state)
            )
            dot.toolTip = "\(info.name): \(Self.tooltipForBadge(info.state, activity: info.activity))"
            if SettingsWindowController.isBadgeAnimated(info.state) {
                Self.addPulseAnimation(to: dot)
            }
            badgeContainer.addArrangedSubview(dot)
        }
        // Re-assert: if shortcut overlay is active, keep dots invisible
        if shortcutBadge != nil {
            badgeContainer.alphaValue = 0
        }
    }

    static func addPulseAnimation(to view: NSView) {
        if let badgeView = view as? BadgeShapeView {
            badgeView.setPulseAnimationEnabled(true)
            return
        }
        guard let layer = view.layer else { return }
        layer.add(BadgeShapeView.makePulseAnimation(), forKey: BadgeShapeView.pulseAnimationKey)
    }

    static func tooltipForBadge(_ state: TabItem.BadgeState, activity: ProcessMonitor.ActivityInfo? = nil) -> String {
        switch state {
        case .none: return ""
        case .idle: return "Idle"
        case .thinking: return "Thinking..."
        case .waitingForInput: return "Waiting for input"
        case .needsPermission: return "Needs permission"
        case .error: return "Error"
        case .codexIdle: return "Codex idle"
        case .codexThinking: return "Codex working..."
        case .codexError: return "Codex error"
        case .codexCompletedUnseen: return "Codex done (unvisited)"
        case .terminalIdle: return "Idle"
        case .terminalActive: return activity?.description ?? "Running"
        case .terminalError: return "Error"
        case .completedUnseen: return "Done (unvisited)"
        case .terminalCompletedUnseen: return "Done (unvisited)"
        }
    }

    static let defaultBadgeColors: [TabItem.BadgeState: NSColor] = [
        .idle: .systemGray,
        .thinking: NSColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 1.0),
        .waitingForInput: NSColor(red: 0.65, green: 0.4, blue: 0.9, alpha: 1.0),
        .needsPermission: .systemOrange,
        .error: .systemRed,
        .codexIdle: NSColor(red: 0.26, green: 0.58, blue: 0.42, alpha: 1.0),
        .codexThinking: NSColor(red: 0.18, green: 0.76, blue: 0.48, alpha: 1.0),
        .codexError: .systemRed,
        .codexCompletedUnseen: NSColor(red: 0.10, green: 0.84, blue: 0.66, alpha: 1.0),
        .terminalIdle: NSColor(red: 0.35, green: 0.55, blue: 0.54, alpha: 1.0),
        .terminalActive: NSColor(red: 0.45, green: 0.72, blue: 0.71, alpha: 1.0),
        .terminalError: NSColor(red: 0.85, green: 0.3, blue: 0.3, alpha: 1.0),
        .completedUnseen: NSColor(red: 0.95, green: 0.4, blue: 0.7, alpha: 1.0),
        .terminalCompletedUnseen: NSColor(red: 0.3, green: 0.75, blue: 0.73, alpha: 1.0),
    ]

    static func colorForBadge(_ state: TabItem.BadgeState) -> NSColor {
        if state == .none { return .clear }
        if let hex = UserDefaults.standard.string(forKey: "badgeColor.\(state.rawValue)"),
           let color = NSColor.fromHex(hex) {
            return color
        }
        return defaultBadgeColors[state] ?? .systemGray
    }

    static let defaultBadgeShapes: [TabItem.BadgeState: TabItem.BadgeShape] = [:]

    static func shapeForBadge(_ state: TabItem.BadgeState) -> TabItem.BadgeShape {
        if let raw = UserDefaults.standard.string(forKey: "badgeShape.\(state.rawValue)"),
           let shape = TabItem.BadgeShape(rawValue: raw) {
            return shape
        }
        return defaultBadgeShapes[state] ?? .circle
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            startEditing()
        } else {
            dragStartPoint = convert(event.locationInWindow, from: nil)
            _ = target?.perform(action, with: self)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = onContextMenu?(event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        let distance = abs(current.y - start.y)
        guard distance > 5 else { return }

        dragStartPoint = nil

        let pb = NSPasteboardItem()
        pb.setString("\(index)", forType: deckardWorkspaceDragType)
        let item = NSDraggingItem(pasteboardWriter: pb)
        item.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }


    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            layer?.render(in: ctx)
        }
        image.unlockFocus()
        return image
    }

    /// True while the workspace name text field is being edited.
    var isEditingName: Bool { label.isEditable }

    private func startEditing() {
        label.isEditable = true
        label.isSelectable = true
        label.focusRingType = .none
        label.delegate = self
        label.becomeFirstResponder()
        label.currentEditor()?.selectAll(nil)
    }

    private func finishEditing() {
        label.isEditable = false
        label.isSelectable = false
        let newName = label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if newName.isEmpty {
            // Reset to default name
            onClearName?()
        } else if newName != title {
            title = newName
            onRename?(newName)
        } else {
            label.stringValue = title
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finishEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            finishEditing()
            window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            label.stringValue = title
            label.isEditable = false
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}

// MARK: - SidebarGroupView

/// A group header row in the sidebar with disclosure triangle and name.
class SidebarGroupView: NSView, NSTextFieldDelegate, NSDraggingSource {
    let group: SidebarGroup
    private let disclosureImageView: NSImageView
    private let label: NSTextField
    private let badgeContainer: NSStackView

    var onToggle: ((SidebarGroupView) -> Void)?
    var onRename: ((String) -> Void)?
    var onContextMenu: ((NSEvent) -> NSMenu?)?
    var onDrop: ((SidebarGroupView, Int) -> Void)?  // group, workspace index

    /// Row index in the sidebar stack view (set during rebuildSidebar).
    var rowIndex: Int = 0
    private var dragStartPoint: NSPoint?
    private var didDrag = false

    /// Highlight when a dragged item hovers over this group.
    var isDropTarget: Bool = false {
        didSet { needsDisplay = true }
    }

    /// Badge info aggregated from all workspaces in the group.
    var badgeInfos: [(state: TabItem.BadgeState, name: String, activity: ProcessMonitor.ActivityInfo?)] = [] {
        didSet { updateBadgeDots() }
    }

    /// True when the group is collapsed and contains the selected workspace.
    var isContainingSelected: Bool = false {
        didSet { needsDisplay = true }
    }

    init(group: SidebarGroup, workspaceCount: Int) {
        self.group = group

        disclosureImageView = NSImageView()
        disclosureImageView.image = NSImage(systemSymbolName: group.isCollapsed ? "chevron.right" : "chevron.down",
                                            accessibilityDescription: "Toggle group")
        disclosureImageView.contentTintColor = ThemeManager.shared.currentColors.secondaryText
        disclosureImageView.imageAlignment = .alignCenter

        label = NSTextField(labelWithString: group.name)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = ThemeManager.shared.currentColors.secondaryText
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        badgeContainer = NSStackView()
        badgeContainer.orientation = .horizontal
        badgeContainer.spacing = 3
        badgeContainer.setContentHuggingPriority(.required, for: .horizontal)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        disclosureImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(disclosureImageView)

        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeContainer)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            disclosureImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            disclosureImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureImageView.widthAnchor.constraint(equalToConstant: 24),
            disclosureImageView.heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: disclosureImageView.trailingAnchor, constant: 0),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badgeContainer.leadingAnchor, constant: -4),
            badgeContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badgeContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // While editing the group name, let the field editor handle events normally.
        // Otherwise, always route clicks to self so subviews (image, label) don't swallow them.
        if isEditingName { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        if isDropTarget {
            NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 4, yRadius: 4).fill()
        } else if isContainingSelected {
            ThemeManager.shared.currentColors.selectedBackground.withAlphaComponent(0.5).setFill()
            bounds.fill()
        }
    }

    func updateChevron() {
        disclosureImageView.image = NSImage(systemSymbolName: group.isCollapsed ? "chevron.right" : "chevron.down",
                                            accessibilityDescription: "Toggle group")
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if localPoint.x <= 26 {
            // Chevron area — always toggle, even on rapid clicks.
            // Don't set dragStartPoint so mouseUp won't double-toggle.
            onToggle?(self)
        } else if event.clickCount == 2 {
            startEditing()
        } else {
            dragStartPoint = localPoint
            didDrag = false
        }
    }

    override func mouseUp(with event: NSEvent) {
        // Toggle on mouseUp for non-chevron clicks (supports drag detection)
        if !didDrag && dragStartPoint != nil {
            onToggle?(self)
        }
        dragStartPoint = nil
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        let distance = abs(current.y - start.y)
        guard distance > 5 else { return }

        didDrag = true
        dragStartPoint = nil

        let pb = NSPasteboardItem()
        pb.setString("\(rowIndex)", forType: deckardGroupDragType)
        let item = NSDraggingItem(pasteboardWriter: pb)
        item.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }

    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            layer?.render(in: ctx)
        }
        image.unlockFocus()
        return image
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = onContextMenu?(event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    /// True while the group name text field is being edited.
    var isEditingName: Bool { label.isEditable }

    func startEditing() {
        label.isEditable = true
        label.isSelectable = true
        label.focusRingType = .none
        label.delegate = self
        label.becomeFirstResponder()
        label.currentEditor()?.selectAll(nil)
    }

    private func finishEditing() {
        label.isEditable = false
        label.isSelectable = false
        let newName = label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newName.isEmpty, newName != group.name {
            group.name = newName
            onRename?(newName)
        } else {
            label.stringValue = group.name
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finishEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(insertNewline(_:)) {
            finishEditing()
            window?.makeFirstResponder(nil)
            return true
        }
        if sel == #selector(cancelOperation(_:)) {
            label.stringValue = group.name
            label.isEditable = false
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    private func updateBadgeDots() {
        badgeContainer.arrangedSubviews.forEach {
            $0.layer?.removeAllAnimations()
            $0.removeFromSuperview()
        }
        // When collapsed, show aggregated badges; when expanded, hide them
        // (individual workspace rows show their own badges)
        guard group.isCollapsed else { return }
        for info in badgeInfos where info.state != .none {
            let dot = BadgeShapeView(
                shape: VerticalTabRowView.shapeForBadge(info.state),
                color: VerticalTabRowView.colorForBadge(info.state)
            )
            dot.toolTip = "\(info.name): \(VerticalTabRowView.tooltipForBadge(info.state, activity: info.activity))"
            if SettingsWindowController.isBadgeAnimated(info.state) {
                VerticalTabRowView.addPulseAnimation(to: dot)
            }
            badgeContainer.addArrangedSubview(dot)
        }
    }
}

// MARK: - SidebarDropZone

/// Covers the empty area below the workspace list; dropping here moves to end.
class SidebarDropZone: NSView {
    var onDrop: ((Int) -> Void)?
    var onGroupDrop: ((Int) -> Void)?  // group row index dropped to bottom
    var onContextMenu: ((NSEvent) -> NSMenu?)?
    weak var sidebarStackView: ReorderableStackView?

    override func rightMouseDown(with event: NSEvent) {
        if let menu = onContextMenu?(event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    private func acceptsDrag(_ sender: NSDraggingInfo) -> Bool {
        let types = sender.draggingPasteboard.types ?? []
        return types.contains(deckardWorkspaceDragType) || types.contains(deckardGroupDragType)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrag(sender) else { return [] }
        sidebarStackView?.showIndicatorAtEnd()
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrag(sender) else { return [] }
        sidebarStackView?.showIndicatorAtEnd()
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        sidebarStackView?.hideIndicator()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        sidebarStackView?.hideIndicator()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sidebarStackView?.hideIndicator()
        if let fromStr = sender.draggingPasteboard.string(forType: deckardWorkspaceDragType),
           let fromIndex = Int(fromStr) {
            onDrop?(fromIndex)
            return true
        }
        if let fromStr = sender.draggingPasteboard.string(forType: deckardGroupDragType),
           let fromRow = Int(fromStr) {
            onGroupDrop?(fromRow)
            return true
        }
        return false
    }
}

// MARK: - ReorderableStackView

/// NSStackView subclass that accepts drops for reordering.
/// Supports workspace drag (reorder/drop onto group) and group drag (reorder groups).
class ReorderableStackView: NSStackView {
    var onReorder: ((Int, Int, Bool) -> Void)?
    var onDropOntoGroup: ((SidebarGroupView, Int) -> Void)?
    var onGroupReorder: ((Int, Int) -> Void)?

    private let dropIndicator: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = ThemeManager.shared.currentColors.foreground.withAlphaComponent(0.4).cgColor
        v.isHidden = true
        return v
    }()
    private var currentDropIndex: Int = -1
    private var currentDropForceFullWidth: Bool = false
    private weak var highlightedGroup: SidebarGroupView?

    private func dropIndex(for sender: NSDraggingInfo) -> Int {
        let location = convert(sender.draggingLocation, from: nil)
        for (i, view) in arrangedSubviews.enumerated() {
            if location.y > view.frame.midY {
                return i
            }
        }
        return arrangedSubviews.count
    }

    /// Returns the SidebarGroupView at the drag location, if the cursor is
    /// within the center region of a group row. The top and bottom edges
    /// (6px each) are reserved for between-item line indicator drops.
    private func groupView(at sender: NSDraggingInfo) -> SidebarGroupView? {
        let location = convert(sender.draggingLocation, from: nil)
        let edgeInset: CGFloat = 6
        for view in arrangedSubviews {
            guard let fv = view as? SidebarGroupView else { continue }
            let innerTop = fv.frame.maxY - edgeInset
            let innerBottom = fv.frame.minY + edgeInset
            if location.y <= innerTop && location.y >= innerBottom {
                return fv
            }
        }
        return nil
    }

    private func clearGroupHighlight() {
        if let prev = highlightedGroup {
            prev.isDropTarget = false
            highlightedGroup = nil
        }
    }

    private func showIndicator(at index: Int, forceFullWidth: Bool = false) {
        guard index != currentDropIndex || forceFullWidth != currentDropForceFullWidth else { return }
        currentDropIndex = index
        currentDropForceFullWidth = forceFullWidth

        // Use frame-based positioning (no autolayout) for simplicity
        if dropIndicator.superview !== self {
            dropIndicator.removeFromSuperview()
            addSubview(dropIndicator)
        }
        dropIndicator.isHidden = false

        let yPos: CGFloat
        if index < arrangedSubviews.count {
            yPos = arrangedSubviews[index].frame.maxY - 1
        } else if let last = arrangedSubviews.last {
            yPos = last.frame.minY - 1
        } else {
            yPos = bounds.maxY - 1
        }

        // Indent the indicator when between items inside a group (workspace drags only)
        let leftInset: CGFloat
        if forceFullWidth {
            leftInset = 8
        } else if index < arrangedSubviews.count,
           let row = arrangedSubviews[index] as? VerticalTabRowView, row.indent > 0 {
            leftInset = 24
        } else if index > 0, index - 1 < arrangedSubviews.count,
                  let prevRow = arrangedSubviews[index - 1] as? VerticalTabRowView, prevRow.indent > 0 {
            leftInset = 24
        } else {
            leftInset = 8
        }
        dropIndicator.frame = NSRect(x: leftInset, y: yPos, width: bounds.width - leftInset - 8, height: 2)
    }

    func showIndicatorAtEnd() {
        showIndicator(at: arrangedSubviews.count, forceFullWidth: true)
    }

    func hideIndicator() {
        dropIndicator.isHidden = true
        currentDropIndex = -1
        currentDropForceFullWidth = false
        clearGroupHighlight()
    }

    private func acceptsWorkspaceDrag(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.types?.contains(deckardWorkspaceDragType) == true
    }

    private func acceptsGroupDrag(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.types?.contains(deckardGroupDragType) == true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if acceptsWorkspaceDrag(sender) {
            return updateWorkspaceDrag(sender)
        } else if acceptsGroupDrag(sender) {
            return updateGroupDrag(sender)
        }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if acceptsWorkspaceDrag(sender) {
            return updateWorkspaceDrag(sender)
        } else if acceptsGroupDrag(sender) {
            return updateGroupDrag(sender)
        }
        return []
    }

    /// Group drag: only show indicator between top-level items (not inside groups).
    private func updateGroupDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        let snapped = snapToTopLevel(for: sender)
        showIndicator(at: snapped, forceFullWidth: true)
        return .move
    }

    /// Snap drop position to the nearest top-level boundary.
    /// Indented rows (inside groups) are skipped — the indicator jumps to
    /// the group header above or the next top-level item below.
    private func snapToTopLevel(for sender: NSDraggingInfo) -> Int {
        let raw = dropIndex(for: sender)
        // If dropping at a top-level position, use it directly
        if raw < arrangedSubviews.count {
            let view = arrangedSubviews[raw]
            let isIndented = (view as? VerticalTabRowView)?.indent ?? 0 > 0
            if !isIndented { return raw }
        }
        // Find the nearest top-level row above
        var best = raw
        for i in stride(from: raw - 1, through: 0, by: -1) {
            let view = arrangedSubviews[i]
            let isIndented = (view as? VerticalTabRowView)?.indent ?? 0 > 0
            if !isIndented {
                // Snap to just after this top-level item's group
                // (after the group + all its children)
                best = i
                // Find end of this group's children
                if view is SidebarGroupView {
                    var end = i + 1
                    while end < arrangedSubviews.count,
                          let r = arrangedSubviews[end] as? VerticalTabRowView, r.indent > 0 {
                        end += 1
                    }
                    best = end
                }
                break
            }
        }
        return best
    }

    /// Common logic for workspace drag: highlight group or show line indicator.
    private func updateWorkspaceDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let fv = groupView(at: sender) {
            // Hovering over a group row — highlight it, hide the line indicator
            dropIndicator.isHidden = true
            currentDropIndex = -1
            if highlightedGroup !== fv {
                clearGroupHighlight()
                fv.isDropTarget = true
                highlightedGroup = fv
            }
        } else {
            // Not over a group — show the line indicator
            clearGroupHighlight()
            let idx = dropIndex(for: sender)
            // At the boundary between the last child of an expanded group
            // and the next non-indented row, use cursor Y to disambiguate:
            // upper half (group child territory) → indented indicator,
            // lower half (top-level territory) → full-width indicator.
            var forceFullWidth = false
            if idx > 0, idx < arrangedSubviews.count {
                let prevIndented = (arrangedSubviews[idx - 1] as? VerticalTabRowView)?.indent ?? 0 > 0
                let currIndented = (arrangedSubviews[idx] as? VerticalTabRowView)?.indent ?? 0 > 0
                if prevIndented && !currIndented {
                    let location = convert(sender.draggingLocation, from: nil)
                    forceFullWidth = location.y <= arrangedSubviews[idx].frame.maxY
                }
            }
            showIndicator(at: idx, forceFullWidth: forceFullWidth)
        }
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideIndicator()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        hideIndicator()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let wasOnGroup = highlightedGroup
        let wasForceFullWidth = currentDropForceFullWidth
        hideIndicator()

        // Handle workspace drag
        if let fromStr = sender.draggingPasteboard.string(forType: deckardWorkspaceDragType),
           let fromIndex = Int(fromStr) {
            // If dropped on a highlighted group, route to group drop handler
            if let fv = wasOnGroup {
                onDropOntoGroup?(fv, fromIndex)
                return true
            }
            let toIndex = dropIndex(for: sender)
            onReorder?(fromIndex, toIndex, wasForceFullWidth)
            return true
        }

        // Handle group drag
        if let fromStr = sender.draggingPasteboard.string(forType: deckardGroupDragType),
           let fromRow = Int(fromStr) {
            let toRow = dropIndex(for: sender)
            if toRow != fromRow {
                onGroupReorder?(fromRow, toRow)
            }
            return true
        }

        return false
    }
}

// MARK: - AddTabButton

/// + button: left-click adds Claude tab; modifiers/context menu expose other tab types.
class AddTabButton: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    private let claudeAction: () -> Void
    private let codexAction: () -> Void
    private let terminalAction: () -> Void
    private let label: NSTextField

    init(claudeAction: @escaping () -> Void, codexAction: @escaping () -> Void, terminalAction: @escaping () -> Void) {
        self.claudeAction = claudeAction
        self.codexAction = codexAction
        self.terminalAction = terminalAction
        label = NSTextField(labelWithString: "  +")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = ThemeManager.shared.currentColors.secondaryText
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = shortcutTooltip("New Claude tab", for: .newClaudeTab)
            + "\nOption-click: " + shortcutTooltip("new Codex", for: .newCodexTab)
            + "\nShift-click: " + shortcutTooltip("new Terminal", for: .newTerminalTab)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            codexAction()
        } else if event.modifierFlags.contains(.shift) {
            terminalAction()
        } else {
            claudeAction()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let claudeItem = NSMenuItem(title: "New Claude Tab", action: #selector(newClaudeAction), keyEquivalent: "")
        claudeItem.setShortcut(for: .newClaudeTab)
        claudeItem.target = self
        menu.addItem(claudeItem)

        let codexItem = NSMenuItem(title: "New Codex Tab", action: #selector(newCodexAction), keyEquivalent: "")
        codexItem.setShortcut(for: .newCodexTab)
        codexItem.target = self
        menu.addItem(codexItem)

        let terminalItem = NSMenuItem(title: "New Terminal Tab", action: #selector(newTerminalAction), keyEquivalent: "")
        terminalItem.setShortcut(for: .newTerminalTab)
        terminalItem.target = self
        menu.addItem(terminalItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func newClaudeAction() { claudeAction() }
    @objc private func newCodexAction() { codexAction() }
    @objc private func newTerminalAction() { terminalAction() }
}

// MARK: - BadgeShapeView

/// Draws a badge dot using AppKit so the same pulse path works in both tab bars.
class BadgeShapeView: NSView {
    static let pulseAnimationKey = "pulse"

    private var shape: TabItem.BadgeShape
    private var color: NSColor
    private var isPulseAnimationEnabled = false
    private var pulseTimer: Timer?
    private var pulseStartTime: TimeInterval = 0

    init(shape: TabItem.BadgeShape, color: NSColor, size: CGFloat = 7) {
        self.shape = shape
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
        updateAppearance(shape: shape, color: color, size: size)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    deinit {
        pulseTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopPulseAnimation(resetOpacity: false)
        } else if isPulseAnimationEnabled {
            startPulseAnimation()
        }
    }

    func setPulseAnimationEnabled(_ enabled: Bool) {
        isPulseAnimationEnabled = enabled
        if enabled {
            startPulseAnimation()
        } else {
            stopPulseAnimation(resetOpacity: true)
        }
    }

    func updateAppearance(shape: TabItem.BadgeShape, color: NSColor, size: CGFloat = 7) {
        self.shape = shape
        self.color = color
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.addPath(Self.path(for: shape, in: bounds))
        context.setFillColor(color.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    private func startPulseAnimation() {
        stopPulseAnimation(resetOpacity: false)
        pulseStartTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updatePulseOpacity()
        }
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
        updatePulseOpacity()
    }

    private func stopPulseAnimation(resetOpacity: Bool) {
        pulseTimer?.invalidate()
        pulseTimer = nil
        layer?.removeAnimation(forKey: Self.pulseAnimationKey)
        if resetOpacity {
            alphaValue = 1.0
            needsDisplay = true
        }
    }

    private func updatePulseOpacity() {
        let halfCycle: TimeInterval = 1.2
        let cycle = halfCycle * 2
        let elapsed = CACurrentMediaTime() - pulseStartTime
        let position = elapsed.truncatingRemainder(dividingBy: cycle)
        let rawProgress = position <= halfCycle
            ? position / halfCycle
            : (cycle - position) / halfCycle
        let eased = 0.5 - 0.5 * cos(rawProgress * .pi)
        let opacity = Float(1.0 - (0.7 * eased))
        alphaValue = CGFloat(opacity)
        needsDisplay = true
    }

    static func makePulseAnimation() -> CABasicAnimation {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.3
        anim.duration = 1.2
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return anim
    }

    static func path(for shape: TabItem.BadgeShape, in rect: CGRect) -> CGPath {
        let w = rect.width
        let cx = rect.midX
        let cy = rect.midY

        switch shape {
        case .circle:
            return CGPath(ellipseIn: rect, transform: nil)

        case .square:
            // Inset slightly so visual weight matches the circle
            let inset: CGFloat = 0.5
            return CGPath(rect: rect.insetBy(dx: inset, dy: inset), transform: nil)

        case .diamond:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: cx, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: cy))
            path.addLine(to: CGPoint(x: cx, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: cy))
            path.closeSubpath()
            return path

        case .triangleUp:
            // AppKit: y=0 is bottom, so apex at maxY points up on screen
            let path = CGMutablePath()
            path.move(to: CGPoint(x: cx, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.closeSubpath()
            return path

        case .triangleDown:
            // AppKit: y=0 is bottom, so apex at minY points down on screen
            let path = CGMutablePath()
            path.move(to: CGPoint(x: cx, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path

        case .cross:
            let arm = w * 0.22
            let path = CGMutablePath()
            path.move(to: CGPoint(x: cx - arm, y: rect.minY))
            path.addLine(to: CGPoint(x: cx + arm, y: rect.minY))
            path.addLine(to: CGPoint(x: cx + arm, y: cy - arm))
            path.addLine(to: CGPoint(x: rect.maxX, y: cy - arm))
            path.addLine(to: CGPoint(x: rect.maxX, y: cy + arm))
            path.addLine(to: CGPoint(x: cx + arm, y: cy + arm))
            path.addLine(to: CGPoint(x: cx + arm, y: rect.maxY))
            path.addLine(to: CGPoint(x: cx - arm, y: rect.maxY))
            path.addLine(to: CGPoint(x: cx - arm, y: cy + arm))
            path.addLine(to: CGPoint(x: rect.minX, y: cy + arm))
            path.addLine(to: CGPoint(x: rect.minX, y: cy - arm))
            path.addLine(to: CGPoint(x: cx - arm, y: cy - arm))
            path.closeSubpath()
            return path

        case .xCross:
            // Same as cross but rotated 45°
            var transform = CGAffineTransform.identity
                .translatedBy(x: cx, y: cy)
                .rotated(by: .pi / 4)
                .translatedBy(x: -cx, y: -cy)
            let crossPath = Self.path(for: .cross, in: rect)
            return crossPath.copy(using: &transform) ?? crossPath

        case .hexagon:
            let path = CGMutablePath()
            let r = w / 2
            for i in 0..<6 {
                let angle = CGFloat(i) * .pi / 3 - .pi / 6  // flat-top hexagon
                let px = cx + r * cos(angle)
                let py = cy + r * sin(angle)
                if i == 0 {
                    path.move(to: CGPoint(x: px, y: py))
                } else {
                    path.addLine(to: CGPoint(x: px, y: py))
                }
            }
            path.closeSubpath()
            return path

        }
    }
}
