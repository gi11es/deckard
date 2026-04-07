# Project-Level Default Arguments

**Date:** 2026-04-07
**Issue:** [#46 comment](https://github.com/gi11es/deckard/issues/46#issuecomment-4152705055)

## Overview

Add per-project default arguments for Claude Code sessions. The resolution hierarchy is:

```
per-session dialog > project defaults > global defaults
```

Each tier fully replaces the one below it (no merging).

## Data Model

Add `defaultArgs: String?` to both runtime and persistence models:

- **`ProjectItem`** (runtime class): `var defaultArgs: String?`
- **`ProjectState`** (persistence struct): `var defaultArgs: String?`

Semantics:
- `nil` — no project override; fall back to global defaults
- Non-empty string — use exactly these args, ignoring global defaults

Empty string in the UI is treated as "clear the override" and stored as `nil`.

Since the field is optional and `Codable`, existing `state.json` files without it decode with `nil` automatically. No migration needed.

## Argument Resolution

Current logic in `createTabInProject()`:

```swift
let resolvedArgs = extraArgs ?? UserDefaults.standard.string(forKey: "claudeExtraArgs") ?? ""
```

New logic:

```swift
let resolvedArgs = extraArgs ?? project.defaultArgs ?? UserDefaults.standard.string(forKey: "claudeExtraArgs") ?? ""
```

Where `extraArgs` is only present when the per-session prompt is enabled and the user accepted.

## Per-Session Dialog Pre-Fill

When the per-session dialog is shown, it pre-fills with:

```swift
project.defaultArgs ?? UserDefaults.standard.string(forKey: "claudeExtraArgs") ?? ""
```

Instead of always using global defaults. This way the dialog reflects the effective defaults for that project.

## UI: Context Menu + Sheet

### Context Menu

Add a "Default Arguments..." item to `buildProjectContextMenu()` in `SidebarController.swift`. Placement: after "Explore Sessions", before the folder-management section.

The menu item receives the `ProjectItem` as `representedObject`.

### Sheet

The menu action presents an `NSAlert` as a sheet (same pattern as the existing per-session dialog):

- **Title:** "Default Arguments for [project name]"
- **Informative text:** "These arguments will be used for new Claude tabs in this project, overriding global defaults. Leave empty to clear."
- **Accessory view:** `ClaudeArgsField`, pre-filled with `project.defaultArgs ?? ""`
- **Buttons:** "Save" and "Cancel"

On Save:
- If field is empty → set `project.defaultArgs = nil` (clear override)
- If field is non-empty → set `project.defaultArgs = field.stringValue`
- Mark state dirty for autosave

On Cancel: no changes.

## Persistence

`captureState()` copies `project.defaultArgs` into the `ProjectState`.
`restoreOrCreateInitial()` restores `defaultArgs` from `ProjectState` back onto the `ProjectItem`.

## Scope

This feature only affects **new Claude tabs**. Existing tabs (including restored tabs on relaunch) are not retroactively affected — they already had their args baked in at creation time.

## Files Changed

1. **`DeckardWindowController.swift`** — add `defaultArgs` to `ProjectItem`, update `createTabInProject()` resolution and dialog pre-fill
2. **`SessionState.swift`** — add `defaultArgs` to `ProjectState`, update `captureState()` and `restoreOrCreateInitial()`
3. **`SidebarController.swift`** — add context menu item and sheet action
