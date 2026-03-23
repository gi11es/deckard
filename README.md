# Deckard

A terminal built for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Deckard is a native macOS app that treats Claude Code sessions as first-class objects. Each tab knows whether Claude is thinking, waiting for input, or needs tool approval, and tracks context window usage so you know when a session is running low.

Run multiple sessions side by side in a single window with tabs, projects, and session persistence. Built with Swift and AppKit. Terminal rendering powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

[![Download for macOS](https://img.shields.io/static/v1?label=Download+for+macOS&message=v0.6.0&color=black&style=for-the-badge&logo=apple&logoColor=white)](https://github.com/gi11es/deckard/releases/latest) <!-- x-release-please-version -->

![Deckard screenshot](screenshot.jpg)

## Features

- **Multi-tab sessions**: Open multiple Claude Code (and plain terminal) tabs per project. Switch between them with Cmd+1–9 or drag to reorder.
- **Project sidebar**: Organize work by folder. Each project gets its own set of tabs, persisted across restarts.
- **Context usage tracking**: A progress bar shows how much of Claude's context window the active session has consumed.
- **Session state detection**: Tab badges show whether Claude is thinking, waiting for input, needs tool permission, or has errored. Terminal tabs show CPU/disk activity.
- **Session persistence**: Claude sessions resume via `--resume`. Terminal tabs preserve full shell state (scrollback, running processes, environment) across quit/relaunch using tmux when available.
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

## Keyboard Shortcuts

All shortcuts can be customized in Settings → Shortcuts. Defaults:

| Shortcut | Action |
|---|---|
| Cmd+T | New Claude tab |
| Shift+Cmd+T | New terminal tab |
| Cmd+W | Close tab |
| Shift+Cmd+W | Close folder |
| Cmd+1–9 | Jump to tab |
| Shift+Cmd+[ / ] | Previous / next tab |
| Cmd+O | Open folder |
| Ctrl+Cmd+S | Toggle sidebar |
| Cmd+, | Settings |

## How It Works

Deckard wraps the `claude` CLI with a thin hook layer. When Claude Code launches inside a Deckard tab, the wrapper injects lifecycle hooks via a Unix domain socket so the app can track session state, detect context usage, and surface notifications, without modifying Claude Code itself.

## License

MIT
