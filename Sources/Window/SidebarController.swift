import AppKit

// MARK: - Sidebar Controller Extension

extension DeckardWindowController {

    // MARK: - Sidebar Helpers

    /// Build `sidebarOrder` from the flat projects array when no order exists yet (migration).
    func ensureSidebarOrder() {
        guard sidebarOrder.isEmpty, !projects.isEmpty else { return }
        sidebarOrder = projects.map { .project($0.id) }
    }

    /// Remove a project from sidebarOrder and all folders' projectIds.
    func removeSidebarReference(projectId: UUID) {
        sidebarOrder.removeAll { item in
            if case .project(let id) = item, id == projectId { return true }
            return false
        }
        for folder in sidebarFolders {
            folder.projectIds.removeAll { $0 == projectId }
        }
    }

    /// Look up a ProjectItem by id.
    func projectById(_ id: UUID) -> ProjectItem? {
        projects.first { $0.id == id }
    }

    /// Returns the flat index into `projects` for a given project id, or -1.
    func projectIndex(forId id: UUID) -> Int {
        projects.firstIndex { $0.id == id } ?? -1
    }

    // MARK: - Sidebar Rebuild

    /// True when any sidebar row is being inline-edited (rename).
    private var isSidebarEditing: Bool {
        sidebarStackView.arrangedSubviews.contains { view in
            if let fv = view as? SidebarFolderView, fv.isEditingName { return true }
            if let rv = view as? VerticalTabRowView, rv.isEditingName { return true }
            return false
        }
    }

