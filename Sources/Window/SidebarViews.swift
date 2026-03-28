import AppKit

// MARK: - VerticalTabRowView

class VerticalTabRowView: NSView, NSTextFieldDelegate, NSDraggingSource {
    var title: String {
        didSet { label.stringValue = title }
    }
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }
    /// Badge info for each Claude tab in this project, shown as right-aligned dots.
    var badgeInfos: [(state: TabItem.BadgeState, name: String, activity: ProcessMonitor.ActivityInfo?)] = [] {
        didSet { if shortcutBadge == nil { updateBadgeDots() } }
    }
    var onRename: ((String) -> Void)?
    var onClearName: (() -> Void)?
    var onReorder: ((Int, Int) -> Void)?
    var onContextMenu: ((NSEvent) -> NSMenu?)?
    let index: Int
    private let label: NSTextField
    private let badgeContainer: NSStackView
    private weak var target: AnyObject?
    private let action: Selector
    private var dragStartPoint: NSPoint?
    private var leadingConstraint: NSLayoutConstraint?

    /// Leading indent (used for projects inside folders).
    var indent: CGFloat = 0 {
        didSet { leadingConstraint?.constant = 8 + indent }
    }

    /// Replace badge dots with a shortcut number, or restore dots when nil.
    var shortcutBadge: String? {
        didSet {
            if let badge = shortcutBadge {
                badgeContainer.arrangedSubviews.forEach { $0.isHidden = true }
                if badgeContainer.viewWithTag(999) == nil {
                    let numLabel = NSTextField(labelWithString: "")
                    numLabel.tag = 999
                    numLabel.font = .systemFont(ofSize: 10)
                    numLabel.textColor = .white
                    badgeContainer.addArrangedSubview(numLabel)
                }
                (badgeContainer.viewWithTag(999) as? NSTextField)?.stringValue = badge
                badgeContainer.viewWithTag(999)?.isHidden = false
            } else {
                badgeContainer.viewWithTag(999)?.removeFromSuperview()
                badgeContainer.arrangedSubviews.forEach { $0.isHidden = false }
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

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.toolTip = shortcutTooltip("Close Folder", for: .closeFolder)
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(badgeContainer)

        let lc = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        self.leadingConstraint = lc

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            lc,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badgeContainer.leadingAnchor, constant: -4),
            badgeContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badgeContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
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
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = Self.colorForBadge(info.state).cgColor
            dot.toolTip = "\(info.name): \(Self.tooltipForBadge(info.state, activity: info.activity))"
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
            ])
            if SettingsWindowController.isBadgeAnimated(info.state) {
                Self.addPulseAnimation(to: dot)
            }
            badgeContainer.addArrangedSubview(dot)
        }
    }

    static func addPulseAnimation(to view: NSView) {
        guard let layer = view.layer else { return }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.3
        anim.duration = 1.2
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(anim, forKey: "pulse")
    }

    static func tooltipForBadge(_ state: TabItem.BadgeState, activity: ProcessMonitor.ActivityInfo? = nil) -> String {
        switch state {
        case .none: return ""
        case .idle: return "Idle"
        case .thinking: return "Thinking..."
        case .waitingForInput: return "Waiting for input"
        case .needsPermission: return "Needs permission"
        case .error: return "Error"
        case .terminalIdle: return "Idle"
        case .terminalActive: return activity?.description ?? "Running"
        case .terminalError: return "Error"
        }
    }

    static let defaultBadgeColors: [TabItem.BadgeState: NSColor] = [
        .idle: .systemGray,
        .thinking: NSColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 1.0),
        .waitingForInput: NSColor(red: 0.65, green: 0.4, blue: 0.9, alpha: 1.0),
        .needsPermission: .systemOrange,
        .error: .systemRed,
        .terminalIdle: NSColor(red: 0.35, green: 0.55, blue: 0.54, alpha: 1.0),
        .terminalActive: NSColor(red: 0.45, green: 0.72, blue: 0.71, alpha: 1.0),
        .terminalError: NSColor(red: 0.85, green: 0.3, blue: 0.3, alpha: 1.0),
    ]

    static func colorForBadge(_ state: TabItem.BadgeState) -> NSColor {
        if state == .none { return .clear }
        if let hex = UserDefaults.standard.string(forKey: "badgeColor.\(state.rawValue)"),
           let color = NSColor.fromHex(hex) {
            return color
        }
        return defaultBadgeColors[state] ?? .systemGray
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
        pb.setString("\(index)", forType: deckardProjectDragType)
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

    /// True while the project name text field is being edited.
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

// MARK: - SidebarFolderView

/// A folder header row in the sidebar with disclosure triangle and name.
class SidebarFolderView: NSView, NSTextFieldDelegate, NSDraggingSource {
    let folder: SidebarFolder
    private let disclosureImageView: NSImageView
    private let label: NSTextField
    private let badgeContainer: NSStackView

    var onToggle: ((SidebarFolderView) -> Void)?
    var onRename: ((String) -> Void)?
    var onContextMenu: ((NSEvent) -> NSMenu?)?
    var onDrop: ((SidebarFolderView, Int) -> Void)?  // folder, project index

    /// Row index in the sidebar stack view (set during rebuildSidebar).
    var rowIndex: Int = 0
    private var dragStartPoint: NSPoint?
    private var didDrag = false

    /// Highlight when a dragged item hovers over this folder.
    var isDropTarget: Bool = false {
        didSet { needsDisplay = true }
    }

    /// Badge info aggregated from all projects in the folder.
    var badgeInfos: [(state: TabItem.BadgeState, name: String, activity: ProcessMonitor.ActivityInfo?)] = [] {
        didSet { updateBadgeDots() }
    }

    /// True when the folder is collapsed and contains the selected project.
    var isContainingSelected: Bool = false {
        didSet { needsDisplay = true }
    }

    init(folder: SidebarFolder, projectCount: Int) {
        self.folder = folder

        disclosureImageView = NSImageView()
        disclosureImageView.image = NSImage(systemSymbolName: folder.isCollapsed ? "chevron.right" : "chevron.down",
                                            accessibilityDescription: "Toggle folder")
        disclosureImageView.contentTintColor = ThemeManager.shared.currentColors.secondaryText
        disclosureImageView.imageAlignment = .alignCenter

        label = NSTextField(labelWithString: folder.name)
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
        // While editing the folder name, let the field editor handle events normally.
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
        disclosureImageView.image = NSImage(systemSymbolName: folder.isCollapsed ? "chevron.right" : "chevron.down",
                                            accessibilityDescription: "Toggle folder")
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
        pb.setString("\(rowIndex)", forType: deckardFolderDragType)
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

    /// True while the folder name text field is being edited.
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
        if !newName.isEmpty, newName != folder.name {
            folder.name = newName
            onRename?(newName)
        } else {
            label.stringValue = folder.name
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
            label.stringValue = folder.name
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
        // (individual project rows show their own badges)
        guard folder.isCollapsed else { return }
        for info in badgeInfos where info.state != .none {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = VerticalTabRowView.colorForBadge(info.state).cgColor
            dot.toolTip = "\(info.name): \(VerticalTabRowView.tooltipForBadge(info.state, activity: info.activity))"
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
            ])
            if SettingsWindowController.isBadgeAnimated(info.state) {
                VerticalTabRowView.addPulseAnimation(to: dot)
            }
            badgeContainer.addArrangedSubview(dot)
        }
    }
}

