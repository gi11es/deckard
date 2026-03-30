import AppKit

// MARK: - Tab Bar Controller Extension

extension DeckardWindowController {

    // MARK: - Tab Bar (horizontal tabs within selected project)

    var isTabEditing: Bool {
        tabBar.arrangedSubviews.contains { ($0 as? HorizontalTabView)?.isEditing == true }
    }

    func rebuildTabBar() {
        guard !isRebuildingTabBar else { return }
        if isTabEditing {
            needsTabBarRebuild = true
            return
        }
        isRebuildingTabBar = true
        defer {
            isRebuildingTabBar = false
            // Restore focus if the rebuild stole it from the terminal
            if let terminal = currentTerminalView, savedFirstResponder === terminal,
               window?.firstResponder !== terminal {
                DiagnosticLog.shared.log("tabbar",
                    "rebuildTabBar: focus stolen! restoring terminal view")
                window?.makeFirstResponder(terminal)
            }
            savedFirstResponder = nil
        }
        savedFirstResponder = window?.firstResponder

        tabBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let project = currentProject else { return }

        for (i, tab) in project.tabs.enumerated() {
            let isSelected = (i == project.selectedTabIndex)
            let title = " \(tab.name) "

            let tabView = HorizontalTabView(
                displayTitle: title,
                editableName: tab.name,
                isClaude: tab.isClaude,
                badgeState: tab.badgeState,
                activity: terminalActivity[tab.id],
                isSelected: isSelected,
                index: i,
                target: self,
                clickAction: #selector(tabBarClicked(_:))
            )
            tabView.onRename = { [weak self] newName in
                guard let self = self, let project = self.currentProject,
                      i < project.tabs.count else { return }
                let tab = project.tabs[i]
                tab.name = newName
                if let sid = tab.sessionId, !sid.isEmpty {
                    SessionManager.shared.saveSessionName(sessionId: sid, name: newName)
                }
                self.rebuildTabBar()
                self.saveState()
            }
            tabView.onClearName = { [weak self] in
                guard let self = self, let project = self.currentProject,
                      i < project.tabs.count else { return }
                let tab = project.tabs[i]
                let base = tab.isClaude ? "Claude" : "Terminal"
                let sameType = project.tabs.filter { $0.isClaude == tab.isClaude }
                tab.name = sameType.count <= 1 ? base : "\(base) #\(i + 1)"
                self.rebuildTabBar()
                self.saveState()
            }
            tabView.onEditingFinished = { [weak self] in
                guard let self = self, self.needsTabBarRebuild else { return }
                self.needsTabBarRebuild = false
                self.rebuildTabBar()
            }
            tabBar.addArrangedSubview(tabView)
        }

        // Set up drag-to-reorder
        tabBar.tabCount = project.tabs.count
        tabBar.registerForDraggedTypes([deckardTabDragType])
        tabBar.onReorder = { [weak self] from, to in
            self?.reorderTab(from: from, to: to)
        }

        // Add "+" button
        let addButton = AddTabButton(
            leftClickAction: { [weak self] in self?.addTabToCurrentProject(isClaude: true) },
            rightClickAction: { [weak self] in self?.addTabToCurrentProject(isClaude: false) }
        )
        tabBar.addArrangedSubview(addButton)

        // Spacer
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabBar.addArrangedSubview(spacer)
    }

    func reorderTab(from fromIndex: Int, to toIndex: Int) {
        guard let project = currentProject else { return }
        guard fromIndex != toIndex,
              fromIndex >= 0, fromIndex < project.tabs.count,
              toIndex >= 0, toIndex <= project.tabs.count else { return }

        let tab = project.tabs.remove(at: fromIndex)
        let insertAt = toIndex > fromIndex ? toIndex - 1 : toIndex
        project.tabs.insert(tab, at: min(insertAt, project.tabs.count))

        if project.selectedTabIndex == fromIndex {
            project.selectedTabIndex = insertAt
        } else if fromIndex < project.selectedTabIndex && insertAt >= project.selectedTabIndex {
            project.selectedTabIndex -= 1
        } else if fromIndex > project.selectedTabIndex && insertAt <= project.selectedTabIndex {
            project.selectedTabIndex += 1
        }

        rebuildTabBar()
        rebuildSidebar()
        saveState()
    }

    @objc func tabBarClicked(_ sender: HorizontalTabView) {
        selectTabInProject(at: sender.index)
    }

    @objc func tabBarCloseClicked(_ sender: NSButton) {
        guard let project = currentProject else { return }
        let idx = sender.tag
        guard idx >= 0, idx < project.tabs.count else { return }

        let tab = project.tabs[idx]
        tab.surface.terminate()
        tabCreationOrder.removeAll { $0 == tab.id }

        project.tabs.remove(at: idx)

        if project.tabs.isEmpty {
            currentTerminalView = nil
            showEmptyState()
            rebuildTabBar()
            rebuildSidebar()
        } else {
            project.selectedTabIndex = min(idx, project.tabs.count - 1)
            rebuildTabBar()
            rebuildSidebar()
            clearUnseenIfNeeded(project.tabs[project.selectedTabIndex])
            showTab(project.tabs[project.selectedTabIndex])
        }
        saveState()
    }
}