    func rebuildSidebar() {
        // Don't tear down the sidebar while the user is renaming an item —
        // the active field editor would be destroyed, causing focus loss.
        if isSidebarEditing { return }

        let savedFR = window?.firstResponder
        defer {
            if let terminal = currentTerminalView, savedFR === terminal,
               window?.firstResponder !== terminal {
                DiagnosticLog.shared.log("sidebar",
                    "rebuildSidebar: focus stolen! restoring terminal view")
                window?.makeFirstResponder(terminal)
            }
        }
        sidebarStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        ensureSidebarOrder()

        // Check current Cmd state to pre-set shortcut indicators on new rows
        let reveal = UserDefaults.standard.object(forKey: "revealProjectNumbers") as? Bool ?? true
        let cmdHeld = reveal && NSEvent.modifierFlags.contains(.command)
        var shortcutForProjectIndex: [Int: String] = [:]
        if cmdHeld {
            for (pos, pi) in projectIndicesInSidebarOrder().prefix(10).enumerated() {
                shortcutForProjectIndex[pi] = "\((pos + 1) % 10)"
            }
        }

        // Map from arranged-subview index to flat project index (for selection highlight).
        // Also used for drag-drop: we store a "sidebar row index" in the pasteboard.
        var sidebarRowToProjectIndex: [Int: Int] = [:]
        var rowIndex = 0

        for sidebarItem in sidebarOrder {
            switch sidebarItem {
            case .project(let projectId):
                guard let project = projectById(projectId) else { continue }
                let pi = projectIndex(forId: projectId)
                let row = VerticalTabRowView(title: project.name, bold: false, index: pi,
                                     target: self, action: #selector(projectRowClicked(_:)))
                row.shortcutBadge = shortcutForProjectIndex[pi]
                row.badgeInfos = project.tabs.filter { $0.badgeState != .none }.map { tab in
                    (state: tab.badgeState, name: tab.name, activity: self.terminalActivity[tab.id])
                }
                row.onRename = { [weak self] newName in
                    guard let self = self else { return }
                    project.name = newName
                    self.saveState()
                }
                row.onClearName = { [weak self] in
                    guard let self = self else { return }
                    project.name = (project.path as NSString).lastPathComponent
                    self.rebuildSidebar()
                    self.saveState()
                }
                row.onContextMenu = { [weak self] event in
                    guard let self = self else { return nil }
                    return self.buildProjectContextMenu(for: project)
                }
                sidebarStackView.addArrangedSubview(row)
                row.leadingAnchor.constraint(equalTo: sidebarStackView.leadingAnchor).isActive = true
                row.trailingAnchor.constraint(equalTo: sidebarStackView.trailingAnchor).isActive = true
                sidebarRowToProjectIndex[rowIndex] = pi
                rowIndex += 1

            case .folder(let folder):
                // Folder header
                let folderView = SidebarFolderView(
                    folder: folder,
                    projectCount: folder.projectIds.count
                )
                folderView.onToggle = { [weak self] fv in
                    self?.folderToggleClicked(fv)
                }
                folderView.onDrop = { [weak self] fv, fromIndex in
                    guard let self else { return }
                    guard fromIndex >= 0, fromIndex < self.projects.count else { return }
                    let project = self.projects[fromIndex]
                    self.moveProjectIntoFolder(projectId: project.id, folder: fv.folder)
                }

                // Aggregate badge infos from all projects in the folder
                var aggregatedBadges: [(state: TabItem.BadgeState, name: String, activity: ProcessMonitor.ActivityInfo?)] = []
                for pid in folder.projectIds {
                    if let project = projectById(pid) {
                        for tab in project.tabs where tab.badgeState != .none {
                            aggregatedBadges.append((state: tab.badgeState, name: tab.name, activity: self.terminalActivity[tab.id]))
                        }
                    }
                }
                folderView.badgeInfos = aggregatedBadges

                folderView.onRename = { [weak self] newName in
                    guard let self = self else { return }
                    folder.name = newName
                    self.saveState()
                }
                folderView.onContextMenu = { [weak self] event in
                    guard let self = self else { return nil }
                    return self.buildFolderContextMenu(for: folder)
                }
                folderView.rowIndex = rowIndex
                sidebarStackView.addArrangedSubview(folderView)
                folderView.leadingAnchor.constraint(equalTo: sidebarStackView.leadingAnchor).isActive = true
                folderView.trailingAnchor.constraint(equalTo: sidebarStackView.trailingAnchor).isActive = true
                rowIndex += 1

                // Render projects inside the folder (if not collapsed)
                if !folder.isCollapsed {
                    for projectId in folder.projectIds {
                        guard let project = projectById(projectId) else { continue }
                        let pi = projectIndex(forId: projectId)
                        let row = VerticalTabRowView(title: project.name, bold: false, index: pi,
                                             target: self, action: #selector(projectRowClicked(_:)))
                        row.indent = 16
                        row.shortcutBadge = shortcutForProjectIndex[pi]
                        row.badgeInfos = project.tabs.filter { $0.badgeState != .none }.map { tab in
                            (state: tab.badgeState, name: tab.name, activity: self.terminalActivity[tab.id])
                        }
                        row.onRename = { [weak self] newName in
                            guard let self = self else { return }
                            project.name = newName
                            self.saveState()
                        }
                        row.onClearName = { [weak self] in
                            guard let self = self else { return }
                            project.name = (project.path as NSString).lastPathComponent
                            self.rebuildSidebar()
                            self.saveState()
                        }
                        row.onContextMenu = { [weak self] event in
                            guard let self = self else { return nil }
                            return self.buildProjectContextMenu(for: project)
                        }
                        sidebarStackView.addArrangedSubview(row)
                        row.leadingAnchor.constraint(equalTo: sidebarStackView.leadingAnchor).isActive = true
                        row.trailingAnchor.constraint(equalTo: sidebarStackView.trailingAnchor).isActive = true
                        sidebarRowToProjectIndex[rowIndex] = pi
                        rowIndex += 1
                    }
                }
            }
        }

        sidebarStackView.registerForDraggedTypes([deckardProjectDragType, deckardSidebarDragType, deckardFolderDragType])
        sidebarStackView.onReorder = { [weak self] from, to in
            self?.handleSidebarDragReorder(fromProjectIndex: from, toRow: to)
        }
        sidebarStackView.onDropOntoFolder = { [weak self] folderView, fromIndex in
            folderView.onDrop?(folderView, fromIndex)
        }
        sidebarStackView.onFolderReorder = { [weak self] fromRow, toRow in
            self?.handleFolderDragReorder(fromRow: fromRow, toRow: toRow)
        }
        sidebarDropZone.onDrop = { [weak self] fromIndex in
            guard let self = self, fromIndex >= 0, fromIndex < self.projects.count else { return }
            let project = self.projects[fromIndex]
            // If the project was inside a folder, move it out first
            if self.sidebarFolders.contains(where: { $0.projectIds.contains(project.id) }) {
                self.moveProjectOutOfFolder(projectId: project.id)
            }
            // Move the sidebarOrder item to the end
            self.sidebarOrder.removeAll { item in
                if case .project(let id) = item, id == project.id { return true }
                return false
            }
            self.sidebarOrder.append(.project(project.id))
            self.reorderProject(from: fromIndex, to: self.projects.count)
        }
        sidebarDropZone.onFolderDrop = { [weak self] fromRow in
            guard let self else { return }
            // Move folder to end of sidebarOrder
            let infos = self.sidebarRowInfos()
            guard fromRow >= 0, fromRow < infos.count, infos[fromRow].isFolder,
                  let folderId = infos[fromRow].folderId else { return }
            guard let orderIdx = self.sidebarOrder.firstIndex(where: {
                if case .folder(let f) = $0, f.id == folderId { return true }
                return false
            }) else { return }
            let item = self.sidebarOrder.remove(at: orderIdx)
            self.sidebarOrder.append(item)
            self.rebuildSidebar()
            self.saveState()
        }
        sidebarDropZone.sidebarStackView = sidebarStackView
        sidebarDropZone.onContextMenu = { [weak self] event in
            let menu = NSMenu()
            let item = NSMenuItem(title: "New Folder", action: #selector(self?.sidebarEmptyContextNewFolder), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return menu
        }

        updateSidebarSelection()
    }

    func reorderProject(from fromIndex: Int, to toIndex: Int) {
        guard fromIndex != toIndex,
              fromIndex >= 0, fromIndex < projects.count,
              toIndex >= 0, toIndex <= projects.count else { return }

        let project = projects.remove(at: fromIndex)
        let insertAt = toIndex > fromIndex ? toIndex - 1 : toIndex
        projects.insert(project, at: min(insertAt, projects.count))

        // Update selected index
        if selectedProjectIndex == fromIndex {
            selectedProjectIndex = insertAt
        } else if fromIndex < selectedProjectIndex && insertAt >= selectedProjectIndex {
            selectedProjectIndex -= 1
        } else if fromIndex > selectedProjectIndex && insertAt <= selectedProjectIndex {
            selectedProjectIndex += 1
        }

        rebuildSidebar()
        saveState()
    }

    // MARK: - Sidebar Row Info

    /// Maps a sidebar stack view row index to a sidebarOrder-aware identifier.
    /// Returns (sidebarOrderIndex, isFolder, isFolderChild, parentFolder, childIndex)
    struct SidebarRowInfo {
        var sidebarOrderIndex: Int
        var isFolder: Bool
        var parentFolder: SidebarFolder?
        var childIndexInFolder: Int?
        var projectId: UUID?
        var folderId: UUID?
    }

    func sidebarRowInfos() -> [SidebarRowInfo] {
        var infos: [SidebarRowInfo] = []
        for (orderIdx, item) in sidebarOrder.enumerated() {
            switch item {
            case .project(let pid):
                infos.append(SidebarRowInfo(
                    sidebarOrderIndex: orderIdx, isFolder: false,
                    parentFolder: nil, childIndexInFolder: nil,
                    projectId: pid, folderId: nil))
            case .folder(let folder):
                infos.append(SidebarRowInfo(
                    sidebarOrderIndex: orderIdx, isFolder: true,
                    parentFolder: nil, childIndexInFolder: nil,
                    projectId: nil, folderId: folder.id))
                if !folder.isCollapsed {
                    for (ci, pid) in folder.projectIds.enumerated() {
                        infos.append(SidebarRowInfo(
                            sidebarOrderIndex: orderIdx, isFolder: false,
                            parentFolder: folder, childIndexInFolder: ci,
                            projectId: pid, folderId: nil))
                    }
                }
            }
        }
        return infos
    }

    // MARK: - Sidebar Drag Handling

    /// Handle drag reorder in the sidebar.
    /// `fromProjectIndex` is the flat projects array index (from the pasteboard).
    /// `toRow` is the stack view row index of the drop target.
    func handleSidebarDragReorder(fromProjectIndex: Int, toRow: Int) {
        guard fromProjectIndex >= 0, fromProjectIndex < projects.count else { return }
        let draggedProject = projects[fromProjectIndex]
        let infos = sidebarRowInfos()
        guard toRow >= 0, toRow < infos.count else {
            // Drop past the end — move to top level at the end
            let wasInFolder = sidebarFolders.contains { $0.projectIds.contains(draggedProject.id) }
            if wasInFolder { moveProjectOutOfFolder(projectId: draggedProject.id) }
            sidebarOrder.removeAll { if case .project(let id) = $0, id == draggedProject.id { return true }; return false }
            sidebarOrder.append(.project(draggedProject.id))
            rebuildSidebar()
            saveState()
            return
        }

        let toInfo = infos[toRow]

        // Note: dropping directly *onto* a folder header (with highlight) is
        // handled separately via onDropOntoFolder in performDragOperation.
        // Here we only handle line-indicator (between-items) drops.

        // Determine the target folder: either the row itself is a folder child,
        // or the row above is (dropping after the last child in a folder).
        let effectiveFolder: SidebarFolder?
        let effectiveChildIndex: Int?
        if let pf = toInfo.parentFolder {
            effectiveFolder = pf
            effectiveChildIndex = toInfo.childIndexInFolder
        } else if toRow > 0, toRow - 1 < infos.count, let prevFolder = infos[toRow - 1].parentFolder {
            // The previous row is a folder child — we're inserting at the end of that folder
            effectiveFolder = prevFolder
            effectiveChildIndex = prevFolder.projectIds.count
        } else {
            effectiveFolder = nil
            effectiveChildIndex = nil
        }

        // Dropping between items inside the same folder → reorder within folder
        let sourceFolder = sidebarFolders.first { $0.projectIds.contains(draggedProject.id) }
        if let targetFolder = effectiveFolder, let sf = sourceFolder, sf.id == targetFolder.id {
            // Reorder within the same folder
            guard let fromIdx = sf.projectIds.firstIndex(of: draggedProject.id),
                  let toIdx = effectiveChildIndex else { return }
            sf.projectIds.remove(at: fromIdx)
            let insertAt = toIdx > fromIdx ? min(toIdx - 1, sf.projectIds.count) : toIdx
            sf.projectIds.insert(draggedProject.id, at: insertAt)
            rebuildSidebar()
            saveState()
            return
        }

        // Dropping between items inside a different folder → move into that folder at position
        if let targetFolder = effectiveFolder {
            // Remove from source folder if needed
            if let sf = sourceFolder {
                sf.projectIds.removeAll { $0 == draggedProject.id }
            } else {
                // Remove from top-level sidebarOrder
                sidebarOrder.removeAll { if case .project(let id) = $0, id == draggedProject.id { return true }; return false }
            }
            // Insert at position in target folder
            let insertAt = toInfo.childIndexInFolder ?? targetFolder.projectIds.count
            if !targetFolder.projectIds.contains(draggedProject.id) {
                targetFolder.projectIds.insert(draggedProject.id, at: min(insertAt, targetFolder.projectIds.count))
            }
            rebuildSidebar()
            saveState()
            return
        }

        // Dropping at top level — reorder in sidebarOrder
        if let sf = sourceFolder {
            sf.projectIds.removeAll { $0 == draggedProject.id }
            // Add as top-level project in sidebarOrder at the target position
            let targetOrderIdx = toInfo.sidebarOrderIndex
            // Remove existing top-level entry if any
            sidebarOrder.removeAll { if case .project(let id) = $0, id == draggedProject.id { return true }; return false }
            sidebarOrder.insert(.project(draggedProject.id), at: min(targetOrderIdx, sidebarOrder.count))
        } else if let targetPid = toInfo.projectId {
            // Both are top-level — reorder sidebarOrder
            if let fromOrderIdx = sidebarOrder.firstIndex(where: {
                if case .project(let id) = $0, id == draggedProject.id { return true }; return false
            }), let targetOrderIdx = sidebarOrder.firstIndex(where: {
                if case .project(let id) = $0, id == targetPid { return true }; return false
            }) {
                let item = sidebarOrder.remove(at: fromOrderIdx)
                let insertIdx = targetOrderIdx > fromOrderIdx ? targetOrderIdx : targetOrderIdx
                sidebarOrder.insert(item, at: min(insertIdx, sidebarOrder.count))
            }
        }

        // Also reorder in the flat projects array
        let fromPi = fromProjectIndex
        if let pid = toInfo.projectId, let toPi = projects.firstIndex(where: { $0.id == pid }), fromPi != toPi {
            reorderProject(from: fromPi, to: toPi)
        } else {
            rebuildSidebar()
            saveState()
        }
    }

    // MARK: - Folder Management

    @objc func sidebarEmptyContextNewFolder() {
        createSidebarFolder()
    }

    func createSidebarFolder(name: String = "New Folder") {
        let folder = SidebarFolder(name: name)
        sidebarFolders.append(folder)
        sidebarOrder.append(.folder(folder))
        rebuildSidebar()
        saveState()
        // Start editing the name immediately
        if let folderView = sidebarStackView.arrangedSubviews.compactMap({ $0 as? SidebarFolderView }).last {
            folderView.startEditing()
        }
    }

    func deleteSidebarFolder(_ folder: SidebarFolder) {
        // Move all projects inside the folder back to top level (ungrouped)
        let orderIndex = sidebarOrder.firstIndex(where: {
            if case .folder(let f) = $0, f.id == folder.id { return true }
            return false
        })

        // Insert ungrouped project items in place of the folder
        if let idx = orderIndex {
            sidebarOrder.remove(at: idx)
            var insertIdx = idx
            for pid in folder.projectIds {
                sidebarOrder.insert(.project(pid), at: insertIdx)
                insertIdx += 1
            }
        }

        sidebarFolders.removeAll { $0.id == folder.id }
        rebuildSidebar()
        saveState()
    }

    func moveProjectIntoFolder(projectId: UUID, folder: SidebarFolder) {
        // Remove project from current location (top-level or another folder)
        sidebarOrder.removeAll { item in
            if case .project(let id) = item, id == projectId { return true }
            return false
        }
        for f in sidebarFolders where f.id != folder.id {
            f.projectIds.removeAll { $0 == projectId }
        }

        // Add to target folder
        if !folder.projectIds.contains(projectId) {
            folder.projectIds.append(projectId)
        }

        // Auto-expand folder when adding projects
        folder.isCollapsed = false

        rebuildSidebar()
        saveState()
    }

    func moveProjectOutOfFolder(projectId: UUID) {
        // Find which folder contains this project
        guard let folder = sidebarFolders.first(where: { $0.projectIds.contains(projectId) }) else { return }
        folder.projectIds.removeAll { $0 == projectId }

        // Insert as ungrouped project right after the folder in sidebarOrder
        if let folderIdx = sidebarOrder.firstIndex(where: {
            if case .folder(let f) = $0, f.id == folder.id { return true }
            return false
        }) {
            sidebarOrder.insert(.project(projectId), at: folderIdx + 1)
        } else {
            sidebarOrder.append(.project(projectId))
        }

        rebuildSidebar()
        saveState()
    }

    func folderToggleClicked(_ sender: SidebarFolderView) {
        let wasCollapsed = sender.folder.isCollapsed
        sender.folder.isCollapsed.toggle()

        // If collapsing a folder that contains the selected project, auto-expand it instead
        if sender.folder.isCollapsed, let current = currentProject,
           sender.folder.projectIds.contains(current.id) {
            sender.folder.isCollapsed = false
        }

        DiagnosticLog.shared.log("sidebar",
            "folderToggle: \(sender.folder.name) was=\(wasCollapsed) now=\(sender.folder.isCollapsed) projects=\(sender.folder.projectIds.count)")

        rebuildSidebar()
        saveState()
    }

    /// Handle drag-reorder of a folder row.
    /// `fromRow` is the row index of the dragged folder, `toRow` is the drop target row.
    func handleFolderDragReorder(fromRow: Int, toRow: Int) {
        let infos = sidebarRowInfos()
        guard fromRow >= 0, fromRow < infos.count, infos[fromRow].isFolder,
              let folderId = infos[fromRow].folderId else { return }

        // Find the folder's index in sidebarOrder
        guard let fromOrderIdx = sidebarOrder.firstIndex(where: {
            if case .folder(let f) = $0, f.id == folderId { return true }
            return false
        }) else { return }

        // Determine target sidebarOrder index
        let targetOrderIdx: Int
        if toRow >= 0, toRow < infos.count {
            targetOrderIdx = infos[toRow].sidebarOrderIndex
        } else {
            targetOrderIdx = sidebarOrder.count
        }

        guard fromOrderIdx != targetOrderIdx else { return }

        let item = sidebarOrder.remove(at: fromOrderIdx)
        let insertIdx = targetOrderIdx > fromOrderIdx ? min(targetOrderIdx - 1, sidebarOrder.count) : min(targetOrderIdx, sidebarOrder.count)
        sidebarOrder.insert(item, at: insertIdx)

        rebuildSidebar()
        saveState()
    }

    // MARK: - Folder Context Menu

    func buildFolderContextMenu(for folder: SidebarFolder) -> NSMenu {
        let menu = NSMenu()

        let renameItem = NSMenuItem(title: "Rename Folder", action: #selector(renameFolderMenuAction(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.representedObject = folder
        menu.addItem(renameItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: "Delete Folder", action: #selector(deleteFolderMenuAction(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = folder
        menu.addItem(deleteItem)

        return menu
    }

    @objc func renameFolderMenuAction(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? SidebarFolder else { return }
        // Find the SidebarFolderView for this folder and start editing
        for view in sidebarStackView.arrangedSubviews {
            if let fv = view as? SidebarFolderView, fv.folder.id == folder.id {
                fv.startEditing()
                break
            }
        }
    }

    @objc func deleteFolderMenuAction(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? SidebarFolder else { return }
        deleteSidebarFolder(folder)
    }

    // MARK: - Project Context Menu

    class ResumeSessionInfo {
        let project: ProjectItem
        let sessionId: String
        let tabName: String?
        init(project: ProjectItem, sessionId: String, tabName: String?) {
            self.project = project
            self.sessionId = sessionId
            self.tabName = tabName
        }
    }

    func buildProjectContextMenu(for project: ProjectItem) -> NSMenu {
        let menu = NSMenu()

        let resumeItem = NSMenuItem(title: "Resume Session", action: nil, keyEquivalent: "")
        let resumeSubmenu = NSMenu()

        let sessions = ContextMonitor.shared.listSessions(forProjectPath: project.path)
        let openSessionIds = Set(project.tabs.compactMap { $0.sessionId })
        let resumable = sessions.filter { !openSessionIds.contains($0.sessionId) }

        if resumable.isEmpty {
            let emptyItem = NSMenuItem(title: "No sessions to resume", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            resumeSubmenu.addItem(emptyItem)
        } else {
            let savedNames = SessionManager.shared.loadSessionNames()
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated

            for session in resumable.prefix(50) {
                let timeStr = formatter.localizedString(for: session.modificationDate, relativeTo: Date())
                let savedName = savedNames[session.sessionId]

                let title: String
                if let name = savedName, !name.isEmpty {
                    title = "\(timeStr) \u{2014} \(name)"
                } else if !session.firstUserMessage.isEmpty {
                    let msg = session.firstUserMessage.count > 60
                        ? String(session.firstUserMessage.prefix(60)) + "\u{2026}"
                        : session.firstUserMessage
                    title = "\(timeStr) \u{2014} \(msg)"
                } else {
                    title = timeStr
                }

                let item = NSMenuItem(title: title, action: #selector(resumeSessionMenuAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ResumeSessionInfo(project: project, sessionId: session.sessionId, tabName: savedName)
                resumeSubmenu.addItem(item)
            }
        }

        resumeItem.submenu = resumeSubmenu
        menu.addItem(resumeItem)

        menu.addItem(.separator())

        // Folder options
        let isInFolder = sidebarFolders.contains { $0.projectIds.contains(project.id) }

        if isInFolder {
            let moveOutItem = NSMenuItem(title: "Move Out of Folder", action: #selector(moveProjectOutOfFolderAction(_:)), keyEquivalent: "")
            moveOutItem.target = self
            moveOutItem.representedObject = project
            menu.addItem(moveOutItem)
        } else if !sidebarFolders.isEmpty {
            let moveToItem = NSMenuItem(title: "Move to Folder", action: nil, keyEquivalent: "")
            let moveSubmenu = NSMenu()
            for folder in sidebarFolders {
                let item = NSMenuItem(title: folder.name, action: #selector(moveProjectToFolderAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = MoveToFolderInfo(project: project, folder: folder)
                moveSubmenu.addItem(item)
            }
            moveToItem.submenu = moveSubmenu
            menu.addItem(moveToItem)
        }

        menu.addItem(.separator())

        let newFolderItem = NSMenuItem(title: "New Folder", action: #selector(newFolderMenuAction), keyEquivalent: "")
        newFolderItem.target = self
        menu.addItem(newFolderItem)

        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: "Close Folder", action: #selector(closeProjectMenuAction(_:)), keyEquivalent: "")
        closeItem.target = self
        closeItem.representedObject = project
        menu.addItem(closeItem)

        return menu
    }

    class MoveToFolderInfo {
        let project: ProjectItem
        let folder: SidebarFolder
        init(project: ProjectItem, folder: SidebarFolder) {
            self.project = project
            self.folder = folder
        }
    }

    @objc func moveProjectToFolderAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? MoveToFolderInfo else { return }
        moveProjectIntoFolder(projectId: info.project.id, folder: info.folder)
    }

    @objc func moveProjectOutOfFolderAction(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? ProjectItem else { return }
        moveProjectOutOfFolder(projectId: project.id)
    }

    @objc func newFolderMenuAction() {
        createSidebarFolder()
    }

    @objc func closeProjectMenuAction(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? ProjectItem,
              let pi = projects.firstIndex(where: { $0.id == project.id }) else { return }
        closeProject(at: pi)
    }

    @objc func resumeSessionMenuAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? ResumeSessionInfo else { return }
        let project = info.project
        let sessionId = info.sessionId

        createTabInProject(project, isClaude: true, name: info.tabName, sessionIdToResume: sessionId)
        project.selectedTabIndex = project.tabs.count - 1

        if let pi = projects.firstIndex(where: { $0.id == project.id }) {
            if pi == selectedProjectIndex {
                rebuildTabBar()
                showTab(project.tabs[project.selectedTabIndex])
            } else {
                selectProject(at: pi)
            }
        }
        saveState()
    }

    // MARK: - Sidebar Selection

    func updateSidebarSelection() {
        guard let currentProjectId = currentProject?.id else {
            for view in sidebarStackView.arrangedSubviews {
                if let row = view as? VerticalTabRowView {
                    row.isSelected = false
                }
            }
            return
        }
        for view in sidebarStackView.arrangedSubviews {
            if let row = view as? VerticalTabRowView {
                row.isSelected = (row.index == selectedProjectIndex)
            } else if let fv = view as? SidebarFolderView {
                // Highlight folder if it contains the selected project
                fv.isContainingSelected = fv.folder.projectIds.contains(currentProjectId) && fv.folder.isCollapsed
            }
        }
    }

    @objc func openProjectClicked() {
        AppDelegate.shared?.openProjectPicker()
    }

    @objc func projectRowClicked(_ sender: VerticalTabRowView) {
        selectProject(at: sender.index)
    }
}
