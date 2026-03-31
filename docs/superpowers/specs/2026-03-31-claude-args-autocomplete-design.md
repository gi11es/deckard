# Claude CLI Args Autocomplete — Design Spec

## Overview

Replace the plain text field for Claude CLI start parameters (in Settings and the per-session dialog) with a smart chip-based field that autocompletes CLI flags and their values, powered by dynamically parsing `claude --help` at Deckard startup.

## 1. CLI Flag Discovery & Parsing

### Model

```swift
struct ClaudeFlag {
    let longName: String           // "--permission-mode"
    let shortName: String?         // "-p", "-c", etc.
    let description: String        // "Permission mode to use..."
    let valueType: ValueType       // .boolean, .freeText, .enum([...])
    let valuePlaceholder: String?  // "<mode>", "<path>", etc.
}

enum ValueType {
    case boolean                   // no argument needed
    case freeText                  // user types a value
    case enumeration([String])     // choices parsed from help
}
```

### Parsing strategy

- Run `claude --help` via `Process` at Deckard startup (async, non-blocking).
- Regex-match each option line:
  - `--flag-name <placeholder>` → flag takes a value; no `<>` → boolean.
  - Extract `(choices: "a", "b", "c")` for explicit enums (regex: `\(choices:\s*(.+?)\)` then split on comma).
  - Extract informal enums: when the description ends with a parenthesized comma-separated list of short lowercase words (e.g., `(low, medium, high, max)`), treat as enum. Heuristic: all items ≤20 chars, no spaces within items, 2-8 items.
- Cache the parsed result in memory. Re-parse on next launch.
- If `claude` isn't installed or `--help` fails, degrade gracefully — the field behaves as a plain text field.

### Blocklist

Flags Deckard manages internally, excluded from suggestions:

`--resume`, `--continue`, `--fork-session`, `--print`, `--version`, `--help`, `--output-format`, `--input-format`, `--include-partial-messages`, `--replay-user-messages`, `--json-schema`, `--max-budget-usd`, `--no-session-persistence`, `--fallback-model`, `--from-pr`, `--session-id`

## 2. ClaudeArgsField UI Component

A reusable `NSView` subclass used in both Settings and the per-session dialog.

### Layout

- A styled container view (rounded rect, monospaced font, matching current field appearance).
- Inside: a horizontal flow layout with **chips** (for accepted flags) and an **inline text field** (for typing).
- The text field occupies remaining space after chips, wrapping to next line if needed.

### Chips

- Each chip represents one accepted argument (e.g., `--permission-mode auto` or `--verbose`).
- Styled with a subtle background color, rounded corners, monospaced font.
- Click a chip to select it, press Backspace to delete.
- Chips are not editable — delete and re-add to change.

### Suggestion dropdown

- A floating `NSWindow` positioned below the text field, containing an `NSTableView`.
- Appears automatically when the user starts typing (no trigger key required).
- Each row shows: flag name (bold) + short description (dimmed).
- Fuzzy-filters on the typed text, matching against flag name **without requiring `--` prefix** (typing "perm" matches `--permission-mode`).
- Keyboard: Up/Down to navigate, Tab/Enter to accept, Escape to dismiss.
- Already-added flags are hidden from suggestions (no duplicates).

### Two-step flow for valued flags

1. User types, selects a flag like `--permission-mode` → flag name appears as provisional text.
2. If the flag has **enum values** → dropdown immediately shows the enum choices.
3. If the flag has **free-text value** → dropdown dismisses, user types the value, Enter/Space commits the chip.
4. If the flag is **boolean** → chip is created immediately.

### Serialization

- The field stores its value as a plain string in UserDefaults (same `claudeExtraArgs` key).
- On load: parse the string into chips (split by known flag boundaries).
- On save: join chips back into a CLI string (`--permission-mode auto --verbose`).
- Backward compatible — no migration needed.

## 3. Integration Points

### Settings General Pane (`SettingsWindow.swift`)

- Replace the current `NSTextField` for `claudeExtraArgs` (around line 123) with a `ClaudeArgsField` instance.
- Same grid row, same label, same UserDefaults key.

### Per-Session Dialog (`DeckardWindowController.swift`)

- Replace the `NSTextField` in `promptForClaudeArgs()` (around line 744) with a `ClaudeArgsField`.
- `NSAlert.accessoryView` becomes the `ClaudeArgsField`.
- Slightly wider frame (~400pt) to accommodate chips.

### Startup Parsing (`AppDelegate.swift`)

- On app launch, run `claude --help` via `Process`, parse output into `[ClaudeFlag]`.
- Store as a shared singleton: `ClaudeCLIFlags.shared.flags`.
- Async — don't block app launch. Field works as plain text until parsing completes.
- If `claude` is not found or help fails, `flags` stays empty → plain text behavior.

### File organization

- `Sources/Window/ClaudeArgsField.swift` — the custom NSView (chips + text field + dropdown).
- `Sources/App/ClaudeCLIFlags.swift` — parsing `claude --help`, the `ClaudeFlag` model, blocklist, singleton.

## 4. Testing & Edge Cases

### Unit tests

- **Help parser tests**: feed sample `claude --help` output, verify flags extracted correctly — boolean vs valued vs enum, short names, descriptions, choices parsing (both `(choices: ...)` and informal `(low, medium, high, max)` formats).
- **Blocklist tests**: verify blocked flags are excluded from parsed results.
- **Serialization round-trip**: chips → string → chips produces identical results.

### Edge cases

- `claude` not installed → graceful fallback to plain text field.
- `claude --help` output format changes → parser returns partial results, unrecognized lines skipped.
- User pastes raw args string → parsed into chips on paste.
- Unknown flags (not in help output) → accepted as-is into a chip (don't block the user).
- Duplicate flag entry → already-added flags hidden from dropdown, but not forcibly prevented.

### Not in scope

- Validating flag combinations (e.g., `--fork-session` requires `--resume`).
- Auto-updating the flag list while the app is running (only at launch).
- Persisting the parsed flag data to disk (in-memory only, re-parsed each launch).
