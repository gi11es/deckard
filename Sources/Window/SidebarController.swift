import AppKit
import KeyboardShortcuts

// MARK: - Sidebar Controller Extension

extension DeckardWindowController {

    // MARK: - Sidebar Helpers

    /// Build `sidebarOrder` from the flat workspaces array when no order exists yet (migration).
    func ensureSidebarOrder() {
        guard sidebarOrder.isEmpty, !workspaces.isEmpty else { return }
        sidebarOrder = workspaces.map { .workspace($0.id) }
    }

    /// Remove a workspace from sidebarOrder and all groups' workspaceIds.
    func removeSidebarReference(workspaceId: UUID) {
        sidebarOrder.removeAll { item in
            if case .workspace(let id) = item, id == workspaceId { return true }
            return false
        }
        for group in sidebarGroups {
            group.workspaceIds.removeAll { $0 == workspaceId }
        }
    }

    /// Look up a WorkspaceItem by id.
    func workspaceById(_ id: UUID) -> WorkspaceItem? {
        workspaces.first { $0.id == id }
    }

    /// Returns the flat index into `workspaces` for a given workspace id, or -1.
    func workspaceIndex(forId id: UUID) -> Int {
        workspaces.firstIndex { $0.id == id } ?? -1
    }

    // MARK: - Sidebar Rebuild

