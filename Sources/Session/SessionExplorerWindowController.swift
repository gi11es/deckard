import AppKit

/// Displays all Claude Code sessions for a project in a dedicated window.
/// Left pane: search + session list with star toggles. Right pane: conversation timeline.
class SessionExplorerWindowController: NSWindowController, NSSplitViewDelegate, NSSearchFieldDelegate {

    private let projectPath: String
    private let projectName: String

    /// Callback invoked when the user picks an action (resume/fork).
    /// Parameters: kind, sessionId, forkSession flag, tab name.
    var onSessionAction: ((TabKind, String, Bool, String?) -> Void)?

    /// Session IDs currently open in the project's tabs.
    var openSessionIds = Set<String>()

    // --- Data ---
    private var allSessions: [ExplorerSessionInfo] = []
    private var filteredSessions: [ExplorerSessionInfo] = []
    private var selectedSessionId: String?
    private var showFavoritesOnly = false

    // --- UI ---
    private let splitView = NSSplitView()
    private let leftPane = NSView()
    private let rightPane = NSView()
    private let searchField = NSSearchField()
    private let listScrollView = NSScrollView()
    private let listTableView = NSTableView()

    // Right pane managed by timeline view helper
    private var timelineController: SessionExplorerTimelineController?

    // --- Formatters ---
    private let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    init(projectPath: String, projectName: String) {
        self.projectPath = projectPath
        self.projectName = projectName

        let colors = ThemeManager.shared.currentColors
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sessions — \(projectName)"
        window.minSize = NSSize(width: 700, height: 500)
        window.backgroundColor = colors.background
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: colors.isDark ? .darkAqua : .aqua)

        super.init(window: window)
        window.delegate = self

        // Center on the main Deckard window, or fall back to screen center
        if let mainFrame = NSApp.mainWindow?.frame {
            let x = mainFrame.midX - window.frame.width / 2
            let y = mainFrame.midY - window.frame.height / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            window.center()
        }

