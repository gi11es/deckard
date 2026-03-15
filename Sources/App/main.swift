import AppKit
import GhosttyKit

// Initialize the Ghostty library before anything else.
let ghosttyResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
guard ghosttyResult == GHOSTTY_SUCCESS else {
    print("Failed to initialize ghostty: \(ghosttyResult)")
    exit(1)
}

// Launch the macOS application.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
