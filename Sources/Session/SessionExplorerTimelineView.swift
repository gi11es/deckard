import AppKit

/// Manages the right pane of the session explorer: header with actions + timeline table.
class SessionExplorerTimelineController: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private let containerView: NSView
    private var headerView: NSView?
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    private var currentSession: ExplorerSessionInfo?
    private var entries: [TimelineEntry] = []
    private var summarizeSpinner: NSProgressIndicator?

    // Callbacks
    var onResume: ((String) -> Void)?
    var onFork: ((String) -> Void)?
    var onForkAtPoint: ((String, Int) -> Void)?
    var onSummarize: (() -> Void)?

    private var summarizeBtn: NSButton?

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    init(containerView: NSView) {
        self.containerView = containerView
        super.init()
        setupTableView()
        showEmptyState()
    }

    private func setupTableView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("timeline"))
        column.title = ""
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAutomaticRowHeights = true
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
    }

    // MARK: - Public

    func showTimeline(
        session: ExplorerSessionInfo,
        entries: [TimelineEntry],
        cachedActionSummaries: [Int: String],
        summarizeEnabled: Bool,
        resumeEnabled: Bool,
        scrollToIndex: Int?
    ) {
        self.currentSession = session
        self.entries = entries

        // Apply cached action summaries
        for i in 0..<self.entries.count {
            self.entries[i].actionSummary = cachedActionSummaries[self.entries[i].index]
        }

        containerView.subviews.forEach { $0.removeFromSuperview() }

        // Header
        let header = makeHeader(session: session, summarizeEnabled: summarizeEnabled, resumeEnabled: resumeEnabled)
        self.headerView = header
        header.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(header)

        // Timeline
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: containerView.topAnchor),
            header.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        tableView.reloadData()

        if let idx = scrollToIndex, idx < entries.count {
            tableView.scrollRowToVisible(idx)
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    /// Transitions the button to a "generating" state: disabled, label changes, spinner appears.
    func setSummarizing(_ active: Bool) {
        guard let btn = summarizeBtn else { return }
        btn.title = active ? "Summarizing..." : "Summarize with Haiku"
        btn.isEnabled = !active

        if active {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimation(nil)
            btn.superview?.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.leadingAnchor.constraint(equalTo: btn.trailingAnchor, constant: 6),
                spinner.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
            ])
            summarizeSpinner = spinner
        } else {
            summarizeSpinner?.removeFromSuperview()
            summarizeSpinner = nil
        }
        tableView.reloadData()
    }

    // MARK: - Header

    private func makeHeader(session: ExplorerSessionInfo, summarizeEnabled: Bool, resumeEnabled: Bool) -> NSView {
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(white: 0, alpha: 0.1).cgColor

        // Title: always the saved name or first user message
        let title = NSTextField(labelWithString: session.savedName ?? session.firstUserMessage)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 5
        title.cell?.wraps = true
        title.cell?.isScrollable = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false

        let timeStr = RelativeDateTimeFormatter().localizedString(for: session.modificationDate, relativeTo: Date())
        let subtitle = NSTextField(labelWithString: "\(session.messageCount) messages \u{00B7} \(timeStr)")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        // Action buttons (top right)
        let resumeBtn = NSButton(title: "Resume", target: self, action: #selector(resumeClicked))
        resumeBtn.bezelStyle = .rounded
        resumeBtn.isEnabled = resumeEnabled
        resumeBtn.translatesAutoresizingMaskIntoConstraints = false

        let forkBtn = NSButton(title: "Fork", target: self, action: #selector(forkClicked))
        forkBtn.bezelStyle = .rounded
        forkBtn.translatesAutoresizingMaskIntoConstraints = false

        let buttonStack = NSStackView(views: [resumeBtn, forkBtn])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(title)
        header.addSubview(subtitle)
        header.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -12),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),

            buttonStack.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            buttonStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
        ])

        // Track what the current bottom element is
        var bottomAnchorView: NSView = subtitle

        // Show existing summary if cached
        if let summary = session.summary {
            let field = NSTextField(labelWithString: summary)
            field.font = .systemFont(ofSize: 12)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 5
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(field)

            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
                field.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 4),
            ])
            bottomAnchorView = field
        }

        // Summarize button — always present, disabled when nothing to summarize
        let btn = NSButton(title: "Summarize with Haiku", target: self, action: #selector(summarizeClicked))
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.isEnabled = summarizeEnabled
        btn.translatesAutoresizingMaskIntoConstraints = false
        self.summarizeBtn = btn
        header.addSubview(btn)

        NSLayoutConstraint.activate([
            btn.topAnchor.constraint(equalTo: bottomAnchorView.bottomAnchor, constant: 8),
            btn.leadingAnchor.constraint(equalTo: title.leadingAnchor),
        ])
        btn.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -12).isActive = true

        return header
    }

    @objc private func resumeClicked() {
        guard let session = currentSession else { return }
        onResume?(session.sessionId)
    }

    @objc private func forkClicked() {
        guard let session = currentSession else { return }
        onFork?(session.sessionId)
    }

    @objc private func summarizeClicked() {
        onSummarize?()
    }

    // MARK: - Empty State

    private func showEmptyState() {
        containerView.subviews.forEach { $0.removeFromSuperview() }

        let label = NSTextField(labelWithString: "Select a session to view its timeline")
        label.font = .systemFont(ofSize: 14)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
        ])
    }

    // MARK: - NSTableViewDataSource & Delegate (timeline)

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let entry = entries[row]
        return makeTimelineCell(entry: entry, isLast: row == entries.count - 1)
    }

    // Row heights are driven by usesAutomaticRowHeights + auto layout constraints

    // MARK: - Timeline Cell

    private func makeTimelineCell(entry: TimelineEntry, isLast: Bool) -> NSView {
        let cell = NSView()

        // Vertical line
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(line)

        // Dot
        let dot = NSView()
        dot.wantsLayer = true
        let dotColor = NSColor(red: 0.4, green: 0.6, blue: 0.9, alpha: 0.7)
        dot.layer?.backgroundColor = dotColor.cgColor
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(dot)

        // Message text
        let msgField = NSTextField(labelWithString: entry.message)
        msgField.font = .systemFont(ofSize: 12)
        msgField.textColor = .labelColor
        msgField.lineBreakMode = .byTruncatingTail
        msgField.maximumNumberOfLines = 5
        msgField.cell?.wraps = true
        msgField.cell?.isScrollable = false
        msgField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        msgField.toolTip = entry.message
        msgField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(msgField)

        // Timestamp
        var metaParts: [String] = []
        if let ts = entry.timestamp {
            metaParts.append(timeFormatter.string(from: ts))
        }

        let metaField = NSTextField(labelWithString: metaParts.joined(separator: " \u{00B7} "))
        metaField.font = .systemFont(ofSize: 11)
        metaField.textColor = .tertiaryLabelColor
        metaField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(metaField)

        // Action summary (what Claude did in response)
        let actionField: NSTextField?
        if let summary = entry.actionSummary, !summary.isEmpty {
            let field = NSTextField(labelWithString: "\u{2192} \(summary)")
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 5
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            actionField = field
        } else {
            actionField = nil
        }

        // Fork here button (icon rotated 180° so arrows point down)
        let forkBtn = NSButton(title: "", target: nil, action: nil)
        if let branchImage = NSImage(systemSymbolName: "arrow.branch", accessibilityDescription: "Fork here") {
            let size = branchImage.size
            let rotated = NSImage(size: size, flipped: false) { _ in
                let ctx = NSGraphicsContext.current!.cgContext
                ctx.translateBy(x: size.width / 2, y: size.height / 2)
                ctx.rotate(by: .pi)
                ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
                branchImage.draw(in: NSRect(origin: .zero, size: size))
                return true
            }
            rotated.isTemplate = true
            forkBtn.image = rotated
        }
        forkBtn.bezelStyle = .inline
        forkBtn.isBordered = false
        forkBtn.toolTip = "Fork here"
        forkBtn.contentTintColor = NSColor(red: 0.4, green: 0.6, blue: 0.9, alpha: 0.8)
        forkBtn.tag = entry.index
        forkBtn.target = self
        forkBtn.action = #selector(forkHereClicked(_:))
        forkBtn.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(forkBtn)

        NSLayoutConstraint.activate([
            // Vertical line
            line.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 24),
            line.widthAnchor.constraint(equalToConstant: 2),
            line.topAnchor.constraint(equalTo: cell.topAnchor),
            line.bottomAnchor.constraint(equalTo: isLast ? dot.centerYAnchor : cell.bottomAnchor),

            // Dot
            dot.centerXAnchor.constraint(equalTo: line.centerXAnchor),
            dot.topAnchor.constraint(equalTo: cell.topAnchor, constant: 12),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),

            // Message
            msgField.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
            msgField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16),
            msgField.topAnchor.constraint(equalTo: dot.topAnchor, constant: -2),

            // Meta
            metaField.leadingAnchor.constraint(equalTo: msgField.leadingAnchor),
            metaField.topAnchor.constraint(equalTo: msgField.bottomAnchor, constant: 2),

            // Fork here
            forkBtn.leadingAnchor.constraint(equalTo: metaField.trailingAnchor, constant: 8),
            forkBtn.centerYAnchor.constraint(equalTo: metaField.centerYAnchor),
        ])

        if let actionField {
            NSLayoutConstraint.activate([
                actionField.leadingAnchor.constraint(equalTo: msgField.leadingAnchor),
                actionField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16),
                actionField.topAnchor.constraint(equalTo: metaField.bottomAnchor, constant: 1),
                actionField.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -8),
            ])
        } else {
            metaField.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -8).isActive = true
        }

        return cell
    }

    @objc private func forkHereClicked(_ sender: NSButton) {
        guard let session = currentSession else { return }
        onForkAtPoint?(session.sessionId, sender.tag)
    }

}