        setupUI()
        loadData()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: contentView.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])

        setupLeftPane()
        splitView.addSubview(leftPane)

        setupRightPane()
        splitView.addSubview(rightPane)

        splitView.setPosition(310, ofDividerAt: 0)
    }

    private func setupLeftPane() {
        leftPane.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search sessions..."
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        leftPane.addSubview(searchField)

        let favBtn = NSButton(title: "", target: self, action: #selector(toggleFavoritesFilter))
        favBtn.image = NSImage(systemSymbolName: "star", accessibilityDescription: "Show favorites only")
        favBtn.bezelStyle = .inline
        favBtn.isBordered = false
        favBtn.toolTip = "Show favorites only"
        favBtn.translatesAutoresizingMaskIntoConstraints = false
        leftPane.addSubview(favBtn)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.title = ""
        listTableView.addTableColumn(column)
        listTableView.headerView = nil
        listTableView.dataSource = self
        listTableView.delegate = self
        listTableView.rowHeight = 52
        listTableView.backgroundColor = .clear
        listTableView.selectionHighlightStyle = .regular
        listTableView.target = self
        listTableView.action = #selector(listRowClicked)

        listScrollView.documentView = listTableView
        listScrollView.hasVerticalScroller = true
        listScrollView.translatesAutoresizingMaskIntoConstraints = false
        listScrollView.drawsBackground = false
        leftPane.addSubview(listScrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: leftPane.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: favBtn.leadingAnchor, constant: -4),

            favBtn.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            favBtn.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor, constant: -8),
            favBtn.widthAnchor.constraint(equalToConstant: 24),

            listScrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            listScrollView.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            listScrollView.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            listScrollView.bottomAnchor.constraint(equalTo: leftPane.bottomAnchor),
        ])
    }

    private func setupRightPane() {
        rightPane.translatesAutoresizingMaskIntoConstraints = false
        timelineController = SessionExplorerTimelineController(containerView: rightPane)
        timelineController?.onResume = { [weak self] sessionId in
            self?.performAction(sessionId: sessionId, fork: false)
        }
        timelineController?.onFork = { [weak self] sessionId in
            self?.performAction(sessionId: sessionId, fork: true)
        }
        timelineController?.onForkAtPoint = { [weak self] sessionId, turnIndex in
            self?.performForkAtPoint(sessionId: sessionId, turnIndex: turnIndex)
        }
    }

    // MARK: - Data Loading

    private func loadData() {
        let rawSessions = ContextMonitor.shared.listAllSessions(forProjectPath: projectPath)
        let savedNames = SessionManager.shared.loadSessionNames()

        allSessions = rawSessions.map { session in
            let cacheKey = SessionManager.sessionCacheKey(sessionId: session.sessionId, kind: session.kind)
            let name = savedNames[cacheKey]
            let bookmarkedIds = BookmarkManager.shared.bookmarkedSessionIds(forProjectPath: projectPath, kind: session.kind)
            return ExplorerSessionInfo(
                agentKind: session.kind,
                sessionId: session.sessionId,
                filePath: session.filePath ?? URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects/\(projectPath.claudeProjectDirName)/\(session.sessionId).jsonl"),
                modificationDate: session.modificationDate,
                messageCount: session.messageCount,
                firstUserMessage: session.firstUserMessage,
                savedName: (name?.isEmpty == false) ? name : nil,
                isBookmarked: bookmarkedIds.contains(session.sessionId)
            )
        }

        applyFilter()
    }

    @objc private func toggleFavoritesFilter(_ sender: NSButton) {
        showFavoritesOnly.toggle()
        sender.contentTintColor = showFavoritesOnly
            ? NSColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 0.9)
            : nil
        sender.image = NSImage(systemSymbolName: showFavoritesOnly ? "star.fill" : "star", accessibilityDescription: "Show favorites only")
        applyFilter()
    }

    private func applyFilter() {
        let query = searchField.stringValue.lowercased()
        var sessions = allSessions

        if showFavoritesOnly {
            sessions = sessions.filter { $0.isBookmarked }
        }

        if !query.isEmpty {
            sessions = sessions.filter {
                ($0.savedName ?? "").lowercased().contains(query) ||
                $0.firstUserMessage.lowercased().contains(query)
            }
        }

        filteredSessions = sessions

        // Preserve scroll position and selection across reload
        let scrollPosition = listScrollView.contentView.bounds.origin
        let previousSelection = selectedSessionId
        listTableView.reloadData()
        listScrollView.contentView.scroll(to: scrollPosition)
        if let prevId = previousSelection {
            restoreListSelection(sessionId: prevId)
        }
    }

    private func restoreListSelection(sessionId: String) {
        if let idx = filteredSessions.firstIndex(where: { $0.cacheKey == sessionId }) {
            listTableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    // MARK: - Actions

    private func sessionDisplayName(for sessionId: String) -> String? {
        guard let session = allSessions.first(where: { $0.cacheKey == sessionId || $0.sessionId == sessionId }) else { return nil }
        let savedNames = SessionManager.shared.loadSessionNames()
        if let name = savedNames[session.cacheKey], !name.isEmpty { return name }
        let msg = session.firstUserMessage
        return msg.isEmpty ? nil : String(msg.prefix(60))
    }

    private func performAction(sessionId: String, fork: Bool) {
        guard let session = allSessions.first(where: { $0.cacheKey == selectedSessionId || $0.sessionId == sessionId }) else { return }
        onSessionAction?(session.agentKind, session.sessionId, fork, sessionDisplayName(for: session.cacheKey))
        close()
    }

    private func performForkAtPoint(sessionId: String, turnIndex: Int) {
        guard let session = allSessions.first(where: { $0.cacheKey == selectedSessionId || $0.sessionId == sessionId }),
              let newSessionId = ContextMonitor.shared.truncateSession(
            sessionId: sessionId,
            projectPath: projectPath,
            afterTurnIndex: turnIndex,
            kind: session.agentKind
        ) else { return }

        let name = sessionDisplayName(for: session.cacheKey)
        onSessionAction?(session.agentKind, newSessionId, true, name)
        close()
    }

    @objc private func starClicked(_ sender: NSButton) {
        let row = sender.tag
        guard row < filteredSessions.count else { return }
        let session = filteredSessions[row]
        let sessionId = session.sessionId
        let newState = BookmarkManager.shared.toggleBookmark(projectPath: projectPath, sessionId: sessionId, kind: session.agentKind)
        if let idx = allSessions.firstIndex(where: { $0.cacheKey == session.cacheKey }) {
            allSessions[idx].isBookmarked = newState
        }
        if let fIdx = filteredSessions.firstIndex(where: { $0.cacheKey == session.cacheKey }) {
            filteredSessions[fIdx].isBookmarked = newState
        }
        // Update only the button itself — no row reload
        sender.title = newState ? "\u{2605}" : "\u{2606}"
        sender.contentTintColor = newState
            ? NSColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 0.7)
            : NSColor.tertiaryLabelColor
    }

    // MARK: - Search

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === searchField {
            applyFilter()
        }
    }

    // MARK: - List selection

    @objc private func listRowClicked() {
        let row = listTableView.selectedRow
        guard row >= 0, row < filteredSessions.count else { return }
        let session = filteredSessions[row]
        selectSession(cacheKey: session.cacheKey, scrollToMessageIndex: nil)
    }

    private func selectSession(cacheKey: String, scrollToMessageIndex: Int?) {
        selectedSessionId = cacheKey
        guard let session = allSessions.first(where: { $0.cacheKey == cacheKey }) else { return }
        let sessionId = session.sessionId

        let entries = ContextMonitor.shared.parseTimeline(sessionId: sessionId, projectPath: projectPath, kind: session.agentKind)

        if let idx = allSessions.firstIndex(where: { $0.cacheKey == cacheKey }) {
            allSessions[idx].messageCount = entries.count
        }

        let updatedSession = allSessions.first(where: { $0.cacheKey == cacheKey }) ?? session

        let isOpen = openSessionIds.contains(updatedSession.cacheKey)

        timelineController?.showTimeline(
            session: updatedSession,
            entries: entries,
            options: .init(
                resumeEnabled: !isOpen,
                forkAtPointEnabled: updatedSession.agentKind.isAgent,
                scrollToIndex: scrollToMessageIndex
            )
        )
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 200
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return (window?.frame.width ?? 900) * 0.5
    }
}

