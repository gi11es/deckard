# Deckard

A terminal built for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Deckard is a native macOS app that treats Claude Code sessions as first-class objects. Each tab knows whether Claude is thinking, waiting for input, or needs tool approval, and tracks context window usage so you know when a session is running low.

Run multiple sessions side by side in a single window with tabs, projects, and session persistence. Built with Swift and AppKit. Terminal rendering powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

[![Download for macOS](https://img.shields.io/static/v1?label=Download+for+macOS&message=v0.8.0&color=black&style=for-the-badge&logo=apple&logoColor=white)](https://github.com/gi11es/deckard/releases/latest) <!-- x-release-please-version -->

![Deckard screenshot](screenshot.jpg)

## Features

- **Multi-tab sessions**: Open multiple Claude Code (and plain terminal) tabs per project. Switch between them with Cmd+1–9 or drag to reorder.
- **Project sidebar**: Each open directory gets its own set of tabs, persisted across restarts. Group related projects into collapsible sidebar folders for organization (e.g., by client).
- **Context usage tracking**: A progress bar shows how much of Claude's context window the active session has consumed.
- **Session state detection**: Tab badges show whether Claude is thinking, waiting for input, needs tool permission, or has errored. Terminal tabs show CPU/disk activity.
- **Session persistence**: Claude sessions resume via `--resume`. Tab structure and working directories are preserved across restarts.
- **tmux integration**: When tmux is installed, terminal tabs are transparently wrapped in tmux sessions. Quit and relaunch Deckard to resume exactly where you left off — full shell state, scrollback, running processes, and environment preserved. Works as a progressive enhancement; no tmux required.
- **Terminal rendering**: Powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), a self-contained terminal emulator with VT100/xterm emulation, IME support, and mouse reporting.

## Requirements

- macOS 14.0 (Sonoma) or later
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed
- Xcode 16+ (to build from source)

## Building

Clone and build. SwiftTerm is fetched automatically via Swift Package Manager:

```bash
git clone https://github.com/gi11es/deckard.git
cd deckard
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build
```

The built app will be in your Xcode DerivedData directory.

## How It Works

On launch, Deckard automatically installs two integrations into Claude Code (no manual setup needed):

1. **Lifecycle hooks** — a shell script and entries in `~/.claude/settings.json` that notify Deckard when Claude starts thinking, finishes a response, needs tool approval, or encounters an error. Communication happens over a Unix domain socket.
2. **`/deckard` skill** — a Claude Code slash command (`~/.claude/commands/deckard.md`) for filing bug reports and feature requests directly from a session.

These are installed idempotently on every launch and don't modify Claude Code itself.

## License

MIT
