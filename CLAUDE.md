# Deckard

## Build & Run

```bash
# Build
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build

# App location
/Users/gilles/Library/Developer/Xcode/DerivedData/Deckard-hkgvzqxyznptcubawtorcnhugxer/Build/Products/Debug/Deckard.app

# Quit and relaunch (osascript is required — pkill does not work for this app)
osascript -e 'tell application "Deckard" to quit'
open /Users/gilles/Library/Developer/Xcode/DerivedData/Deckard-hkgvzqxyznptcubawtorcnhugxer/Build/Products/Debug/Deckard.app
```

**Always ask for confirmation before restarting Deckard** — do not quit and relaunch the app automatically after a build. Ask the user first.

## Releasing a New Version

### Version locations (update all 4)

1. `Resources/Info.plist` — `CFBundleShortVersionString`
2. `Sources/Window/SettingsWindow.swift` — version label in About pane
3. `Resources/bin/deckard-mcp` — `serverInfo.version` in MCP initialize response
4. `README.md` — download badge version

### Steps

```bash
# 1. Bump version in all 4 files above

# 2. Commit and push
git add Resources/Info.plist Sources/Window/SettingsWindow.swift Resources/bin/deckard-mcp README.md
git commit -m "Bump version to X.Y.Z"
git push

# 3. Wait for CI to pass, then create GitHub release (also creates the git tag)
gh release create vX.Y.Z --repo gi11es/deckard --title "vX.Y.Z" --latest --notes "release notes here"
```

Use `git log vPREVIOUS..HEAD --oneline` to summarize changes for release notes.
