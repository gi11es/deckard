import AppKit

/// Manages the right pane of the session explorer: header with actions + timeline table.
class SessionExplorerTimelineController: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private let containerView: NSView
    private var headerView: NSView?
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    private var currentSession: ExplorerSessionInfo?
    private var entries: [TimelineEntry] = []
    private var forkAtPointEnabled = false

    // Callbacks
    var onResume: ((String) -> Void)?
    var onFork: ((String) -> Void)?
    var onForkAtPoint: ((String, Int) -> Void)?

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

    struct TimelineOptions {
        let resumeEnabled: Bool
        let forkAtPointEnabled: Bool
        let scrollToIndex: Int?
    }

    // MARK: - Public

    func showTimeline(session: ExplorerSessionInfo, entries: [TimelineEntry], options: TimelineOptions) {
        self.currentSession = session
        self.entries = entries
        self.forkAtPointEnabled = options.forkAtPointEnabled

        containerView.subviews.forEach { $0.removeFromSuperview() }

        // Header
        let header = makeHeader(session: session, resumeEnabled: options.resumeEnabled)
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

        if let idx = options.scrollToIndex, idx < entries.count {
            tableView.scrollRowToVisible(idx)
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    // MARK: - Header

    private func makeHeader(session: ExplorerSessionInfo, resumeEnabled: Bool) -> NSView {
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
            subtitle.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -12),

            buttonStack.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
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

        // Fork here button (icon rotated 180° so arrows point down)
        let forkBtn: NSButton?
        if forkAtPointEnabled {
            let btn = NSButton(title: "", target: nil, action: nil)
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
                btn.image = rotated
            }
            btn.bezelStyle = .inline
            btn.isBordered = false
            btn.toolTip = "Fork here"
            btn.contentTintColor = NSColor(red: 0.4, green: 0.6, blue: 0.9, alpha: 0.8)
            btn.tag = entry.index
            btn.target = self
            btn.action = #selector(forkHereClicked(_:))
            btn.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(btn)
            forkBtn = btn
        } else {
            forkBtn = nil
        }

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
            metaField.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -8),

        ])

        if let forkBtn {
            NSLayoutConstraint.activate([
                forkBtn.leadingAnchor.constraint(equalTo: metaField.trailingAnchor, constant: 8),
                forkBtn.centerYAnchor.constraint(equalTo: metaField.centerYAnchor),
            ])
        }

        return cell
    }

    @objc private func forkHereClicked(_ sender: NSButton) {
        guard let session = currentSession else { return }
        onForkAtPoint?(session.sessionId, sender.tag)
    }

}
