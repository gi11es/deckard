import AppKit

/// Displays all Claude Code sessions for a project in a dedicated window.
/// Left pane: search + bookmarks + session list. Right pane: conversation timeline.
class SessionExplorerWindowController: NSWindowController, NSSplitViewDelegate, NSSearchFieldDelegate {

    private let projectPath: String
    private let projectName: String

    /// Callback invoked when the user picks an action (resume/fork).
    /// Parameters: sessionId, forkSession flag, tab name.
    var onSessionAction: ((String, Bool, String?) -> Void)?

    // --- Data ---
    private var allSessions: [ExplorerSessionInfo] = []
    private var filteredSessions: [ExplorerSessionInfo] = []
    private var bookmarks: [SessionBookmark] = []
    private var filteredBookmarks: [SessionBookmark] = []
    private var selectedSessionId: String?

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
        window.setFrameAutosaveName("SessionExplorerWindow")
        window.center()

        setupUI()
        loadData()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // Split view
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

        // Left pane
        setupLeftPane()
        splitView.addSubview(leftPane)

        // Right pane
        setupRightPane()
        splitView.addSubview(rightPane)

        splitView.setPosition(310, ofDividerAt: 0)
    }

    private func setupLeftPane() {
        leftPane.translatesAutoresizingMaskIntoConstraints = false

        // Search field
        searchField.placeholderString = "Search sessions..."
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        leftPane.addSubview(searchField)

        // Table view
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.title = ""
        listTableView.addTableColumn(column)
        listTableView.headerView = nil
        listTableView.dataSource = self
        listTableView.delegate = self
        listTableView.usesAutomaticRowHeights = true
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
            searchField.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor, constant: -8),

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
        timelineController?.onBookmarkToggle = { [weak self] sessionId, entry in
            self?.toggleBookmark(sessionId: sessionId, entry: entry)
        }
    }

    // MARK: - Data Loading

    private func loadData() {
        let rawSessions = ContextMonitor.shared.listSessions(forProjectPath: projectPath)
        let savedNames = SessionManager.shared.loadSessionNames()

        allSessions = rawSessions.map { session in
            let name = savedNames[session.sessionId]
            return ExplorerSessionInfo(
                sessionId: session.sessionId,
                filePath: URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects/\(projectPath.claudeProjectDirName)/\(session.sessionId).jsonl"),
                modificationDate: session.modificationDate,
                messageCount: session.messageCount,
                firstUserMessage: session.firstUserMessage,
                savedName: (name?.isEmpty == false) ? name : nil,
                summary: SummaryManager.shared.cachedSummary(forSessionId: session.sessionId)
            )
        }

        bookmarks = BookmarkManager.shared.bookmarks(forProjectPath: projectPath)
            .sorted { $0.createdAt < $1.createdAt }

        applyFilter()
    }

    private func applyFilter() {
        let query = searchField.stringValue.lowercased()
        if query.isEmpty {
            filteredSessions = allSessions
            filteredBookmarks = bookmarks
        } else {
            filteredSessions = allSessions.filter {
                ($0.savedName ?? "").lowercased().contains(query) ||
                ($0.summary ?? "").lowercased().contains(query) ||
                $0.firstUserMessage.lowercased().contains(query)
            }
            filteredBookmarks = bookmarks.filter {
                $0.label.lowercased().contains(query)
            }
        }
        // Preserve selection across reload
        let previousSelection = selectedSessionId
        listTableView.reloadData()
        if let prevId = previousSelection {
            restoreListSelection(sessionId: prevId)
        }
    }

    /// Restores the list selection to match the given sessionId.
    private func restoreListSelection(sessionId: String) {
        let bookmarkCount = filteredBookmarks.count
        let hasDivider = bookmarkCount > 0
        let offset = bookmarkCount + (hasDivider ? 1 : 0)
        if let idx = filteredSessions.firstIndex(where: { $0.sessionId == sessionId }) {
            listTableView.selectRowIndexes(IndexSet(integer: offset + idx), byExtendingSelection: false)
        }
    }

    // MARK: - Actions

    private func sessionDisplayName(for sessionId: String) -> String? {
        // Prefer saved session name (from tab rename), then first user message
        let savedNames = SessionManager.shared.loadSessionNames()
        if let name = savedNames[sessionId], !name.isEmpty { return name }
        guard let session = allSessions.first(where: { $0.sessionId == sessionId }) else { return nil }
        let msg = session.firstUserMessage
        return msg.isEmpty ? nil : String(msg.prefix(60))
    }

    private func performAction(sessionId: String, fork: Bool) {
        onSessionAction?(sessionId, fork, sessionDisplayName(for: sessionId))
        close()
    }

    private func performForkAtPoint(sessionId: String, turnIndex: Int) {
        let name = sessionDisplayName(for: sessionId)
        guard let newSessionId = ContextMonitor.shared.truncateSession(
            sessionId: sessionId,
            projectPath: projectPath,
            afterTurnIndex: turnIndex
        ) else { return }

        onSessionAction?(newSessionId, true, name)
        close()
    }

    private func toggleBookmark(sessionId: String, entry: TimelineEntry) {
        if entry.isBookmarked {
            BookmarkManager.shared.removeBookmark(
                projectPath: projectPath,
                sessionId: sessionId,
                messageIndex: entry.index
            )
        } else {
            promptForBookmarkLabel(defaultLabel: String(entry.message.prefix(60))) { [weak self] label in
                guard let self, let label else { return }
                BookmarkManager.shared.addBookmark(
                    projectPath: self.projectPath,
                    sessionId: sessionId,
                    messageIndex: entry.index,
                    label: label
                )
                self.loadData()
                self.timelineController?.reloadBookmarkState(
                    projectPath: self.projectPath,
                    sessionId: sessionId
                )
            }
            return
        }
        loadData()
        timelineController?.reloadBookmarkState(projectPath: projectPath, sessionId: sessionId)
    }

    private func promptForBookmarkLabel(defaultLabel: String, completion: @escaping (String?) -> Void) {
        guard let window else {
            completion(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Bookmark Label"
        alert.informativeText = "Enter a name for this bookmark:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = defaultLabel
        alert.accessoryView = input

        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                let label = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(label.isEmpty ? defaultLabel : label)
            } else {
                completion(nil)
            }
        }
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
        guard row >= 0 else { return }

        let bookmarkCount = filteredBookmarks.count
        let hasDivider = bookmarkCount > 0

        if row < bookmarkCount {
            // Clicked a bookmark -- select its parent session and scroll to message
            let bookmark = filteredBookmarks[row]
            selectSession(sessionId: bookmark.sessionId, scrollToMessageIndex: bookmark.messageIndex)
        } else {
            let sessionIndex = row - bookmarkCount - (hasDivider ? 1 : 0)
            guard sessionIndex >= 0, sessionIndex < filteredSessions.count else { return }
            let session = filteredSessions[sessionIndex]
            selectSession(sessionId: session.sessionId, scrollToMessageIndex: nil)
        }
    }

    private func selectSession(sessionId: String, scrollToMessageIndex: Int?) {
        selectedSessionId = sessionId
        guard let session = allSessions.first(where: { $0.sessionId == sessionId }) else { return }

        let entries = ContextMonitor.shared.parseTimeline(sessionId: sessionId, projectPath: projectPath)

        // Update message count now that we've parsed the full file
        if let idx = allSessions.firstIndex(where: { $0.sessionId == sessionId }) {
            allSessions[idx].messageCount = entries.count
        }

        // Use the session with updated messageCount for the timeline header
        let updatedSession = allSessions.first(where: { $0.sessionId == sessionId }) ?? session

        // Enrich entries with bookmark state
        let enrichedEntries = entries.map { entry -> TimelineEntry in
            var e = entry
            e.isBookmarked = BookmarkManager.shared.isBookmarked(
                projectPath: projectPath,
                sessionId: sessionId,
                messageIndex: entry.index
            )
            e.bookmarkLabel = BookmarkManager.shared.bookmarkLabel(
                projectPath: projectPath,
                sessionId: sessionId,
                messageIndex: entry.index
            )
            return e
        }

        // Load cached action summaries (no AI call — just what we already have)
        let cachedActionSummaries = SummaryManager.shared.cachedTurnSummaries(forSessionId: sessionId)

        // Check if anything needs AI summarization
        let actions = ContextMonitor.shared.parseActions(sessionId: sessionId, projectPath: projectPath)
        let hasUncachedActions = entries.contains { entry in
            let turnActions = actions[entry.index] ?? []
            return !turnActions.isEmpty && cachedActionSummaries[entry.index] == nil
        }
        let cachedTurnCount = SummaryManager.shared.cachedSummaryTurnCount(forSessionId: sessionId)
        let needsSessionSummary = session.summary == nil || cachedTurnCount < entries.count
        let summarizeEnabled = needsSessionSummary || hasUncachedActions

        timelineController?.showTimeline(
            session: updatedSession,
            entries: enrichedEntries,
            cachedActionSummaries: cachedActionSummaries,
            summarizeEnabled: summarizeEnabled,
            scrollToIndex: scrollToMessageIndex
        )

        timelineController?.onSummarize = { [weak self] in
            self?.summarizeAll(sessionId: sessionId, entries: entries, actions: actions)
        }
    }

    private func summarizeAll(sessionId: String, entries: [TimelineEntry], actions: [Int: [String]]) {
        timelineController?.setSummarizing(true)

        SummaryManager.shared.generateCombinedSummaries(
            sessionId: sessionId,
            projectPath: projectPath,
            currentTurnCount: entries.count,
            actions: actions
        ) { [weak self] sessionSummary, actionSummaries in
            guard let self, self.selectedSessionId == sessionId else { return }

            if let summary = sessionSummary,
               let idx = self.allSessions.firstIndex(where: { $0.sessionId == sessionId }) {
                self.allSessions[idx].summary = summary
                self.applyFilter()
                self.timelineController?.updateHeaderSummary(summary)
            }

            self.timelineController?.updateActionSummaries(actionSummaries)
            self.timelineController?.setSummarizing(false)
        }
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

    /// Total rows = bookmarks + (divider if bookmarks exist) + sessions
    func numberOfRows(in tableView: NSTableView) -> Int {
        let bookmarkCount = filteredBookmarks.count
        let divider = bookmarkCount > 0 ? 1 : 0
        return bookmarkCount + divider + filteredSessions.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let bookmarkCount = filteredBookmarks.count
        let hasDivider = bookmarkCount > 0

        if row < bookmarkCount {
            // Bookmark row
            let bookmark = filteredBookmarks[row]
            let sessionSummary = allSessions.first(where: { $0.sessionId == bookmark.sessionId })
            return makeBookmarkCell(bookmark: bookmark, sessionSummary: sessionSummary?.summary ?? sessionSummary?.firstUserMessage ?? "")
        } else if hasDivider && row == bookmarkCount {
            // Divider row
            return makeDividerCell()
        } else {
            // Session row
            let sessionIndex = row - bookmarkCount - (hasDivider ? 1 : 0)
            guard sessionIndex >= 0, sessionIndex < filteredSessions.count else { return nil }
            let session = filteredSessions[sessionIndex]
            return makeSessionCell(session: session)
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let bookmarkCount = filteredBookmarks.count
        let hasDivider = bookmarkCount > 0
        if hasDivider && row == bookmarkCount { return 16 }  // divider
        return 64
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // Don't allow selecting the divider
        let bookmarkCount = filteredBookmarks.count
        let hasDivider = bookmarkCount > 0
        if hasDivider && row == bookmarkCount { return false }
        return true
    }

    // MARK: - Cell Factories

    private func makeBookmarkCell(bookmark: SessionBookmark, sessionSummary: String) -> NSView {
        let cell = NSTableCellView()
        cell.wantsLayer = true
        cell.layer?.backgroundColor = NSColor(red: 1.0, green: 0.85, blue: 0.2, alpha: 0.08).cgColor
        cell.layer?.cornerRadius = 4

        let star = NSTextField(labelWithString: "\u{2605}")
        star.font = .systemFont(ofSize: 12)
        star.textColor = NSColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 0.7)
        star.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: bookmark.label)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 2
        title.preferredMaxLayoutWidth = 200
        title.cell?.wraps = true
        title.cell?.isScrollable = false
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let subtitle = NSTextField(labelWithString: "\(sessionSummary) \u{00B7} msg \(bookmark.messageIndex + 1)")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(star)
        cell.addSubview(title)
        cell.addSubview(subtitle)

        NSLayoutConstraint.activate([
            star.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            star.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            title.leadingAnchor.constraint(equalTo: star.trailingAnchor, constant: 4),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -8),
        ])

        return cell
    }

    private func makeDividerCell() -> NSView {
        let cell = NSView()
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            line.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            line.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeSessionCell(session: ExplorerSessionInfo) -> NSView {
        let cell = NSTableCellView()

        // Saved name as title, falling back to first user message
        let title = NSTextField(labelWithString: session.savedName ?? session.firstUserMessage)
        title.font = .systemFont(ofSize: 13, weight: session.sessionId == selectedSessionId ? .semibold : .regular)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 5
        title.preferredMaxLayoutWidth = 200
        title.cell?.wraps = true
        title.cell?.isScrollable = false
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // AI-generated summary below the title
        let summaryField: NSTextField?
        if let summary = session.summary {
            let field = NSTextField(labelWithString: summary)
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 5
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.translatesAutoresizingMaskIntoConstraints = false
            summaryField = field
        } else {
            summaryField = nil
        }

        // Timestamp + message count
        let timeStr = relativeFormatter.localizedString(for: session.modificationDate, relativeTo: Date())
        let metaText = session.messageCount > 0 ? "\(timeStr) \u{00B7} \(session.messageCount) msgs" : timeStr
        let metaField = NSTextField(labelWithString: metaText)
        metaField.font = .systemFont(ofSize: 10)
        metaField.textColor = .tertiaryLabelColor
        metaField.translatesAutoresizingMaskIntoConstraints = false

        // Spinner for summary generation
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isHidden = !SummaryManager.shared.isGenerating(sessionId: session.sessionId)
        if !spinner.isHidden { spinner.startAnimation(nil) }

        cell.addSubview(title)
        cell.addSubview(metaField)
        if let summaryField { cell.addSubview(summaryField) }
        cell.addSubview(spinner)

        // Bottom anchor: summary if present, otherwise meta
        let bottomView: NSView = summaryField ?? metaField

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -4),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),

            metaField.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            metaField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            metaField.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),

            bottomView.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -8),

            spinner.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            spinner.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
        ])

        if let summaryField {
            NSLayoutConstraint.activate([
                summaryField.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                summaryField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
                summaryField.topAnchor.constraint(equalTo: metaField.bottomAnchor, constant: 2),
            ])
        }

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
