import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let openWorkspace = Self("openWorkspace", default: .init(.o, modifiers: .command))
    static let newClaudeTab = Self("newClaudeTab", default: .init(.t, modifiers: .command))
    static let newCodexTab = Self("newCodexTab", default: .init(.t, modifiers: [.command, .option]))
    static let newTerminalTab = Self("newTerminalTab", default: .init(.t, modifiers: [.command, .shift]))
    static let closeTab = Self("closeTab", default: .init(.w, modifiers: .command))
    static let closeWorkspace = Self("closeWorkspace", default: .init(.w, modifiers: [.command, .shift]))
    static let nextTab = Self("nextTab", default: .init(.rightBracket, modifiers: [.command, .shift]))
    static let previousTab = Self("previousTab", default: .init(.leftBracket, modifiers: [.command, .shift]))
    static let nextWorkspace = Self("nextWorkspace", default: .init(.rightBracket, modifiers: [.command, .option]))
    static let previousWorkspace = Self("previousWorkspace", default: .init(.leftBracket, modifiers: [.command, .option]))
    static let toggleSidebar = Self("toggleSidebar", default: .init(.s, modifiers: [.command, .control]))
    static let exploreSessions = Self("exploreSessions", default: .init(.e, modifiers: [.command, .shift]))
    static let newGroup = Self("newGroup", default: .init(.n, modifiers: [.command, .option]))
    static let moveOutOfGroup = Self("moveOutOfGroup", default: .init(.u, modifiers: [.command, .option]))
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
    ShortcutEntry(name: .openWorkspace, label: "Open Workspace"),
    ShortcutEntry(name: .newClaudeTab, label: "New Claude Tab"),
    ShortcutEntry(name: .newCodexTab, label: "New Codex Tab"),
    ShortcutEntry(name: .newTerminalTab, label: "New Terminal Tab"),
    ShortcutEntry(name: .closeTab, label: "Close Tab"),
    ShortcutEntry(name: .closeWorkspace, label: "Close Workspace"),
    ShortcutEntry(name: .nextTab, label: "Next Tab"),
    ShortcutEntry(name: .previousTab, label: "Previous Tab"),
    ShortcutEntry(name: .nextWorkspace, label: "Next Workspace"),
    ShortcutEntry(name: .previousWorkspace, label: "Previous Workspace"),
    ShortcutEntry(name: .toggleSidebar, label: "Toggle Sidebar"),
    ShortcutEntry(name: .exploreSessions, label: "Explore Sessions"),
    ShortcutEntry(name: .newGroup, label: "New Group"),
    ShortcutEntry(name: .moveOutOfGroup, label: "Move Out of Group"),
    ShortcutEntry(name: .settings, label: "Settings"),
    ShortcutEntry(name: .tab1, label: "Workspace 1"),
    ShortcutEntry(name: .tab2, label: "Workspace 2"),
    ShortcutEntry(name: .tab3, label: "Workspace 3"),
    ShortcutEntry(name: .tab4, label: "Workspace 4"),
    ShortcutEntry(name: .tab5, label: "Workspace 5"),
    ShortcutEntry(name: .tab6, label: "Workspace 6"),
    ShortcutEntry(name: .tab7, label: "Workspace 7"),
    ShortcutEntry(name: .tab8, label: "Workspace 8"),
    ShortcutEntry(name: .tab9, label: "Workspace 9"),
    ShortcutEntry(name: .tab0, label: "Workspace 10"),
]

let tabShortcutNames: [KeyboardShortcuts.Name] = [
    .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9, .tab0,
]

/// One-shot migration that copies user shortcut overrides from old identifier
/// names to new ones, then deletes the old keys. Guarded by a UserDefaults
/// flag so it only runs once. KeyboardShortcuts persists each override under
/// `KeyboardShortcuts_<name>` (see KeyboardShortcuts.swift in the upstream).
enum DeckardShortcutMigration {
    static let migrationFlagKey = "shortcutsMigratedToWorkspaceAndGroupNames"

    /// Old identifier → new identifier renames covering both the folder→group
    /// and project→workspace renames in the folder/project terminology refactor.
    static let renames: [(oldName: String, newName: String)] = [
        ("newSidebarFolder", "newGroup"),
        ("moveOutOfFolder", "moveOutOfGroup"),
        ("openFolder", "openWorkspace"),
        ("closeFolder", "closeWorkspace"),
        ("nextProject", "nextWorkspace"),
        ("previousProject", "previousWorkspace"),
    ]

    static func migrate(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migrationFlagKey) else { return }
        for (oldName, newName) in renames {
            let oldKey = "KeyboardShortcuts_\(oldName)"
            let newKey = "KeyboardShortcuts_\(newName)"
            // Only carry over if the user actually set an override on the old name
            // and hasn't already set one on the new name.
            guard defaults.object(forKey: oldKey) != nil else { continue }
            if defaults.object(forKey: newKey) == nil,
               let value = defaults.object(forKey: oldKey) {
                defaults.set(value, forKey: newKey)
            }
            defaults.removeObject(forKey: oldKey)
        }
        defaults.set(true, forKey: migrationFlagKey)
    }
}

enum DeckardShortcutPolicy {
    static func disableGlobalHotKeys() {
        KeyboardShortcuts.disable(configurableShortcuts.map(\.name))
    }

    static func rejectionReason(for shortcut: KeyboardShortcuts.Shortcut) -> String? {
        let modifiers = shortcut.modifiers.intersection([.command, .shift, .option, .control])

        if shortcut.key == .tab,
           modifiers.contains(.command),
           modifiers.subtracting([.command, .shift]).isEmpty {
            return "Command-Tab and Command-Shift-Tab are reserved by macOS for app switching. Use Command-Option-Left/Right or another combination."
        }

        if modifiers.contains(.option),
           modifiers.subtracting([.option, .shift]).isEmpty {
            return "Option-only shortcuts are reserved by macOS text input and can fail or interfere with typing. Add Command or Control."
        }

        return nil
    }
}