// MARK: - NSTableViewDataSource & Delegate (left pane list)

extension SessionExplorerWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredSessions.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredSessions.count else { return nil }
        return makeSessionCell(session: filteredSessions[row], row: row)
    }

    private func makeSessionCell(session: ExplorerSessionInfo, row: Int) -> NSView {
        let cell = NSTableCellView()

        // Star toggle — fixed size, left-aligned
        let starBtn = NSButton(title: session.isBookmarked ? "\u{2605}" : "\u{2606}", target: self, action: #selector(starClicked(_:)))
        starBtn.bezelStyle = .inline
        starBtn.isBordered = false
        starBtn.font = .systemFont(ofSize: 14)
        starBtn.contentTintColor = session.isBookmarked
            ? NSColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 0.7)
            : NSColor.tertiaryLabelColor
        starBtn.tag = row
        starBtn.setContentHuggingPriority(.required, for: .horizontal)
        starBtn.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Title — single line, truncates
        let title = NSTextField(labelWithString: session.savedName ?? session.firstUserMessage)
        title.font = .systemFont(ofSize: 13, weight: session.cacheKey == selectedSessionId ? .semibold : .regular)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail

        // Timestamp
        let timeStr = relativeFormatter.localizedString(for: session.modificationDate, relativeTo: Date())
        let metaField = NSTextField(labelWithString: "\(session.agentKind.displayName) · \(timeStr)")
        metaField.font = .systemFont(ofSize: 10)
        metaField.textColor = .tertiaryLabelColor

        // Text stack (title + meta)
        let textStack = NSStackView(views: [title, metaField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        // Horizontal: star + text stack
        let hStack = NSStackView(views: [starBtn, textStack])
        hStack.orientation = .horizontal
        hStack.alignment = .top
        hStack.spacing = 4
        hStack.translatesAutoresizingMaskIntoConstraints = false
        hStack.edgeInsets = NSEdgeInsets(top: 6, left: 4, bottom: 6, right: 8)
        cell.addSubview(hStack)

        NSLayoutConstraint.activate([
            hStack.topAnchor.constraint(equalTo: cell.topAnchor),
            hStack.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
            hStack.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            hStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
        ])

        return cell
    }
}

// MARK: - NSWindowDelegate

extension SessionExplorerWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let w = window {
            objc_setAssociatedObject(w, "explorerController", nil, .OBJC_ASSOCIATION_RETAIN)
        }
    }
}
