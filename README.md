# Deckard

A native macOS workspace for [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [OpenAI Codex](https://openai.com/codex), and classic terminal tabs. Deckard treats agent sessions as first-class tabs: Claude Code and Codex can both be created, resumed, forked, explored, bookmarked, and restored across app launches.

Run multiple agents side by side in a single window with project-aware tabs, session persistence, status badges, and usage telemetry when the underlying CLI exposes it. Built with Swift and AppKit. Terminal rendering is powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

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

![Deckard screenshot](docs/images/screenshot.png?v=60ecfcf0)

## Features

### Claude, Codex, and Terminal Tabs

Open Claude Code, Codex, and plain terminal tabs inside the same project workspace. Agent tabs launch the right CLI directly, while terminal tabs remain normal shells. Switch between tabs with Cmd+1-9 or drag tabs to reorder them.

<img src="docs/images/screenshot-tabs.webp?v=cdf54ee7" alt="Tab bar with agent and terminal tabs" width="600">

### Project Sidebar

Each open directory gets its own persisted tab set. Group related projects into collapsible sidebar folders for organization, and keep different agent runs attached to the project they belong to.

<img src="docs/images/screenshot-sidebar.webp?v=ff3961fc" alt="Project sidebar with folders" width="280">

### Provider-Specific Status Badges

Claude Code and Codex have separate badge states and customizable colors. Claude badges use Deckard's Claude hooks to show thinking, waiting, permission, error, and done-unvisited states. Codex badges are read from Codex rollout events and show idle, working, error, and done-unvisited states. Terminal tabs use their own process-activity badges.

<img src="docs/images/screenshot-status-indicators.webp?v=42af91f8" alt="Status indicator dots" width="250">

### Session Explorer

Browse past Claude Code and Codex sessions with Cmd+Shift+E. The explorer lists both providers for the current project, lets you resume or fork any session, and supports bookmark stars and timeline views.

Fork-at-turn works for both agent providers. For Claude Code, Deckard truncates the Claude session JSONL and resumes with Claude's fork support. For Codex, Deckard creates a truncated Codex rollout file, registers it with Codex's local state database, and launches `codex fork` or `codex resume` as appropriate.

<img src="docs/images/screenshot-session-explorer.webp?v=03aa1cca" alt="Session explorer window" width="600">

### Context, Quota, and Token Rate

Agent usage stats appear only on tabs where Deckard can read real provider data.

| Metric | Claude Code tabs | Codex tabs | Terminal tabs |
| --- | --- | --- | --- |
| Context usage bar | Yes, from Claude session usage entries | No reliable local signal; hidden | No |
| 5-hour quota | Yes, from Claude status-line hook data | Yes, from Codex app-server rate-limit data with rollout fallback | No |
| 7-day quota | Yes, from Claude status-line hook data | Yes, from Codex app-server rate-limit data with rollout fallback | No |
| Tokens per minute | Yes, from recent Claude output token usage | Yes, from recent Codex generated token usage | No |

Classic terminal tabs intentionally do not show agent context, quota, or token-rate panels.

<img src="docs/images/screenshot-context-tracking.png?v=d0e0045b" alt="Context and quota tracking popover" width="250">

### 486 Color Themes

Ships with 486 built-in themes in Ghostty format and loads custom themes from `~/.config/ghostty/themes`. Search and preview in Settings. Status indicator shapes, colors, and blink behavior are fully customizable per provider.

<img src="docs/images/screenshot-themes.webp?v=1fb04fe4" alt="Theme settings with status indicators" width="500">

### More

- **Session persistence**: Claude Code sessions resume with `claude --resume`; Codex sessions resume with `codex resume`. Tab structure and working directories are preserved across restarts.
- **Forking workflows**: Claude Code and Codex sessions can be forked from the explorer, including from a specific user turn.
- **Bookmarks**: Claude Code and Codex sessions use separate bookmark caches so provider sessions with similar IDs do not collide.
- **Customizable shortcuts**: All keyboard shortcuts are rebindable in Settings > Shortcuts, including new Claude, Codex, and terminal tab commands.
- **tmux integration**: When tmux is installed, classic terminal tabs are transparently wrapped in tmux sessions. Quit and relaunch Deckard to resume shell state, scrollback, running processes, and environment. tmux options are editable in Settings > Terminal.
- **Drag and drop**: Drag files from Finder into any terminal surface. Paths are shell-escaped and inserted automatically.
- **Auto-updates**: Built-in update checking via [Sparkle](https://sparkle-project.org/). New releases are delivered automatically.
- **Terminal rendering**: Powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), a self-contained terminal emulator with VT100/xterm emulation, IME support, and mouse reporting.

## Agent Support Matrix

| Workflow | Claude Code | Codex |
| --- | --- | --- |
| Create new agent tab | Yes | Yes |
| Resume existing session | Yes | Yes |
| Fork existing session | Yes | Yes |
| Fork from a specific turn | Yes | Yes |
| Session explorer listing | Yes | Yes |
| Timeline and action view | Yes | Yes |
| Bookmarks | Yes | Yes |
| Provider-specific badges | Yes | Yes |
| Context, quota, token rate | Yes | Quota via Codex app-server; token rate from `token_count` events when present |

Deckard aims for equal day-to-day workflows across Claude Code and Codex. Some telemetry is necessarily provider-specific because the CLIs expose different local data. When Deckard cannot read a metric reliably, it hides that metric instead of showing stale data from another tab or provider.

## Install

**Homebrew:**

```bash
brew install gi11es/tap/deckard
```

**Manual download:** grab the latest [DMG from Releases](https://github.com/gi11es/deckard/releases/latest/download/Deckard.dmg).

## Requirements

- macOS 14.0 (Sonoma) or later
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed to use Claude tabs
- [Codex CLI](https://openai.com/codex/get-started/) installed to use Codex tabs
- Xcode 16+ to build from source

Deckard can be used with only Claude Code, only Codex, or both installed. Terminal tabs work without either agent CLI.

## Building

Clone and build. SwiftTerm is fetched automatically via Swift Package Manager:

```bash
git clone https://github.com/gi11es/deckard.git
cd deckard
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build
```

The built app will be in your Xcode DerivedData directory.

## How It Works

Deckard integrates with each provider using the local state that provider already writes.

**Claude Code**

On launch, Deckard installs Claude Code integrations idempotently:

1. **Lifecycle hooks**: a shell script and entries in `~/.claude/settings.json` notify Deckard when Claude starts thinking, finishes a response, needs tool approval, encounters an error, or emits status-line quota data. Communication happens over a Unix domain socket.
2. **`/deckard` skill**: a Claude Code slash command at `~/.claude/commands/deckard.md` for filing bug reports and feature requests directly from a session.

Deckard reads Claude session JSONL files under `~/.claude/projects` for session discovery, timelines, context usage, resume, and fork-at-turn.

**Codex**

Deckard reads Codex rollout files under `~/.codex/sessions` and the local Codex state database at `~/.codex/state_5.sqlite`. That provides project-scoped session discovery, resume, fork, fork-at-turn, timeline parsing, badges, and token-rate calculation when Codex has written the corresponding events.

For Codex quota, Deckard keeps a local `codex app-server --listen stdio://` JSON-RPC connection open while needed and calls `account/rateLimits/read`, falling back to rollout `token_count` rate-limit events if the app-server data is unavailable.

Deckard does not install Codex hooks. It launches the Codex CLI directly with `codex`, `codex resume`, or `codex fork`.

**Terminal**

Classic terminal tabs are normal shells, optionally tmux-backed. They do not participate in agent session discovery and do not show agent context, quota, or token-rate telemetry.

## License

MIT