    /// True when any sidebar row is being inline-edited (rename).
    private var isSidebarEditing: Bool {
        sidebarStackView.arrangedSubviews.contains { view in
            if let fv = view as? SidebarGroupView, fv.isEditingName { return true }
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

        // Check current modifier state to pre-set shortcut indicators on new rows
        let revealMods = revealNumbersModifiers()
        let cmdHeld = !revealMods.isEmpty && NSEvent.modifierFlags.contains(revealMods)
        var shortcutForWorkspaceIndex: [Int: String] = [:]
        if cmdHeld {
            for (pos, pi) in workspaceIndicesInSidebarOrder().prefix(10).enumerated() {
                shortcutForWorkspaceIndex[pi] = "\((pos + 1) % 10)"
            }
        }

        // Map from arranged-subview index to flat workspace index (for selection highlight).
        // Also used for drag-drop: we store a "sidebar row index" in the pasteboard.
        var sidebarRowToWorkspaceIndex: [Int: Int] = [:]
        var rowIndex = 0

        for sidebarItem in sidebarOrder {
            switch sidebarItem {
            case .workspace(let workspaceId):
                guard let workspace = workspaceById(workspaceId) else { continue }
                let pi = workspaceIndex(forId: workspaceId)
                let row = VerticalTabRowView(title: workspace.name, bold: false, index: pi,
                                     target: self, action: #selector(workspaceRowClicked(_:)))
                row.shortcutBadge = shortcutForWorkspaceIndex[pi]
                row.badgeInfos = workspace.tabs.filter { $0.badgeState != .none }.map { tab in
                    (state: tab.badgeState, name: tab.name, activity: self.terminalActivity[tab.id])
                }
                row.onRename = { [weak self] newName in
                    guard let self = self else { return }
                    workspace.name = newName
                    self.saveState()
                }
                row.onClearName = { [weak self] in
                    guard let self = self else { return }
                    workspace.name = (workspace.path as NSString).lastPathComponent
                    self.rebuildSidebar()
                    self.saveState()
                }
                row.onContextMenu = { [weak self] event in
                    guard let self = self else { return nil }
                    return self.buildWorkspaceContextMenu(for: workspace)
                }
                sidebarStackView.addArrangedSubview(row)
                row.leadingAnchor.constraint(equalTo: sidebarStackView.leadingAnchor).isActive = true
                row.trailingAnchor.constraint(equalTo: sidebarStackView.trailingAnchor).isActive = true
                sidebarRowToWorkspaceIndex[rowIndex] = pi
                rowIndex += 1

            case .group(let group):
                // Group header
                let groupView = SidebarGroupView(
                    group: group,
                    workspaceCount: group.workspaceIds.count
                )
                groupView.onToggle = { [weak self] fv in
                    self?.groupToggleClicked(fv)
                }
                groupView.onDrop = { [weak self] fv, fromIndex in
                    guard let self else { return }
                    guard fromIndex >= 0, fromIndex < self.workspaces.count else { return }
                    let workspace = self.workspaces[fromIndex]
                    self.moveWorkspaceIntoGroup(workspaceId: workspace.id, group: fv.group)
                }

                // Aggregate badge infos from all workspaces in the group
                var aggregatedBadges: [(state: TabItem.BadgeState, name: String, activity: ProcessMonitor.ActivityInfo?)] = []
                for pid in group.workspaceIds {
                    if let workspace = workspaceById(pid) {
                        for tab in workspace.tabs where tab.badgeState != .none {
                            aggregatedBadges.append((state: tab.badgeState, name: tab.name, activity: self.terminalActivity[tab.id]))
                        }
                    }
                }
                groupView.badgeInfos = aggregatedBadges

                groupView.onRename = { [weak self] newName in
                    guard let self = self else { return }
                    group.name = newName
                    self.saveState()
                }
                groupView.onContextMenu = { [weak self] event in
                    guard let self = self else { return nil }
                    return self.buildGroupContextMenu(for: group)
                }
                groupView.rowIndex = rowIndex
                sidebarStackView.addArrangedSubview(groupView)
                groupView.leadingAnchor.constraint(equalTo: sidebarStackView.leadingAnchor).isActive = true
                groupView.trailingAnchor.constraint(equalTo: sidebarStackView.trailingAnchor).isActive = true
                rowIndex += 1

                // Render workspaces inside the group (if not collapsed)
                if !group.isCollapsed {
                    for workspaceId in group.workspaceIds {
                        guard let workspace = workspaceById(workspaceId) else { continue }
                        let pi = workspaceIndex(forId: workspaceId)
                        let row = VerticalTabRowView(title: workspace.name, bold: false, index: pi,
                                             target: self, action: #selector(workspaceRowClicked(_:)))
                        row.indent = 16
                        row.shortcutBadge = shortcutForWorkspaceIndex[pi]
                        row.badgeInfos = workspace.tabs.filter { $0.badgeState != .none }.map { tab in
                            (state: tab.badgeState, name: tab.name, activity: self.terminalActivity[tab.id])
                        }
                        row.onRename = { [weak self] newName in
                            guard let self = self else { return }
                            workspace.name = newName
                            self.saveState()
                        }
                        row.onClearName = { [weak self] in
                            guard let self = self else { return }
                            workspace.name = (workspace.path as NSString).lastPathComponent
                            self.rebuildSidebar()
                            self.saveState()
                        }
                        row.onContextMenu = { [weak self] event in
                            guard let self = self else { return nil }
                            return self.buildWorkspaceContextMenu(for: workspace)
                        }
                        sidebarStackView.addArrangedSubview(row)
                        row.leadingAnchor.constraint(equalTo: sidebarStackView.leadingAnchor).isActive = true
                        row.trailingAnchor.constraint(equalTo: sidebarStackView.trailingAnchor).isActive = true
                        sidebarRowToWorkspaceIndex[rowIndex] = pi
                        rowIndex += 1
                    }
                }
            }
        }

        sidebarStackView.registerForDraggedTypes([deckardWorkspaceDragType, deckardSidebarDragType, deckardGroupDragType])
        sidebarStackView.onReorder = { [weak self] from, to, forceTopLevel in
            self?.handleSidebarDragReorder(fromWorkspaceIndex: from, toRow: to, forceTopLevel: forceTopLevel)
        }
        sidebarStackView.onDropOntoGroup = { [weak self] groupView, fromIndex in
            groupView.onDrop?(groupView, fromIndex)
        }
        sidebarStackView.onGroupReorder = { [weak self] fromRow, toRow in
            self?.handleGroupDragReorder(fromRow: fromRow, toRow: toRow)
        }
        sidebarDropZone.onDrop = { [weak self] fromIndex in
            guard let self = self, fromIndex >= 0, fromIndex < self.workspaces.count else { return }
            let workspace = self.workspaces[fromIndex]
            // If the workspace was inside a group, move it out first
            if self.sidebarGroups.contains(where: { $0.workspaceIds.contains(workspace.id) }) {
                self.moveWorkspaceOutOfGroup(workspaceId: workspace.id)
            }
            // Move the sidebarOrder item to the end
            self.sidebarOrder.removeAll { item in
                if case .workspace(let id) = item, id == workspace.id { return true }
                return false
            }
            self.sidebarOrder.append(.workspace(workspace.id))
            self.reorderWorkspace(from: fromIndex, to: self.workspaces.count)
        }
        sidebarDropZone.onGroupDrop = { [weak self] fromRow in
            guard let self else { return }
            // Move group to end of sidebarOrder
            let infos = self.sidebarRowInfos()
            guard fromRow >= 0, fromRow < infos.count, infos[fromRow].isGroup,
                  let groupId = infos[fromRow].groupId else { return }
            guard let orderIdx = self.sidebarOrder.firstIndex(where: {
                if case .group(let f) = $0, f.id == groupId { return true }
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
            let item = NSMenuItem(title: "New Group", action: #selector(self?.sidebarEmptyContextNewGroup), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return menu
        }

        updateSidebarSelection()
    }

    func reorderWorkspace(from fromIndex: Int, to toIndex: Int) {
        guard fromIndex != toIndex,
              fromIndex >= 0, fromIndex < workspaces.count,
              toIndex >= 0, toIndex <= workspaces.count else { return }

        let workspace = workspaces.remove(at: fromIndex)
        let insertAt = toIndex > fromIndex ? toIndex - 1 : toIndex
        workspaces.insert(workspace, at: min(insertAt, workspaces.count))

        // Update selected index
        if selectedWorkspaceIndex == fromIndex {
            selectedWorkspaceIndex = insertAt
        } else if fromIndex < selectedWorkspaceIndex && insertAt >= selectedWorkspaceIndex {
            selectedWorkspaceIndex -= 1
        } else if fromIndex > selectedWorkspaceIndex && insertAt <= selectedWorkspaceIndex {
            selectedWorkspaceIndex += 1
        }

        rebuildSidebar()
        saveState()
    }

    // MARK: - Sidebar Row Info

    /// Maps a sidebar stack view row index to a sidebarOrder-aware identifier.
    /// Returns (sidebarOrderIndex, isGroup, isGroupChild, parentGroup, childIndex)
    struct SidebarRowInfo {
        var sidebarOrderIndex: Int
        var isGroup: Bool
        var parentGroup: SidebarGroup?
        var childIndexInGroup: Int?
        var workspaceId: UUID?
        var groupId: UUID?
    }

    func sidebarRowInfos() -> [SidebarRowInfo] {
        var infos: [SidebarRowInfo] = []
        for (orderIdx, item) in sidebarOrder.enumerated() {
            switch item {
            case .workspace(let pid):
                infos.append(SidebarRowInfo(
                    sidebarOrderIndex: orderIdx, isGroup: false,
                    parentGroup: nil, childIndexInGroup: nil,
                    workspaceId: pid, groupId: nil))
            case .group(let group):
                infos.append(SidebarRowInfo(
                    sidebarOrderIndex: orderIdx, isGroup: true,
                    parentGroup: nil, childIndexInGroup: nil,
                    workspaceId: nil, groupId: group.id))
                if !group.isCollapsed {
                    for (ci, pid) in group.workspaceIds.enumerated() {
                        infos.append(SidebarRowInfo(
                            sidebarOrderIndex: orderIdx, isGroup: false,
                            parentGroup: group, childIndexInGroup: ci,
                            workspaceId: pid, groupId: nil))
                    }
                }
            }
        }
        return infos
    }

    // MARK: - Sidebar Drag Handling

    /// Handle drag reorder in the sidebar.
    /// `fromWorkspaceIndex` is the flat workspaces array index (from the pasteboard).
    /// `toRow` is the stack view row index of the drop target.
    func handleSidebarDragReorder(fromWorkspaceIndex: Int, toRow: Int, forceTopLevel: Bool = false) {
        guard fromWorkspaceIndex >= 0, fromWorkspaceIndex < workspaces.count else { return }
        let draggedWorkspace = workspaces[fromWorkspaceIndex]
        let infos = sidebarRowInfos()
        guard toRow >= 0, toRow < infos.count else {
            // Drop past the end — move to top level at the end
            let wasInGroup = sidebarGroups.contains { $0.workspaceIds.contains(draggedWorkspace.id) }
            if wasInGroup { moveWorkspaceOutOfGroup(workspaceId: draggedWorkspace.id) }
            sidebarOrder.removeAll { if case .workspace(let id) = $0, id == draggedWorkspace.id { return true }; return false }
            sidebarOrder.append(.workspace(draggedWorkspace.id))
            rebuildSidebar()
            saveState()
            return
        }

        let toInfo = infos[toRow]

        // Note: dropping directly *onto* a group header (with highlight) is
        // handled separately via onDropOntoGroup in performDragOperation.
        // Here we only handle line-indicator (between-items) drops.

        // Determine the target group: either the row itself is a group child,
        // or the row above is (dropping after the last child in a group).
        let effectiveGroup: SidebarGroup?
        let effectiveChildIndex: Int?
        if let pf = toInfo.parentGroup {
            effectiveGroup = pf
            effectiveChildIndex = toInfo.childIndexInGroup
        } else if !forceTopLevel, toRow > 0, toRow - 1 < infos.count, let prevGroup = infos[toRow - 1].parentGroup {
            // The previous row is a group child — we're inserting at the end of that group
            effectiveGroup = prevGroup
            effectiveChildIndex = prevGroup.workspaceIds.count
        } else {
            effectiveGroup = nil
            effectiveChildIndex = nil
        }

        // Dropping between items inside the same group → reorder within group
        let sourceGroup = sidebarGroups.first { $0.workspaceIds.contains(draggedWorkspace.id) }
        if let targetGroup = effectiveGroup, let sf = sourceGroup, sf.id == targetGroup.id {
            // Reorder within the same group
            guard let fromIdx = sf.workspaceIds.firstIndex(of: draggedWorkspace.id),
                  let toIdx = effectiveChildIndex else { return }
            sf.workspaceIds.remove(at: fromIdx)
            let insertAt = toIdx > fromIdx ? min(toIdx - 1, sf.workspaceIds.count) : toIdx
            sf.workspaceIds.insert(draggedWorkspace.id, at: insertAt)
            rebuildSidebar()
            saveState()
            return
        }

        // Dropping between items inside a different group → move into that group at position
        if let targetGroup = effectiveGroup {
            // Remove from source group if needed
            if let sf = sourceGroup {
                sf.workspaceIds.removeAll { $0 == draggedWorkspace.id }
            } else {
                // Remove from top-level sidebarOrder
                sidebarOrder.removeAll { if case .workspace(let id) = $0, id == draggedWorkspace.id { return true }; return false }
            }
            // Insert at position in target group
            let insertAt = toInfo.childIndexInGroup ?? targetGroup.workspaceIds.count
            if !targetGroup.workspaceIds.contains(draggedWorkspace.id) {
                targetGroup.workspaceIds.insert(draggedWorkspace.id, at: min(insertAt, targetGroup.workspaceIds.count))
            }
            rebuildSidebar()
            saveState()
            return
        }

        // Dropping at top level — reorder in sidebarOrder
        if let sf = sourceGroup {
            sf.workspaceIds.removeAll { $0 == draggedWorkspace.id }
            // Add as top-level workspace in sidebarOrder at the target position
            let targetOrderIdx = toInfo.sidebarOrderIndex
            // Remove existing top-level entry if any
            sidebarOrder.removeAll { if case .workspace(let id) = $0, id == draggedWorkspace.id { return true }; return false }
            sidebarOrder.insert(.workspace(draggedWorkspace.id), at: min(targetOrderIdx, sidebarOrder.count))
        } else if let targetPid = toInfo.workspaceId {
            // Both are top-level — reorder sidebarOrder
            if let fromOrderIdx = sidebarOrder.firstIndex(where: {
                if case .workspace(let id) = $0, id == draggedWorkspace.id { return true }; return false
            }), let targetOrderIdx = sidebarOrder.firstIndex(where: {
                if case .workspace(let id) = $0, id == targetPid { return true }; return false
            }) {
                let item = sidebarOrder.remove(at: fromOrderIdx)
                let insertIdx = targetOrderIdx > fromOrderIdx ? targetOrderIdx - 1 : targetOrderIdx
                sidebarOrder.insert(item, at: min(insertIdx, sidebarOrder.count))
            }
        }

        // Also reorder in the flat workspaces array
        let fromPi = fromWorkspaceIndex
        if let pid = toInfo.workspaceId, let toPi = workspaces.firstIndex(where: { $0.id == pid }), fromPi != toPi {
            reorderWorkspace(from: fromPi, to: toPi)
        } else {
            rebuildSidebar()
            saveState()
        }
    }

    // MARK: - Group Management

    @objc func sidebarEmptyContextNewGroup() {
        createSidebarGroup()
    }

    func createSidebarGroup(name: String = "New Group") {
        let group = SidebarGroup(name: name)
        sidebarGroups.append(group)
        sidebarOrder.append(.group(group))
        rebuildSidebar()
        saveState()
        // Start editing the name immediately
        if let groupView = sidebarStackView.arrangedSubviews.compactMap({ $0 as? SidebarGroupView }).last {
            groupView.startEditing()
        }
    }

    func deleteSidebarGroup(_ group: SidebarGroup) {
        // Move all workspaces inside the group back to top level (ungrouped)
        let orderIndex = sidebarOrder.firstIndex(where: {
            if case .group(let f) = $0, f.id == group.id { return true }
            return false
        })

        // Insert ungrouped workspace items in place of the group
        if let idx = orderIndex {
            sidebarOrder.remove(at: idx)
            var insertIdx = idx
            for pid in group.workspaceIds {
                sidebarOrder.insert(.workspace(pid), at: insertIdx)
                insertIdx += 1
            }
        }

        sidebarGroups.removeAll { $0.id == group.id }
        rebuildSidebar()
        saveState()
    }

    func moveWorkspaceIntoGroup(workspaceId: UUID, group: SidebarGroup) {
        // Remove workspace from current location (top-level or another group)
        sidebarOrder.removeAll { item in
            if case .workspace(let id) = item, id == workspaceId { return true }
            return false
        }
        for f in sidebarGroups where f.id != group.id {
            f.workspaceIds.removeAll { $0 == workspaceId }
        }

        // Add to target group
        if !group.workspaceIds.contains(workspaceId) {
            group.workspaceIds.append(workspaceId)
        }

        // Auto-expand group when adding workspaces
        group.isCollapsed = false

        rebuildSidebar()
        saveState()
    }

    func moveWorkspaceOutOfGroup(workspaceId: UUID) {
        // Find which group contains this workspace
        guard let group = sidebarGroups.first(where: { $0.workspaceIds.contains(workspaceId) }) else { return }
        group.workspaceIds.removeAll { $0 == workspaceId }

        // Insert as ungrouped workspace right after the group in sidebarOrder
        if let groupIdx = sidebarOrder.firstIndex(where: {
            if case .group(let f) = $0, f.id == group.id { return true }
            return false
        }) {
            sidebarOrder.insert(.workspace(workspaceId), at: groupIdx + 1)
        } else {
            sidebarOrder.append(.workspace(workspaceId))
        }

        rebuildSidebar()
        saveState()
    }

    func groupToggleClicked(_ sender: SidebarGroupView) {
        let wasCollapsed = sender.group.isCollapsed
        sender.group.isCollapsed.toggle()

        // If collapsing a group that contains the selected workspace, auto-expand it instead
        if sender.group.isCollapsed, let current = currentWorkspace,
           sender.group.workspaceIds.contains(current.id) {
            sender.group.isCollapsed = false
        }

        DiagnosticLog.shared.log("sidebar",
            "groupToggle: \(sender.group.name) was=\(wasCollapsed) now=\(sender.group.isCollapsed) workspaces=\(sender.group.workspaceIds.count)")

        rebuildSidebar()
        saveState()
    }

    /// Handle drag-reorder of a group row.
    /// `fromRow` is the row index of the dragged group, `toRow` is the drop target row.
    func handleGroupDragReorder(fromRow: Int, toRow: Int) {
        let infos = sidebarRowInfos()
        guard fromRow >= 0, fromRow < infos.count, infos[fromRow].isGroup,
              let groupId = infos[fromRow].groupId else { return }

        // Find the group's index in sidebarOrder
        guard let fromOrderIdx = sidebarOrder.firstIndex(where: {
            if case .group(let f) = $0, f.id == groupId { return true }
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

    // MARK: - Group Context Menu

    func buildGroupContextMenu(for group: SidebarGroup) -> NSMenu {
        let menu = NSMenu()

        let renameItem = NSMenuItem(title: "Rename Group", action: #selector(renameGroupMenuAction(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.representedObject = group
        menu.addItem(renameItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: "Delete Group", action: #selector(deleteGroupMenuAction(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = group
        menu.addItem(deleteItem)

        return menu
    }

    @objc func renameGroupMenuAction(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? SidebarGroup else { return }
        // Find the SidebarGroupView for this group and start editing
        for view in sidebarStackView.arrangedSubviews {
            if let fv = view as? SidebarGroupView, fv.group.id == group.id {
                fv.startEditing()
                break
            }
        }
    }

    @objc func deleteGroupMenuAction(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? SidebarGroup else { return }
        deleteSidebarGroup(group)
    }

    // MARK: - Workspace Context Menu

    func buildWorkspaceContextMenu(for workspace: WorkspaceItem) -> NSMenu {
        let menu = NSMenu()

        let exploreItem = NSMenuItem(title: "Explore Sessions", action: #selector(exploreSessionsMenuAction(_:)), keyEquivalent: "")
        exploreItem.setShortcut(for: .exploreSessions)
        exploreItem.target = self
        exploreItem.representedObject = workspace
        menu.addItem(exploreItem)

        let defaultArgsItem = NSMenuItem(title: "Default Claude Arguments\u{2026}", action: #selector(defaultArgsMenuAction(_:)), keyEquivalent: "")
        defaultArgsItem.target = self
        defaultArgsItem.representedObject = workspace
        menu.addItem(defaultArgsItem)

        let defaultCodexArgsItem = NSMenuItem(title: "Default Codex Arguments\u{2026}", action: #selector(defaultCodexArgsMenuAction(_:)), keyEquivalent: "")
        defaultCodexArgsItem.target = self
        defaultCodexArgsItem.representedObject = workspace
        menu.addItem(defaultCodexArgsItem)

        menu.addItem(.separator())

        // Group options
        let isInGroup = sidebarGroups.contains { $0.workspaceIds.contains(workspace.id) }

        if isInGroup {
            let moveOutItem = NSMenuItem(title: "Move Out of Group", action: #selector(moveWorkspaceOutOfGroupAction(_:)), keyEquivalent: "")
            moveOutItem.setShortcut(for: .moveOutOfGroup)
            moveOutItem.target = self
            moveOutItem.representedObject = workspace
            menu.addItem(moveOutItem)
        } else if !sidebarGroups.isEmpty {
            let moveToItem = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
            let moveSubmenu = NSMenu()
            for group in sidebarGroups {
                let item = NSMenuItem(title: group.name, action: #selector(moveWorkspaceToGroupAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = MoveToGroupInfo(workspace: workspace, group: group)
                moveSubmenu.addItem(item)
            }
            moveToItem.submenu = moveSubmenu
            menu.addItem(moveToItem)
        }

        menu.addItem(.separator())

        let newGroupItem = NSMenuItem(title: "New Group", action: #selector(newGroupMenuAction), keyEquivalent: "")
        newGroupItem.setShortcut(for: .newGroup)
        newGroupItem.target = self
        menu.addItem(newGroupItem)

        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: "Close Workspace", action: #selector(closeWorkspaceMenuAction(_:)), keyEquivalent: "")
        closeItem.setShortcut(for: .closeWorkspace)
        closeItem.target = self
        closeItem.representedObject = workspace
        menu.addItem(closeItem)

        return menu
    }

    class MoveToGroupInfo {
        let workspace: WorkspaceItem
        let group: SidebarGroup
        init(workspace: WorkspaceItem, group: SidebarGroup) {
            self.workspace = workspace
            self.group = group
        }
    }

    @objc func moveWorkspaceToGroupAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? MoveToGroupInfo else { return }
        moveWorkspaceIntoGroup(workspaceId: info.workspace.id, group: info.group)
    }

    @objc func moveWorkspaceOutOfGroupAction(_ sender: NSMenuItem) {
        guard let workspace = sender.representedObject as? WorkspaceItem else { return }
        moveWorkspaceOutOfGroup(workspaceId: workspace.id)
    }

    @objc func newGroupMenuAction() {
        createSidebarGroup()
    }

    @objc func closeWorkspaceMenuAction(_ sender: NSMenuItem) {
        guard let workspace = sender.representedObject as? WorkspaceItem,
              let pi = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        closeWorkspace(at: pi)
    }

    @objc func exploreSessionsMenuAction(_ sender: NSMenuItem) {
        guard let workspace = sender.representedObject as? WorkspaceItem else { return }

        // If an explorer window already exists for this workspace, bring it to front
        let expectedTitle = "Sessions — \(workspace.name)"
        for window in NSApp.windows {
            if window.title == expectedTitle,
               objc_getAssociatedObject(window, "explorerController") is SessionExplorerWindowController {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                return
            }
        }

        let explorer = SessionExplorerWindowController(
            workspacePath: workspace.path,
            workspaceName: workspace.name
        )
        explorer.openSessionIds = Set(workspace.tabs.compactMap { $0.sessionCacheKey })
        explorer.onSessionAction = { [weak self] kind, sessionId, fork, tabName in
            guard let self else { return }
            self.createTabInWorkspace(workspace, kind: kind, name: tabName, sessionIdToResume: sessionId, forkSession: fork)
            workspace.selectedTabIndex = workspace.tabs.count - 1
            if let idx = self.workspaces.firstIndex(where: { $0 === workspace }) {
                self.selectWorkspace(at: idx)
            }
            self.rebuildTabBar()
            self.saveState()
        }

        NSApp.activate(ignoringOtherApps: true)
        explorer.showWindow(nil)
        explorer.window?.makeKeyAndOrderFront(nil)

        // Keep a strong reference so the window isn't deallocated
        objc_setAssociatedObject(explorer.window!, "explorerController", explorer, .OBJC_ASSOCIATION_RETAIN)
    }

    @objc func defaultArgsMenuAction(_ sender: NSMenuItem) {
        guard let workspace = sender.representedObject as? WorkspaceItem,
              let window else { return }

        let alert = NSAlert()
        alert.messageText = "Default Arguments for \(workspace.name)"
        alert.informativeText = "These arguments will be used for new Claude tabs in this workspace, overriding global defaults. Leave empty to clear."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = ClaudeArgsField(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        field.stringValue = workspace.defaultArgs ?? ""
        alert.accessoryView = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespaces)
            workspace.defaultArgs = value.isEmpty ? nil : value
            self?.saveState()
        }
    }

    @objc func defaultCodexArgsMenuAction(_ sender: NSMenuItem) {
        guard let workspace = sender.representedObject as? WorkspaceItem,
              let window else { return }

        let alert = NSAlert()
        alert.messageText = "Default Codex Arguments for \(workspace.name)"
        alert.informativeText = "These arguments will be used for new Codex tabs in this workspace, overriding global defaults. Leave empty to clear."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = ClaudeArgsField(
            frame: NSRect(x: 0, y: 0, width: 400, height: 60),
            flagSource: .codex
        )
        field.stringValue = workspace.defaultCodexArgs ?? ""
        alert.accessoryView = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespaces)
            workspace.defaultCodexArgs = value.isEmpty ? nil : value
            self?.saveState()
        }
    }

    // MARK: - Sidebar Selection

    func updateSidebarSelection() {
        guard let currentWorkspaceId = currentWorkspace?.id else {
            for view in sidebarStackView.arrangedSubviews {
                if let row = view as? VerticalTabRowView {
                    row.isSelected = false
                }
            }
            return
        }
        for view in sidebarStackView.arrangedSubviews {
            if let row = view as? VerticalTabRowView {
                row.isSelected = (row.index == selectedWorkspaceIndex)
            } else if let fv = view as? SidebarGroupView {
                // Highlight group if it contains the selected workspace
                fv.isContainingSelected = fv.group.workspaceIds.contains(currentWorkspaceId) && fv.group.isCollapsed
            }
        }
    }

    @objc func openWorkspaceClicked() {
        AppDelegate.shared?.openWorkspacePicker()
    }

    @objc func workspaceRowClicked(_ sender: VerticalTabRowView) {
        selectWorkspace(at: sender.index)
    }
}
