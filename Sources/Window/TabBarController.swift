import AppKit

// MARK: - Tab Bar Controller Extension

extension DeckardWindowController {

    // MARK: - Tab Bar (horizontal tabs within selected workspace)

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
        guard let workspace = currentWorkspace else { return }

        for (i, tab) in workspace.tabs.enumerated() {
            let isSelected = (i == workspace.selectedTabIndex)
            let title = " \(tab.name) "

            let tabView = HorizontalTabView(
                displayTitle: title,
                editableName: tab.name,
                kind: tab.kind,
                badgeState: tab.badgeState,
                activity: terminalActivity[tab.id],
                isSelected: isSelected,
                index: i,
                target: self,
                clickAction: #selector(tabBarClicked(_:))
            )
            tabView.onRename = { [weak self] newName in
                guard let self = self, let workspace = self.currentWorkspace,
                      i < workspace.tabs.count else { return }
                let tab = workspace.tabs[i]
                tab.name = newName
                if let sid = tab.sessionId, !sid.isEmpty {
                    SessionManager.shared.saveSessionName(sessionId: sid, kind: tab.kind, name: newName)
                }
                self.rebuildTabBar()
                self.saveState()
            }
            tabView.onClearName = { [weak self] in
                guard let self = self, let workspace = self.currentWorkspace,
                      i < workspace.tabs.count else { return }
                let tab = workspace.tabs[i]
                let base = tab.kind.displayName
                let sameType = workspace.tabs.filter { $0.kind == tab.kind }
                tab.name = sameType.count <= 1 ? base : "\(base) #\(i + 1)"
                self.rebuildTabBar()
                self.saveState()
            }
            tabView.onClose = { [weak self] in
                guard let self = self else { return }
                let btn = NSButton()
                btn.tag = i
                self.tabBarCloseClicked(btn)
            }
            tabView.onNewClaude = { [weak self] in
                self?.addTabToCurrentWorkspace(kind: .claude)
            }
            tabView.onNewCodex = { [weak self] in
                self?.addTabToCurrentWorkspace(kind: .codex)
            }
            tabView.onNewTerminal = { [weak self] in
                self?.addTabToCurrentWorkspace(kind: .terminal)
            }
            tabView.onEditingFinished = { [weak self] in
                guard let self = self, self.needsTabBarRebuild else { return }
                self.needsTabBarRebuild = false
                self.rebuildTabBar()
            }
            tabBar.addArrangedSubview(tabView)
        }

        // Set up drag-to-reorder
        tabBar.tabCount = workspace.tabs.count
        tabBar.registerForDraggedTypes([deckardTabDragType])
        tabBar.onReorder = { [weak self] from, to in
            self?.reorderTab(from: from, to: to)
        }

        // Add "+" button
        let addButton = AddTabButton(
            claudeAction: { [weak self] in self?.addTabToCurrentWorkspace(kind: .claude) },
            codexAction: { [weak self] in self?.addTabToCurrentWorkspace(kind: .codex) },
            terminalAction: { [weak self] in self?.addTabToCurrentWorkspace(kind: .terminal) }
        )
        tabBar.addArrangedSubview(addButton)

        // Spacer
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabBar.addArrangedSubview(spacer)
    }

    func reorderTab(from fromIndex: Int, to toIndex: Int) {
        guard let workspace = currentWorkspace else { return }
        guard fromIndex != toIndex,
              fromIndex >= 0, fromIndex < workspace.tabs.count,
              toIndex >= 0, toIndex <= workspace.tabs.count else { return }

        let tab = workspace.tabs.remove(at: fromIndex)
        let insertAt = toIndex > fromIndex ? toIndex - 1 : toIndex
        workspace.tabs.insert(tab, at: min(insertAt, workspace.tabs.count))

        if workspace.selectedTabIndex == fromIndex {
            workspace.selectedTabIndex = insertAt
        } else if fromIndex < workspace.selectedTabIndex && insertAt >= workspace.selectedTabIndex {
            workspace.selectedTabIndex -= 1
        } else if fromIndex > workspace.selectedTabIndex && insertAt <= workspace.selectedTabIndex {
            workspace.selectedTabIndex += 1
        }

        rebuildTabBar()
        rebuildSidebar()
        saveState()
    }

    @objc func tabBarClicked(_ sender: HorizontalTabView) {
        selectTabInWorkspace(at: sender.index)
    }

    @objc func tabBarCloseClicked(_ sender: NSButton) {
        guard let workspace = currentWorkspace else { return }
        let idx = sender.tag
        guard idx >= 0, idx < workspace.tabs.count else { return }

        let tab = workspace.tabs[idx]
        tab.surface.terminate()
        tabCreationOrder.removeAll { $0 == tab.id }

        workspace.tabs.remove(at: idx)

        if workspace.tabs.isEmpty {
            currentTerminalView = nil
            showEmptyState()
            rebuildTabBar()
            rebuildSidebar()
        } else {
            workspace.selectedTabIndex = min(idx, workspace.tabs.count - 1)
            rebuildTabBar()
            rebuildSidebar()
            clearUnseenIfNeeded(workspace.tabs[workspace.selectedTabIndex])
            showTab(workspace.tabs[workspace.selectedTabIndex])
        }
        saveState()
    }
}
