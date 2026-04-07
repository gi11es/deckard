# Project-Level Default Arguments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-project default arguments for Claude Code sessions with a three-tier resolution hierarchy (per-session dialog > project defaults > global defaults).

**Architecture:** Add `defaultArgs: String?` to the runtime `ProjectItem` class and the persistence `ProjectState` struct, insert a project tier into the argument resolution chain, and expose a "Default Arguments..." context menu item on sidebar projects that opens a sheet with `ClaudeArgsField`.

**Tech Stack:** Swift, AppKit (NSMenu, NSAlert, ClaudeArgsField)

---

### Task 1: Add `defaultArgs` to Data Models

**Files:**
- Modify: `Sources/Window/DeckardWindowController.swift:66-78` (ProjectItem class)
- Modify: `Sources/Session/SessionState.swift:33-39` (ProjectState struct)

- [ ] **Step 1: Add `defaultArgs` property to `ProjectItem`**

In `Sources/Window/DeckardWindowController.swift`, add the property to the `ProjectItem` class:

```swift
class ProjectItem {
    let id: UUID
    var path: String
    var name: String  // basename of path
    var tabs: [TabItem] = []
    var selectedTabIndex: Int = 0
    var defaultArgs: String?

    init(path: String) {
        self.id = UUID()
        self.path = (path as NSString).resolvingSymlinksInPath
        self.name = (self.path as NSString).lastPathComponent
    }
}
```

- [ ] **Step 2: Add `defaultArgs` field to `ProjectState`**

In `Sources/Session/SessionState.swift`, add the field to the `ProjectState` struct:

```swift
struct ProjectState: Codable {
    var id: String
    var path: String
    var name: String
    var selectedTabIndex: Int
    var tabs: [ProjectTabState]
    var defaultArgs: String?
}
```

Since the field is `Optional` and `Codable`, existing `state.json` files without it will decode with `nil` automatically. No migration needed.

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/Window/DeckardWindowController.swift Sources/Session/SessionState.swift
git commit -m "feat: add defaultArgs property to ProjectItem and ProjectState"
```

---

### Task 2: Update Persistence (capture + restore)

**Files:**
- Modify: `Sources/Window/DeckardWindowController.swift:1217-1233` (captureState)
- Modify: `Sources/Window/DeckardWindowController.swift:1289-1308` (restoreOrCreateInitial)

- [ ] **Step 1: Update `captureState()` to persist `defaultArgs`**

In `Sources/Window/DeckardWindowController.swift`, in the `captureState()` method, add `defaultArgs` to the `ProjectState` initializer (around line 1218):

```swift
state.projects = projects.map { project in
    ProjectState(
        id: project.id.uuidString,
        path: project.path,
        name: project.name,
        selectedTabIndex: project.selectedTabIndex,
        tabs: project.tabs.map { tab in
            ProjectTabState(
                id: tab.id.uuidString,
                name: tab.name,
                isClaude: tab.isClaude,
                sessionId: tab.sessionId,
                tmuxSessionName: tab.surface.tmuxSessionName
            )
        },
        defaultArgs: project.defaultArgs
    )
}
```

- [ ] **Step 2: Update `restoreOrCreateInitial()` to restore `defaultArgs`**

In `Sources/Window/DeckardWindowController.swift`, in the restore loop (around line 1290), set `defaultArgs` after creating the `ProjectItem`:

```swift
let project = ProjectItem(path: ps.path)
project.name = ps.name
project.defaultArgs = ps.defaultArgs
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/Window/DeckardWindowController.swift
git commit -m "feat: persist and restore project defaultArgs in state.json"
```

---

### Task 3: Update Argument Resolution and Dialog Pre-Fill

**Files:**
- Modify: `Sources/Window/DeckardWindowController.swift:663` (resolution in createTabInProject)
- Modify: `Sources/Window/DeckardWindowController.swift:716-734` (addTabToCurrentProject — pass project to dialog)
- Modify: `Sources/Window/DeckardWindowController.swift:749-772` (promptForClaudeArgs — accept project defaults)

- [ ] **Step 1: Update argument resolution in `createTabInProject()`**

In `Sources/Window/DeckardWindowController.swift`, change line 663 from:

```swift
let resolvedArgs = extraArgs ?? UserDefaults.standard.string(forKey: "claudeExtraArgs") ?? ""
```

to:

```swift
let resolvedArgs = extraArgs ?? project.defaultArgs ?? UserDefaults.standard.string(forKey: "claudeExtraArgs") ?? ""
```

- [ ] **Step 2: Update `promptForClaudeArgs()` to accept a project parameter for pre-fill**

Change the method signature and pre-fill logic:

```swift
private func promptForClaudeArgs(for project: ProjectItem, completion: @escaping (String?) -> Void) {
    let alert = NSAlert()
    alert.messageText = "Claude Code Arguments"
    alert.informativeText = "Arguments passed to this session:"
    alert.addButton(withTitle: "Start")
    alert.addButton(withTitle: "Cancel")

    let field = ClaudeArgsField(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
    field.stringValue = project.defaultArgs ?? UserDefaults.standard.string(forKey: "claudeExtraArgs") ?? ""
    alert.accessoryView = field

    guard let window else {
        completion(nil)
        return
    }

    alert.beginSheetModal(for: window) { response in
        if response == .alertFirstButtonReturn {
            completion(field.stringValue)
        } else {
            completion(nil)
        }
    }
}
```

- [ ] **Step 3: Update the call site in `addTabToCurrentProject()` to pass the project**

Change line 717 from:

```swift
promptForClaudeArgs { [weak self] args in
```

to:

```swift
promptForClaudeArgs(for: project) { [weak self] args in
```

- [ ] **Step 4: Build to verify compilation**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/Window/DeckardWindowController.swift
git commit -m "feat: three-tier argument resolution with project-level defaults"
```

---

### Task 4: Add Context Menu Item and Sheet

**Files:**
- Modify: `Sources/Window/SidebarController.swift:578-627` (buildProjectContextMenu)
- Modify: `Sources/Window/SidebarController.swift` (new action method)

- [ ] **Step 1: Add "Default Arguments..." menu item to `buildProjectContextMenu()`**

In `Sources/Window/SidebarController.swift`, insert the new item after the "Explore Sessions" item (after line 585, before the separator on line 587):

```swift
let defaultArgsItem = NSMenuItem(title: "Default Arguments\u{2026}", action: #selector(defaultArgsMenuAction(_:)), keyEquivalent: "")
defaultArgsItem.target = self
defaultArgsItem.representedObject = project
menu.addItem(defaultArgsItem)
```

- [ ] **Step 2: Add the action method that presents the sheet**

Add below the `exploreSessionsMenuAction` method (after line 665 area):

```swift
@objc func defaultArgsMenuAction(_ sender: NSMenuItem) {
    guard let project = sender.representedObject as? ProjectItem,
          let window else { return }

    let alert = NSAlert()
    alert.messageText = "Default Arguments for \(project.name)"
    alert.informativeText = "These arguments will be used for new Claude tabs in this project, overriding global defaults. Leave empty to clear."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")

    let field = ClaudeArgsField(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
    field.stringValue = project.defaultArgs ?? ""
    alert.accessoryView = field

    alert.beginSheetModal(for: window) { [weak self] response in
        guard response == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        project.defaultArgs = value.isEmpty ? nil : value
        self?.saveState()
    }
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/Window/SidebarController.swift
git commit -m "feat: add 'Default Arguments' context menu for projects"
```
