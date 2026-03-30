import AppKit
import Fuse

/// A Spotlight-style project picker that appears when creating a new Claude tab.
/// Shows recent projects from ~/.claude/projects/, sorted by recency.
class ProjectPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    typealias Completion = (String?) -> Void  // nil = cancelled, String = chosen path

    private let panel: NSPanel
    private let searchField: NSTextField
    private let tableView: NSTableView
    private let scrollView: NSScrollView
    private var completion: Completion?

    private var allProjects: [(path: String, lastUsed: Date)] = []
    private var filteredProjects: [(path: String, lastUsed: Date)] = []
    private var spotlightSearch: Process?
    private var spotlightPipe: Pipe?
    private var keyMonitor: Any?
    private var excludePaths: Set<String> = []
    private let fuse = Fuse(threshold: 0.4)

    override init() {
        // Create a floating panel
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        // Search field
        searchField = NSTextField()
        searchField.placeholderString = "Open Folder..."
        searchField.font = .systemFont(ofSize: 16)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.focusRingType = .none
        searchField.bezelStyle = .roundedBezel

        // Table view for project list
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Project"))
        column.title = ""

        tableView = NSTableView()
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = false

        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false

        super.init()

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked)
        searchField.delegate = self

        // Layout
        let contentView = panel.contentView!
        contentView.addSubview(searchField)
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 30),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // Handle Enter and Escape via the search field's action
        searchField.target = self
        searchField.action = #selector(searchFieldAction)
    }

    /// Show the picker centered on the given window.
    /// `excludePaths` are already-open projects that should be hidden from the list.
    func show(relativeTo window: NSWindow?, completion: @escaping Completion) {
        self.completion = completion

        allProjects = Self.loadRecentProjects()
        filteredProjects = allProjects
        tableView.reloadData()

        // Select first row
        if !filteredProjects.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        // Position
        if let window = window {
            let windowFrame = window.frame
            let x = windowFrame.midX - 250
            let y = windowFrame.midY - 50
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)

        // Monitor for Escape key — remove any prior monitor to avoid leaks
        if let existing = keyMonitor {
            NSEvent.removeMonitor(existing)
            keyMonitor = nil
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.panel.isVisible else { return event }

            if event.keyCode == 53 { // Escape
                self.cancel()
                return nil
            }
            if event.keyCode == 36 { // Enter
                self.confirm()
                return nil
            }
            if event.keyCode == 125 { // Down arrow
                self.moveSelection(by: 1)
                return nil
            }
            if event.keyCode == 126 { // Up arrow
                self.moveSelection(by: -1)
                return nil
            }
            if event.keyCode == 48 { // Tab — autocomplete selected path
                self.autocompleteSelection()
                return nil
            }
            return event
        }

        searchField.stringValue = ""
    }

    private func cancel() {
        cancelSpotlightSearch()
        removeKeyMonitor()
        panel.orderOut(nil)
        completion?(nil)
        completion = nil
    }

    private func confirm() {
        cancelSpotlightSearch()
        removeKeyMonitor()
        let row = tableView.selectedRow
        let path: String
        if row >= 0, row < filteredProjects.count {
            path = filteredProjects[row].path
        } else {
            // Use the text field value as a raw path
            let text = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                cancel()
                return
            }
            path = (text as NSString).expandingTildeInPath
        }
        panel.orderOut(nil)
        completion?(path)
        completion = nil
    }

    private func moveSelection(by delta: Int) {
        guard !filteredProjects.isEmpty else { return }
        let current = tableView.selectedRow
        let next = max(0, min(filteredProjects.count - 1, current + delta))
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func autocompleteSelection() {
        var row = tableView.selectedRow
        guard row >= 0, row < filteredProjects.count else { return }
        // If selected row is the typed directory itself, jump to first subfolder
        let currentInput = (searchField.stringValue as NSString).expandingTildeInPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let selectedPath = filteredProjects[row].path
        if selectedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == currentInput,
           row + 1 < filteredProjects.count {
            row += 1
        }
        let path = filteredProjects[row].path + "/"
        searchField.stringValue = path
        // Move cursor to end
        searchField.currentEditor()?.selectedRange = NSRange(location: path.count, length: 0)
        // Trigger a re-filter to show subdirectories
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    @objc private func searchFieldAction() {
        confirm()
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// Safely terminate the spotlight search, clearing the readability handler
    /// first to prevent NSFileHandleOperationException crashes.
    private func cancelSpotlightSearch() {
        spotlightPipe?.fileHandleForReading.readabilityHandler = nil
        spotlightSearch?.terminate()
        spotlightSearch = nil
        spotlightPipe = nil
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue
        if query.isEmpty {
            filteredProjects = allProjects
            cancelSpotlightSearch()
        } else if query.hasPrefix("/") || query.hasPrefix("~") {
            // Path-based autocomplete: list directories at the typed path
            cancelSpotlightSearch()
            filteredProjects = listDirectories(at: query)
        } else {
            // Fuzzy match on basename (primary) and full path (fallback)
            var scored: [(project: (path: String, lastUsed: Date), score: Double)] = []
            for project in allProjects {
                let basename = (project.path as NSString).lastPathComponent
                let bResult = fuse.search(query, in: basename)
                let pResult = fuse.search(query, in: project.path)
                let best: Double? = [bResult?.score, pResult?.score]
                    .compactMap { $0 }.min()
                if let score = best {
                    scored.append((project: project, score: score))
                }
            }
            scored.sort {
                abs($0.score - $1.score) < 0.001
                    ? $0.project.lastUsed > $1.project.lastUsed
                    : $0.score < $1.score
            }
            filteredProjects = scored.map { $0.project }

            // Also search filesystem via mdfind (Spotlight)
            cancelSpotlightSearch()
            searchFilesystem(query: query)
        }
        tableView.reloadData()
        if !filteredProjects.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func listDirectories(at input: String) -> [(path: String, lastUsed: Date)] {
        let expanded = (input as NSString).expandingTildeInPath
        let fm = FileManager.default

        // If the path is an existing directory, show it first then its subdirectories
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            var results: [(path: String, lastUsed: Date)] = []
            // The directory itself as the first option
            let cleanPath = expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
            results.append((path: cleanPath, lastUsed: .now))

            let parent = expanded.hasSuffix("/") ? expanded : expanded + "/"
            guard let contents = try? fm.contentsOfDirectory(atPath: expanded) else { return results }
            results += contents
                .filter { !$0.hasPrefix(".") }
                .map { parent + $0 }
                .filter { path in
                    var d: ObjCBool = false
                    return fm.fileExists(atPath: path, isDirectory: &d) && d.boolValue
                }
                .sorted()
                .map { (path: $0, lastUsed: .distantPast) }
            return results
        }

        // Otherwise, treat as partial path: list parent dir filtered by prefix
        let parentDir = (expanded as NSString).deletingLastPathComponent
        let prefix = (expanded as NSString).lastPathComponent.lowercased()
        guard fm.fileExists(atPath: parentDir, isDirectory: &isDir), isDir.boolValue else { return [] }
        guard let contents = try? fm.contentsOfDirectory(atPath: parentDir) else { return [] }
        return contents
            .filter { !$0.hasPrefix(".") && $0.lowercased().hasPrefix(prefix) }
            .map { (parentDir as NSString).appendingPathComponent($0) }
            .filter { path in
                var d: ObjCBool = false
                return fm.fileExists(atPath: path, isDirectory: &d) && d.boolValue
            }
            .sorted()
            .map { (path: $0, lastUsed: .distantPast) }
    }

    private func searchFilesystem(query: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        // Escape single quotes in the query to prevent Spotlight query injection.
        let escaped = query.replacingOccurrences(of: "'", with: "\\'")
        process.arguments = [
            "kMDItemContentType == public.folder && kMDItemFSName == '*\(escaped)*'cd"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let knownPaths = Set(allProjects.map { $0.path })

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF — process finished, clean up the handler
                handle.readabilityHandler = nil
                return
            }
            let output = String(data: data, encoding: .utf8) ?? ""
            let paths = output.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            DispatchQueue.main.async {
                guard let self = self else { return }
                var added = false
                for path in paths {
                    // Skip already-shown, already-open, or hidden paths
                    if knownPaths.contains(path) { continue }
                    if self.excludePaths.contains(path) { continue }
                    if self.filteredProjects.contains(where: { $0.path == path }) { continue }
                    if path.contains("/.") || path.contains("/Library/") { continue }
                    if path.contains("/node_modules/") || path.contains("/.git/") { continue }

                    // Fuzzy-filter mdfind results
                    let basename = (path as NSString).lastPathComponent
                    let bResult = self.fuse.search(query, in: basename)
                    let pResult = self.fuse.search(query, in: path)
                    let best = [bResult?.score, pResult?.score].compactMap { $0 }.min()
                    guard best != nil else { continue }

                    self.filteredProjects.append((path: path, lastUsed: .distantPast))
                    added = true
                }
                if added {
                    self.tableView.reloadData()
                    if self.tableView.selectedRow < 0, !self.filteredProjects.isEmpty {
                        self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    }
                }
            }
        }

        try? process.run()
        spotlightSearch = process
        spotlightPipe = pipe
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredProjects.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ProjectCell")
        let project = filteredProjects[row]

        let cell: NSTableCellView
        if let recycled = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = recycled
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        // Show shortened path: ~/Documents/project instead of /Users/gilles/Documents/project
        let home = NSHomeDirectory()
        let displayPath = project.path.hasPrefix(home)
            ? "~" + project.path.dropFirst(home.count)
            : project.path

        cell.textField?.stringValue = displayPath
        cell.textField?.font = .systemFont(ofSize: 13)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
    }

    @objc private func tableDoubleClicked() {
        confirm()
    }

    // MARK: - Load Projects

    static func loadRecentProjects() -> [(path: String, lastUsed: Date)] {
        let projectsDir = NSHomeDirectory() + "/.claude/projects"
        let fm = FileManager.default

        guard let entries = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }

        var results: [(path: String, lastUsed: Date, sessionCount: Int)] = []

        for entry in entries {
            guard let decoded = Self.decodeCloudeProjectPath(entry) else { continue }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: decoded, isDirectory: &isDir), isDir.boolValue else { continue }

            let entryPath = projectsDir + "/" + entry
            var newestDate = Date.distantPast
            var sessionCount = 0

            if let files = try? fm.contentsOfDirectory(atPath: entryPath) {
                for file in files where file.hasSuffix(".jsonl") {
                    sessionCount += 1
                    let filePath = entryPath + "/" + file
                    if let attrs = try? fm.attributesOfItem(atPath: filePath),
                       let mod = attrs[.modificationDate] as? Date,
                       mod > newestDate {
                        newestDate = mod
                    }
                }
            }

            if sessionCount > 0 {
                results.append((path: decoded, lastUsed: newestDate, sessionCount: sessionCount))
            }
        }

        // Sort by most recent session first
        results.sort { $0.lastUsed > $1.lastUsed }
        return results.map { (path: $0.path, lastUsed: $0.lastUsed) }
    }

    /// Decode a Claude Code project directory name back to a filesystem path.
    /// Claude encodes "/" as "-", so "-Users-gilles-Documents-ai-trend-finder" must
    /// be decoded by finding which hyphens are path separators and which are literal.
    /// Strategy: greedily build the path left-to-right, checking if each segment exists.
    static func decodeCloudeProjectPath(_ encoded: String) -> String? {
        let stripped = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        let parts = stripped.components(separatedBy: "-")
        guard !parts.isEmpty else { return nil }

        let fm = FileManager.default
        var path = ""
        var segment = parts[0]

        for i in 1..<parts.count {
            let candidate = path + "/" + segment
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                path = candidate
                segment = parts[i]
            } else {
                segment += "-" + parts[i]
            }
        }

        // Append final segment
        path += "/" + segment
        return path
    }
}