// MARK: - SidebarDropZone

/// Covers the empty area below the project list; dropping here moves to end.
class SidebarDropZone: NSView {
    var onDrop: ((Int) -> Void)?
    var onFolderDrop: ((Int) -> Void)?  // folder row index dropped to bottom
    var onContextMenu: ((NSEvent) -> NSMenu?)?
    weak var sidebarStackView: ReorderableStackView?

    override func rightMouseDown(with event: NSEvent) {
        if let menu = onContextMenu?(event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    private func acceptsDrag(_ sender: NSDraggingInfo) -> Bool {
        let types = sender.draggingPasteboard.types ?? []
        return types.contains(deckardProjectDragType) || types.contains(deckardFolderDragType)
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
        if let fromStr = sender.draggingPasteboard.string(forType: deckardProjectDragType),
           let fromIndex = Int(fromStr) {
            onDrop?(fromIndex)
            return true
        }
        if let fromStr = sender.draggingPasteboard.string(forType: deckardFolderDragType),
           let fromRow = Int(fromStr) {
            onFolderDrop?(fromRow)
            return true
        }
        return false
    }
}

// MARK: - ReorderableStackView

/// NSStackView subclass that accepts drops for reordering.
/// Supports project drag (reorder/drop onto folder) and folder drag (reorder folders).
class ReorderableStackView: NSStackView {
    var onReorder: ((Int, Int) -> Void)?
    var onDropOntoFolder: ((SidebarFolderView, Int) -> Void)?
    var onFolderReorder: ((Int, Int) -> Void)?

    private let dropIndicator: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = ThemeManager.shared.currentColors.foreground.withAlphaComponent(0.4).cgColor
        v.isHidden = true
        return v
    }()
    private var currentDropIndex: Int = -1
    private weak var highlightedFolder: SidebarFolderView?

    private func dropIndex(for sender: NSDraggingInfo) -> Int {
        let location = convert(sender.draggingLocation, from: nil)
        for (i, view) in arrangedSubviews.enumerated() {
            if location.y > view.frame.midY {
                return i
            }
        }
        return arrangedSubviews.count
    }

    /// Returns the SidebarFolderView at the drag location, if the cursor is
    /// within the center region of a folder row. The top and bottom edges
    /// (6px each) are reserved for between-item line indicator drops.
    private func folderView(at sender: NSDraggingInfo) -> SidebarFolderView? {
        let location = convert(sender.draggingLocation, from: nil)
        let edgeInset: CGFloat = 6
        for view in arrangedSubviews {
            guard let fv = view as? SidebarFolderView else { continue }
            let innerTop = fv.frame.maxY - edgeInset
            let innerBottom = fv.frame.minY + edgeInset
            if location.y <= innerTop && location.y >= innerBottom {
                return fv
            }
        }
        return nil
    }

    private func clearFolderHighlight() {
        if let prev = highlightedFolder {
            prev.isDropTarget = false
            highlightedFolder = nil
        }
    }

    private func showIndicator(at index: Int, forceFullWidth: Bool = false) {
        guard index != currentDropIndex else { return }
        currentDropIndex = index

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

        // Indent the indicator when between items inside a folder (project drags only)
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
        clearFolderHighlight()
    }

    private func acceptsProjectDrag(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.types?.contains(deckardProjectDragType) == true
    }

    private func acceptsFolderDrag(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.types?.contains(deckardFolderDragType) == true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if acceptsProjectDrag(sender) {
            return updateProjectDrag(sender)
        } else if acceptsFolderDrag(sender) {
            return updateFolderDrag(sender)
        }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if acceptsProjectDrag(sender) {
            return updateProjectDrag(sender)
        } else if acceptsFolderDrag(sender) {
            return updateFolderDrag(sender)
        }
        return []
    }

    /// Folder drag: only show indicator between top-level items (not inside folders).
    private func updateFolderDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        let snapped = snapToTopLevel(for: sender)
        showIndicator(at: snapped, forceFullWidth: true)
        return .move
    }

