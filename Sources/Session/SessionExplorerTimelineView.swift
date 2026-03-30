import AppKit

/// Manages the right pane of the session explorer: header with actions + timeline table.
class SessionExplorerTimelineController: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private let containerView: NSView
    private var headerView: NSView?
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    private var currentSession: ExplorerSessionInfo?
    private var entries: [TimelineEntry] = []

    // Callbacks
    var onResume: ((String) -> Void)?
    var onFork: ((String) -> Void)?
    var onForkAtPoint: ((String, Int) -> Void)?
    var onBookmarkToggle: ((String, TimelineEntry) -> Void)?

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
        tableView.rowHeight = 60
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
    }

    // MARK: - Public

    func showTimeline(session: ExplorerSessionInfo, entries: [TimelineEntry], scrollToIndex: Int?) {
        self.currentSession = session
        self.entries = entries

        containerView.subviews.forEach { $0.removeFromSuperview() }

        // Header
        let header = makeHeader(session: session)
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

    func updateActionSummaries(_ summaries: [Int: String]) {
        for i in 0..<entries.count {
            entries[i].actionSummary = summaries[entries[i].index]
        }
        tableView.reloadData()
    }

    func reloadBookmarkState(projectPath: String, sessionId: String) {
        for i in 0..<entries.count {
            entries[i].isBookmarked = BookmarkManager.shared.isBookmarked(
                projectPath: projectPath,
                sessionId: sessionId,
                messageIndex: entries[i].index
            )
            entries[i].bookmarkLabel = BookmarkManager.shared.bookmarkLabel(
                projectPath: projectPath,
                sessionId: sessionId,
                messageIndex: entries[i].index
            )
        }
        tableView.reloadData()
    }

    // MARK: - Header

    private func makeHeader(session: ExplorerSessionInfo) -> NSView {
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(white: 0, alpha: 0.1).cgColor

        let title = NSTextField(labelWithString: session.summary ?? session.firstUserMessage)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let timeStr = RelativeDateTimeFormatter().localizedString(for: session.modificationDate, relativeTo: Date())
        let subtitle = NSTextField(labelWithString: "\(session.messageCount) messages \u{00B7} \(timeStr)")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let resumeBtn = NSButton(title: "Resume", target: self, action: #selector(resumeClicked))
        resumeBtn.bezelStyle = .rounded
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
            subtitle.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -12),

            buttonStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
        ])

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

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < entries.count else { return 60 }
        return entries[row].actionSummary != nil ? 76 : 60
    }

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
        let dotColor = entry.isBookmarked
            ? NSColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 0.7)
            : NSColor(red: 0.4, green: 0.6, blue: 0.9, alpha: 0.7)
        dot.layer?.backgroundColor = dotColor.cgColor
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(dot)

        // Message text
        var messageText = entry.message
        if let label = entry.bookmarkLabel {
            messageText += "  \u{2605} \(label)"
        }
        let msgField = NSTextField(labelWithString: messageText)
        msgField.font = .systemFont(ofSize: 12)
        msgField.textColor = .labelColor
        msgField.lineBreakMode = .byTruncatingTail
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
        if let summary = entry.actionSummary {
            let field = NSTextField(labelWithString: "\u{2192} \(summary)")
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            actionField = field
        } else {
            actionField = nil
        }

        // Fork here button
        let forkBtn = NSButton(title: "", target: nil, action: nil)
        forkBtn.image = NSImage(systemSymbolName: "arrow.branch", accessibilityDescription: "Fork here")
        forkBtn.bezelStyle = .inline
        forkBtn.isBordered = false
        forkBtn.toolTip = "Fork here"
        forkBtn.contentTintColor = NSColor(red: 0.4, green: 0.6, blue: 0.9, alpha: 0.8)
        forkBtn.tag = entry.index
        forkBtn.target = self
        forkBtn.action = #selector(forkHereClicked(_:))
        forkBtn.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(forkBtn)

        // Star toggle
        let starBtn = NSButton(title: entry.isBookmarked ? "\u{2605}" : "\u{2606}", target: nil, action: nil)
        starBtn.bezelStyle = .inline
        starBtn.font = .systemFont(ofSize: 13)
        starBtn.isBordered = false
        starBtn.contentTintColor = entry.isBookmarked
            ? NSColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 0.7)
            : NSColor.tertiaryLabelColor
        starBtn.tag = entry.index
        starBtn.target = self
        starBtn.action = #selector(starClicked(_:))
        starBtn.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(starBtn)

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
            msgField.trailingAnchor.constraint(equalTo: starBtn.leadingAnchor, constant: -8),
            msgField.topAnchor.constraint(equalTo: dot.topAnchor, constant: -2),

            // Meta
            metaField.leadingAnchor.constraint(equalTo: msgField.leadingAnchor),
            metaField.topAnchor.constraint(equalTo: msgField.bottomAnchor, constant: 2),

            // Fork here
            forkBtn.leadingAnchor.constraint(equalTo: metaField.trailingAnchor, constant: 8),
            forkBtn.centerYAnchor.constraint(equalTo: metaField.centerYAnchor),

            // Star
            starBtn.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16),
            starBtn.topAnchor.constraint(equalTo: cell.topAnchor, constant: 12),
            starBtn.widthAnchor.constraint(equalToConstant: 24),
        ])

        if let actionField {
            NSLayoutConstraint.activate([
                actionField.leadingAnchor.constraint(equalTo: msgField.leadingAnchor),
                actionField.trailingAnchor.constraint(equalTo: starBtn.leadingAnchor, constant: -8),
                actionField.topAnchor.constraint(equalTo: metaField.bottomAnchor, constant: 1),
            ])
        }

        return cell
    }

    @objc private func forkHereClicked(_ sender: NSButton) {
        guard let session = currentSession else { return }
        onForkAtPoint?(session.sessionId, sender.tag)
    }

    @objc private func starClicked(_ sender: NSButton) {
        guard let session = currentSession, sender.tag < entries.count else { return }
        let entry = entries[sender.tag]
        onBookmarkToggle?(session.sessionId, entry)
    }
}
