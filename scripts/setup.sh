#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GHOSTTY_DIR="$PROJECT_DIR/ghostty"

echo "==> Setting up Deckard development environment"

# Check for Zig
if ! command -v zig &>/dev/null; then
    echo "Error: Zig is not installed. Install it with: brew install zig"
    exit 1
fi

echo "Using Zig: $(zig version)"

# Check for Xcode
if ! command -v xcodebuild &>/dev/null; then
    echo "Error: Xcode is not installed."
    exit 1
fi

# Initialize submodules if needed
if [ ! -f "$GHOSTTY_DIR/build.zig" ]; then
    echo "==> Initializing git submodules"
    cd "$PROJECT_DIR"
    git submodule update --init --recursive
fi

# Check for Metal Toolchain
if ! xcrun -sdk macosx metal --version &>/dev/null 2>&1; then
    echo "==> Downloading Metal Toolchain (required for Ghostty shaders)"
    xcodebuild -downloadComponent MetalToolchain
fi

# Build GhosttyKit.xcframework
XCFRAMEWORK="$GHOSTTY_DIR/macos/GhosttyKit.xcframework"
if [ ! -d "$XCFRAMEWORK" ]; then
    echo "==> Building GhosttyKit.xcframework (this may take a few minutes)"
    cd "$GHOSTTY_DIR"
    zig build -Demit-xcframework -Dxcframework-target=native -Doptimize=ReleaseFast
else
    echo "==> GhosttyKit.xcframework already exists, skipping build"
fi

echo "==> Setup complete!"
echo ""
echo "The xcframework is at: $XCFRAMEWORK"
echo "You can now open Deckard.xcodeproj in Xcode or build with: make build"
