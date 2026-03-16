import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let openFolder = Self("openFolder", default: .init(.o, modifiers: .command))
    static let newClaudeTab = Self("newClaudeTab", default: .init(.t, modifiers: .command))
    static let newTerminalTab = Self("newTerminalTab", default: .init(.t, modifiers: [.command, .shift]))
    static let closeTab = Self("closeTab", default: .init(.w, modifiers: .command))
    static let closeFolder = Self("closeFolder", default: .init(.w, modifiers: [.command, .shift]))
    static let nextTab = Self("nextTab", default: .init(.rightBracket, modifiers: [.command, .shift]))
    static let previousTab = Self("previousTab", default: .init(.leftBracket, modifiers: [.command, .shift]))
    static let toggleSidebar = Self("toggleSidebar", default: .init(.s, modifiers: [.command, .control]))
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
}

/// All configurable shortcuts with display names, for the settings UI.
struct ShortcutEntry {
    let name: KeyboardShortcuts.Name
    let label: String
}

let configurableShortcuts: [ShortcutEntry] = [
    ShortcutEntry(name: .openFolder, label: "Open Folder"),
    ShortcutEntry(name: .newClaudeTab, label: "New Claude Tab"),
    ShortcutEntry(name: .newTerminalTab, label: "New Terminal Tab"),
    ShortcutEntry(name: .closeTab, label: "Close Tab"),
    ShortcutEntry(name: .closeFolder, label: "Close Folder"),
    ShortcutEntry(name: .nextTab, label: "Next Tab"),
    ShortcutEntry(name: .previousTab, label: "Previous Tab"),
    ShortcutEntry(name: .toggleSidebar, label: "Toggle Sidebar"),
    ShortcutEntry(name: .settings, label: "Settings"),
    ShortcutEntry(name: .tab1, label: "Tab 1"),
    ShortcutEntry(name: .tab2, label: "Tab 2"),
    ShortcutEntry(name: .tab3, label: "Tab 3"),
    ShortcutEntry(name: .tab4, label: "Tab 4"),
    ShortcutEntry(name: .tab5, label: "Tab 5"),
    ShortcutEntry(name: .tab6, label: "Tab 6"),
    ShortcutEntry(name: .tab7, label: "Tab 7"),
    ShortcutEntry(name: .tab8, label: "Tab 8"),
    ShortcutEntry(name: .tab9, label: "Tab 9"),
]

let tabShortcutNames: [KeyboardShortcuts.Name] = [
    .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9,
]