    /// Snap drop position to the nearest top-level boundary.
    /// Indented rows (inside folders) are skipped — the indicator jumps to
    /// the folder header above or the next top-level item below.
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
                // (after the folder + all its children)
                best = i
                // Find end of this folder's children
                if view is SidebarFolderView {
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

    /// Common logic for project drag: highlight folder or show line indicator.
    private func updateProjectDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let fv = folderView(at: sender) {
            // Hovering over a folder row — highlight it, hide the line indicator
            dropIndicator.isHidden = true
            currentDropIndex = -1
            if highlightedFolder !== fv {
                clearFolderHighlight()
                fv.isDropTarget = true
                highlightedFolder = fv
            }
        } else {
            // Not over a folder — show the line indicator
            clearFolderHighlight()
            showIndicator(at: dropIndex(for: sender))
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
        let wasOnFolder = highlightedFolder
        hideIndicator()

        // Handle project drag
        if let fromStr = sender.draggingPasteboard.string(forType: deckardProjectDragType),
           let fromIndex = Int(fromStr) {
            // If dropped on a highlighted folder, route to folder drop handler
            if let fv = wasOnFolder {
                onDropOntoFolder?(fv, fromIndex)
                return true
            }
            let toIndex = dropIndex(for: sender)
            if toIndex != fromIndex {
                onReorder?(fromIndex, toIndex)
            }
            return true
        }

        // Handle folder drag
        if let fromStr = sender.draggingPasteboard.string(forType: deckardFolderDragType),
           let fromRow = Int(fromStr) {
            let toRow = dropIndex(for: sender)
            if toRow != fromRow {
                onFolderReorder?(fromRow, toRow)
            }
            return true
        }

        return false
    }
}

// MARK: - AddTabButton

/// + button: left-click adds Claude tab, right-click adds terminal tab.
class AddTabButton: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    private let leftClickAction: () -> Void
    private let rightClickAction: () -> Void
    private let label: NSTextField

    init(leftClickAction: @escaping () -> Void, rightClickAction: @escaping () -> Void) {
        self.leftClickAction = leftClickAction
        self.rightClickAction = rightClickAction
        label = NSTextField(labelWithString: "  +")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = ThemeManager.shared.currentColors.secondaryText
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = shortcutTooltip("New Claude tab", for: .newClaudeTab)
            + "\nShift-click or right-click: " + shortcutTooltip("new Terminal", for: .newTerminalTab)
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
        if event.modifierFlags.contains(.shift) {
            rightClickAction()  // Shift+click opens terminal tab
        } else {
            leftClickAction()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        rightClickAction()
    }
}
