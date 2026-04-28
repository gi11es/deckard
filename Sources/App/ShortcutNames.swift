import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let openFolder = Self("openFolder", default: .init(.o, modifiers: .command))
    static let newClaudeTab = Self("newClaudeTab", default: .init(.t, modifiers: .command))
    static let newClaudeYoloTab = Self("newClaudeYoloTab", default: .init(.y, modifiers: .command))
    static let newTerminalTab = Self("newTerminalTab", default: .init(.t, modifiers: [.command, .shift]))
    static let closeTab = Self("closeTab", default: .init(.w, modifiers: .command))
    static let closeFolder = Self("closeFolder", default: .init(.w, modifiers: [.command, .shift]))
    static let nextTab = Self("nextTab", default: .init(.rightBracket, modifiers: [.command, .shift]))
    static let previousTab = Self("previousTab", default: .init(.leftBracket, modifiers: [.command, .shift]))
    static let nextProject = Self("nextProject", default: .init(.rightBracket, modifiers: [.command, .option]))
    static let previousProject = Self("previousProject", default: .init(.leftBracket, modifiers: [.command, .option]))
    static let toggleSidebar = Self("toggleSidebar", default: .init(.s, modifiers: [.command, .control]))
    static let exploreSessions = Self("exploreSessions", default: .init(.e, modifiers: [.command, .shift]))
    static let newSidebarFolder = Self("newSidebarFolder", default: .init(.n, modifiers: [.command, .option]))
    static let moveOutOfFolder = Self("moveOutOfFolder", default: .init(.u, modifiers: [.command, .option]))
    static let settings = Self("settings", default: .init(.comma, modifiers: .command))
    static let tab1 = Self("tab1", default: .init(.one, modifiers: .command))
    static let tab2 = Self("tab2", default: .init(.two, modifiers: .command))
    static let tab3 = Self("tab3", default: .init(.three, modifiers: .command))
    static let tab4 = Self("tab4", default: .init(.four, modifiers: .command))
    static let tab5 = Self("tab5", default: .init(.five, modifiers: .command))
    static let tab6 = Self("tab6", default: .init(.six, modifiers: .command))
    static let tab7 = Self("tab7", default: .init(.seven, modifiers: .command))
    static let tab8 = Self("tab8", default: .init(.eight, modifiers: .command))
    static let tab9 = Self("tab9", default: .init(.nine, modifiers: .command))
    static let tab0 = Self("tab0", default: .init(.zero, modifiers: .command))
}

/// All configurable shortcuts with display names, for the settings UI.
struct ShortcutEntry {
    let name: KeyboardShortcuts.Name
    let label: String
}

let configurableShortcuts: [ShortcutEntry] = [
    ShortcutEntry(name: .openFolder, label: "Open Folder"),
    ShortcutEntry(name: .newClaudeTab, label: "New Claude Tab"),
    ShortcutEntry(name: .newClaudeYoloTab, label: "New Claude Yolo Tab"),
    ShortcutEntry(name: .newTerminalTab, label: "New Terminal Tab"),
    ShortcutEntry(name: .closeTab, label: "Close Tab"),
    ShortcutEntry(name: .closeFolder, label: "Close Folder"),
    ShortcutEntry(name: .nextTab, label: "Next Tab"),
    ShortcutEntry(name: .previousTab, label: "Previous Tab"),
    ShortcutEntry(name: .nextProject, label: "Next Project"),
    ShortcutEntry(name: .previousProject, label: "Previous Project"),
    ShortcutEntry(name: .toggleSidebar, label: "Toggle Sidebar"),
    ShortcutEntry(name: .exploreSessions, label: "Explore Sessions"),
    ShortcutEntry(name: .newSidebarFolder, label: "New Sidebar Folder"),
    ShortcutEntry(name: .moveOutOfFolder, label: "Move Out of Folder"),
    ShortcutEntry(name: .settings, label: "Settings"),
    ShortcutEntry(name: .tab1, label: "Project 1"),
    ShortcutEntry(name: .tab2, label: "Project 2"),
    ShortcutEntry(name: .tab3, label: "Project 3"),
    ShortcutEntry(name: .tab4, label: "Project 4"),
    ShortcutEntry(name: .tab5, label: "Project 5"),
    ShortcutEntry(name: .tab6, label: "Project 6"),
    ShortcutEntry(name: .tab7, label: "Project 7"),
    ShortcutEntry(name: .tab8, label: "Project 8"),
    ShortcutEntry(name: .tab9, label: "Project 9"),
    ShortcutEntry(name: .tab0, label: "Project 10"),
]

let tabShortcutNames: [KeyboardShortcuts.Name] = [
    .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9, .tab0,
]
