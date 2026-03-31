import AppKit

// MARK: - HorizontalTabView

/// A single tab in the horizontal tab bar.
let deckardTabDragType = NSPasteboard.PasteboardType("com.deckard.tab-reorder")

class HorizontalTabView: NSView, NSTextFieldDelegate, NSDraggingSource {
    override var mouseDownCanMoveWindow: Bool { false }
    let index: Int
    private let label: NSTextField
    private weak var target: AnyObject?
    private let clickAction: Selector
    private var isSelected: Bool
    var onRename: ((String) -> Void)?
    var onClearName: (() -> Void)?
    var onEditingFinished: (() -> Void)?
    private var rawName: String

    private var displayTitle: String
    private var editWidthConstraint: NSLayoutConstraint?

    private var badgeDot: NSView?

    init(displayTitle: String, editableName: String, isClaude: Bool = false,
         badgeState: TabItem.BadgeState = .none,
         activity: ProcessMonitor.ActivityInfo? = nil,
         isSelected: Bool, index: Int,
         target: AnyObject, clickAction: Selector) {
        self.index = index
        self.isSelected = isSelected
        self.target = target
        self.clickAction = clickAction
        self.rawName = editableName
        self.displayTitle = displayTitle

        label = NSTextField(labelWithString: displayTitle)
        label.font = .systemFont(ofSize: 12)
        let tc = ThemeManager.shared.currentColors
        label.textColor = isSelected ? tc.primaryText : tc.secondaryText
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Badge dot — positioned on the right by layout constraints below
        if badgeState != .none {
            let dot = BadgeShapeView(
                shape: VerticalTabRowView.shapeForBadge(badgeState),
                color: VerticalTabRowView.colorForBadge(badgeState)
            )
            dot.toolTip = VerticalTabRowView.tooltipForBadge(badgeState, activity: activity)
            addSubview(dot)
            NSLayoutConstraint.activate([
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            if SettingsWindowController.isBadgeAnimated(badgeState) {
                VerticalTabRowView.addPulseAnimation(to: dot)
            }
            badgeDot = dot
        }

        label.translatesAutoresizingMaskIntoConstraints = false
        label.toolTip = shortcutTooltip("Close Tab", for: .closeTab)
        addSubview(label)

        // Layout: [label] [badge]
        var constraints = [
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]

        if let dot = badgeDot {
            constraints.append(dot.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 5))
            constraints.append(dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6))
        } else {
            constraints.append(label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6))
        }

        NSLayoutConstraint.activate(constraints)

        if isSelected {
            layer?.backgroundColor = ThemeManager.shared.currentColors.selectedBackground.cgColor
        }

    }

    required init?(coder: NSCoder) { fatalError() }

    private var dragStartPoint: NSPoint?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            startEditing()
        } else {
            dragStartPoint = convert(event.locationInWindow, from: nil)
            // Switch terminal immediately so the action isn't lost
            // if a tab bar rebuild destroys this view before mouseUp.
            (target as? DeckardWindowController)?.switchToTab(at: index)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartPoint != nil else { return }
        dragStartPoint = nil
        // Rebuild the tab bar to update the visual selection state.
        (target as? DeckardWindowController)?.rebuildTabBar()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard abs(current.x - start.x) > 5 else { return }

        dragStartPoint = nil
        let pb = NSPasteboardItem()
        pb.setString("\(index)", forType: deckardTabDragType)
        let item = NSDraggingItem(pasteboardWriter: pb)
        let snapshot = NSImage(size: bounds.size)
        snapshot.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext { layer?.render(in: ctx) }
        snapshot.unlockFocus()
        item.setDraggingFrame(bounds, contents: snapshot)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }

    private func startEditing() {
        isEditing = true
        let w = max(label.fittingSize.width + 16, 80)
        editWidthConstraint = label.widthAnchor.constraint(equalToConstant: w)
        editWidthConstraint?.isActive = true

        label.isEditable = true
        label.isSelectable = true
        label.isBezeled = false
        label.drawsBackground = false
        label.focusRingType = .none
        label.stringValue = rawName
        label.delegate = self
        label.becomeFirstResponder()
        label.currentEditor()?.selectAll(nil)
    }

    private(set) var isEditing = false

    private func finishEditing() {
        guard isEditing else { return }
        isEditing = false
        editWidthConstraint?.isActive = false
        editWidthConstraint = nil
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        let newName = label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if newName.isEmpty {
            onClearName?()  // reset to default name
        } else if newName != rawName {
            rawName = newName
            onRename?(newName)
        } else {
            label.stringValue = displayTitle
        }
        onEditingFinished?()
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
            isEditing = false
            label.stringValue = displayTitle
            label.isEditable = false
            label.isSelectable = false
            window?.makeFirstResponder(nil)
            onEditingFinished?()
            return true
        }
        return false
    }

}

// MARK: - ReorderableHStackView

/// Horizontal stack view that accepts drops for tab reordering.
class ReorderableHStackView: NSStackView {
    override var mouseDownCanMoveWindow: Bool { false }
    var onReorder: ((Int, Int) -> Void)?
    var tabCount: Int = 0  // number of tab views (excluding + button and spacer)

    private let dropIndicator: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = ThemeManager.shared.currentColors.foreground.withAlphaComponent(0.4).cgColor
        v.isHidden = true
        return v
    }()
    private var currentDropIndex: Int = -1

    private func dropIndex(for sender: NSDraggingInfo) -> Int {
        let location = convert(sender.draggingLocation, from: nil)
        for i in 0..<tabCount {
            guard i < arrangedSubviews.count else { break }
            let view = arrangedSubviews[i]
            if location.x < view.frame.midX {
                return i
            }
        }
        return tabCount
    }

    private func showIndicator(at index: Int) {
        guard index != currentDropIndex else { return }
        currentDropIndex = index

        if dropIndicator.superview !== self {
            dropIndicator.removeFromSuperview()
            addSubview(dropIndicator)
        }
        dropIndicator.isHidden = false

        let xPos: CGFloat
        if index < tabCount, index < arrangedSubviews.count {
            xPos = arrangedSubviews[index].frame.minX - 1
        } else if tabCount > 0, tabCount - 1 < arrangedSubviews.count {
            xPos = arrangedSubviews[tabCount - 1].frame.maxX + 1
        } else {
            xPos = 0
        }
        dropIndicator.frame = NSRect(x: xPos, y: 4, width: 2, height: bounds.height - 8)
    }

    func hideIndicator() {
        dropIndicator.isHidden = true
        currentDropIndex = -1
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(deckardTabDragType) == true else { return [] }
        showIndicator(at: dropIndex(for: sender))
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(deckardTabDragType) == true else { return [] }
        showIndicator(at: dropIndex(for: sender))
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideIndicator()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        hideIndicator()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideIndicator()
        guard let fromStr = sender.draggingPasteboard.string(forType: deckardTabDragType),
              let fromIndex = Int(fromStr) else { return false }

        let toIndex = dropIndex(for: sender)
        if toIndex != fromIndex {
            onReorder?(fromIndex, toIndex)
        }
        return true
    }
}
