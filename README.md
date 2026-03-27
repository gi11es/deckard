# Deckard

A terminal built for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Deckard is a native macOS app that treats Claude Code sessions as first-class objects. Each tab knows whether Claude is thinking, waiting for input, or needs tool approval, and tracks context window usage so you know when a session is running low.

Run multiple sessions side by side in a single window with tabs, projects, and session persistence. Built with Swift and AppKit. Terminal rendering powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

<p align="center">
  <a href="https://github.com/gi11es/deckard/releases/latest/download/Deckard.dmg">
    <img alt="Download for macOS" src="https://img.shields.io/badge/-Download_for_macOS-2563eb?style=for-the-badge&logo=apple&logoColor=white" height="56">
  </a>
  <br><br>
  <a href="https://github.com/gi11es/deckard/releases">
    <img alt="Version" src="https://img.shields.io/github/v/release/gi11es/deckard?style=flat-square&label=latest&color=blue">
  </a>
  <img alt="Platform" src="https://img.shields.io/badge/macOS_14+-grey?style=flat-square">
</p>

![Deckard screenshot](screenshot.png)

## Features

- **Multi-tab sessions**: Open multiple Claude Code (and plain terminal) tabs per project. Switch between them with Cmd+1–9 or drag to reorder.
- **Project sidebar**: Each open directory gets its own set of tabs, persisted across restarts. Group related projects into collapsible sidebar folders for organization (e.g., by client).
- **Context & quota tracking**: A progress bar shows context window usage. A sparkline visualizes token rate over time, and rate limit indicators show 5-hour and 7-day quota consumption.
- **Session state detection**: Tab badges show whether Claude is thinking, waiting for input, needs tool permission, or has errored. Terminal tabs show real-time CPU and disk activity for the foreground process.
- **Session persistence**: Claude sessions resume via `--resume`. Tab structure and working directories are preserved across restarts.
- **486 color themes**: Ships with 486 built-in themes (Ghostty format) and loads custom themes from `~/.config/ghostty/themes`. Search and preview in Settings.
- **Customizable shortcuts**: All keyboard shortcuts are rebindable in Settings > Shortcuts.
- **tmux integration**: When tmux is installed, terminal tabs are transparently wrapped in tmux sessions. Quit and relaunch Deckard to resume exactly where you left off — full shell state, scrollback, running processes, and environment preserved. tmux options are editable in Settings > Terminal. Works as a progressive enhancement; no tmux required.
- **Drag and drop**: Drag files from Finder into the terminal — paths are automatically shell-escaped and inserted.
- **Auto-updates**: Built-in update checking via [Sparkle](https://sparkle-project.org/). New releases are delivered automatically.
- **Terminal rendering**: Powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), a self-contained terminal emulator with VT100/xterm emulation, IME support, and mouse reporting.

## Install

**Homebrew:**

```bash
brew install gi11es/tap/deckard
```

**Manual download:** grab the latest [DMG from Releases](https://github.com/gi11es/deckard/releases/latest/download/Deckard.dmg).

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
