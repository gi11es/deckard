import AppKit
import Carbon.HIToolbox
import GhosttyKit

/// Callback context stored as the surface's userdata.
/// Lets us route callbacks back to the right tab/surface.
final class SurfaceCallbackContext {
    weak var view: TerminalNSView?
    let surfaceId: UUID
    var tabId: UUID

    init(view: TerminalNSView, surfaceId: UUID, tabId: UUID) {
        self.view = view
        self.surfaceId = surfaceId
        self.tabId = tabId
    }
}

/// The NSView that hosts a single libghostty terminal surface.
/// This view is passed to ghostty which sets up Metal rendering on it.
class TerminalNSView: NSView {
    let surfaceId: UUID
    var tabId: UUID?

    private(set) var surface: ghostty_surface_t?
    private var callbackContext: Unmanaged<SurfaceCallbackContext>?
    private var eventMonitor: Any?
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    /// Tracks the last keyUp event number handled, to prevent double delivery
    /// from both the local event monitor and the normal responder chain.
    private var lastHandledKeyUpEventNumber: Int = -1

    var title: String = ""
    var pwd: String?
    var needsOverlay: Bool = false

    override var acceptsFirstResponder: Bool { true }

    init(surfaceId: UUID = UUID()) {
        self.surfaceId = surfaceId
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        wantsLayer = true
        layer?.masksToBounds = true

        // Listen for key-up events that may not reach us through the normal responder chain
        // (e.g., Cmd+key combos where keyUp goes to the window).
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            guard let self = self, self === self.window?.firstResponder else { return event }
            self.keyUp(with: event)
            return event
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        destroySurface()
    }

    // MARK: - Surface Lifecycle

    func createSurface(app: ghostty_app_t, tabId: UUID, workingDirectory: String? = nil, command: String? = nil, envVars: [String: String] = [:], initialInput: String? = nil) {
        self.tabId = tabId

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))

        let ctx = SurfaceCallbackContext(view: self, surfaceId: surfaceId, tabId: tabId)
        let unmanagedCtx = Unmanaged.passRetained(ctx)
        surfaceConfig.userdata = unmanagedCtx.toOpaque()
        callbackContext?.release()
        callbackContext = unmanagedCtx

        surfaceConfig.scale_factor = Double(window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_TAB

        // Build environment variables
        var allEnvVars = envVars
        allEnvVars["DECKARD_SURFACE_ID"] = surfaceId.uuidString
        allEnvVars["DECKARD_TAB_ID"] = tabId.uuidString
        allEnvVars["DECKARD_SOCKET_PATH"] = ControlSocket.shared.path

        // Set our bin/ directory so the shell can prepend it to PATH.
        // We can't set PATH directly because the login shell resets it.
        if let binPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            allEnvVars["DECKARD_BIN_DIR"] = binPath
        }

        // Convert env vars to C representation
        var cEnvVars: [ghostty_env_var_s] = []
        var cEnvStorage: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []

        for (key, value) in allEnvVars {
            guard let keyPtr = strdup(key), let valuePtr = strdup(value) else { continue }
            cEnvStorage.append((keyPtr, valuePtr))
            cEnvVars.append(ghostty_env_var_s(key: keyPtr, value: valuePtr))
        }

        let envCount = cEnvVars.count
        let createSurfaceCall = { [self] in
            if !cEnvVars.isEmpty {
                cEnvVars.withUnsafeMutableBufferPointer { buffer in
                    surfaceConfig.env_vars = buffer.baseAddress
                    surfaceConfig.env_var_count = envCount
                    self.surface = ghostty_surface_new(app, &surfaceConfig)
                }
            } else {
                self.surface = ghostty_surface_new(app, &surfaceConfig)
            }
        }

        // Helper to set optional C strings on the config and then create
        func configureAndCreate() {
            let setAndCreate = { [self] (wd: UnsafePointer<CChar>?, cmd: UnsafePointer<CChar>?, input: UnsafePointer<CChar>?) in
                surfaceConfig.working_directory = wd
                surfaceConfig.command = cmd
                surfaceConfig.initial_input = input
                createSurfaceCall()
            }

            // Nest withCString calls so all pointers remain valid
            (workingDirectory ?? "").withCString { cwd in
                (command ?? "").withCString { cmd in
                    (initialInput ?? "").withCString { input in
                        setAndCreate(
                            workingDirectory?.isEmpty == false ? cwd : nil,
                            command?.isEmpty == false ? cmd : nil,
                            initialInput?.isEmpty == false ? input : nil
                        )
                    }
                }
            }
        }
        configureAndCreate()

        // Clean up C strings
        for (key, value) in cEnvStorage {
            free(key)
            free(value)
        }

        if surface == nil {
            callbackContext?.release()
            callbackContext = nil
            print("Failed to create ghostty surface for tab \(tabId)")
        }

        updateTrackingAreas()
        registerForDraggedTypes([.string, .fileURL])
    }

    func destroySurface() {
        let surface = self.surface
        let ctx = self.callbackContext
        self.surface = nil
        self.callbackContext = nil

        // Remove from view hierarchy first so the renderer stops drawing.
        removeFromSuperview()

        // Free the ghostty surface on a background queue to avoid deadlocking
        // the main thread with the renderer's lock (see issue #5).
        if let surface = surface {
            DispatchQueue.global(qos: .utility).async {
                ghostty_surface_free(surface)
                ctx?.release()
            }
        } else {
            ctx?.release()
        }
    }

    // MARK: - View Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        updateSurfaceSize()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        // When a hidden tab becomes visible again (e.g. after a screen/DPI
        // change while it was in the background), refresh the content scale
        // so the Metal layer renders at the correct resolution.
        guard let surface = self.surface, let window = self.window else { return }
        let scale = window.backingScaleFactor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        CATransaction.commit()
        ghostty_surface_set_content_scale(surface, scale, scale)
        updateSurfaceSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface = self.surface else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

        // Update the layer's contentsScale so Core Animation composites at
        // the correct resolution instead of scaling the old backing store.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        CATransaction.commit()

        ghostty_surface_set_content_scale(surface, scale, scale)
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface = self.surface else { return }
        let scaledSize = convertToBacking(bounds.size)
        guard scaledSize.width > 0 && scaledSize.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(scaledSize.width), UInt32(scaledSize.height))
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            surface.map { ghostty_surface_set_focus($0, true) }
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            surface.map { ghostty_surface_set_focus($0, false) }
        }
        return result
    }

    // MARK: - Mouse Events

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface = self.surface else { return }
        let mods = Self.ghosttyMods(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface = self.surface else { return }
        let mods = Self.ghosttyMods(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface = self.surface else { return }
        let mods = Self.ghosttyMods(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface = self.surface else { return }
        let mods = Self.ghosttyMods(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
        guard let surface = self.surface else { return }
        let mods = Self.ghosttyMods(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, mods)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseUp(with: event); return }
        guard let surface = self.surface else { return }
        let mods = Self.ghosttyMods(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, mods)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDragged(with: event); return }
        guard let surface = self.surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        let mods = Self.ghosttyMods(from: event)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, mods)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface = self.surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        let mods = Self.ghosttyMods(from: event)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, mods)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface = self.surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        let mods = Self.ghosttyMods(from: event)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, mods)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let surface = self.surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        let mods = Self.ghosttyMods(from: event)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, mods)
    }

    override func mouseEntered(with event: NSEvent) {
        guard let surface = self.surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        let mods = Self.ghosttyMods(from: event)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, mods)
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface = self.surface else { return }
        // If a button is held (drag in progress), don't reset — we still
        // get drag events outside the viewport.
        if NSEvent.pressedMouseButtons != 0 { return }
        let mods = Self.ghosttyMods(from: event)
        ghostty_surface_mouse_pos(surface, -1, -1, mods)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = self.surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            x *= 2
            y *= 2
        }
        var mods: ghostty_input_scroll_mods_t = 0
        if precision {
            mods |= 1 // precision bit
        }
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    // MARK: - Keyboard Events

    /// Build a ghostty key input struct from an NSEvent.
    /// The `mods` field is always set to the ORIGINAL event modifiers (per API contract).
    /// Translation mods are used only for consumed_mods and NSEvent reconstruction.
    private func ghosttyKeyInput(for event: NSEvent, translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var input = ghostty_input_key_s()
        input.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        input.keycode = UInt32(event.keyCode)
        input.composing = false

        // Always send original mods — the API contract requires this.
        input.mods = Self.ghosttyMods(from: event)

        // consumed_mods: control and command never contribute to text translation.
        let consumedFlags = (translationMods ?? event.modifierFlags)
            .subtracting([.control, .command])
        input.consumed_mods = Self.ghosttyMods(fromCocoa: consumedFlags)

        // Unshifted codepoint = the key without any modifiers applied.
        // Use characters(byApplyingModifiers:[]) for accuracy (charactersIgnoringModifiers
        // changes behavior with ctrl pressed).
        if event.type == .keyDown || event.type == .keyUp {
            if let chars = event.characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first,
               codepoint.value < 0xF700 {
                input.unshifted_codepoint = codepoint.value
            }
        }

        return input
    }

    /// Compute translation modifiers and optionally reconstruct the NSEvent.
    /// Returns (translationEvent, translationMods) — the event to pass to
    /// interpretKeyEvents and the modifier flags used for its reconstruction.
    private func translationEvent(for event: NSEvent) -> (NSEvent, NSEvent.ModifierFlags) {
        guard let surface = self.surface else { return (event, event.modifierFlags) }

        let rawMods = Self.ghosttyMods(from: event)
        let translatedGhostty = ghostty_surface_key_translation_mods(surface, rawMods)

        // Convert back to NSEvent.ModifierFlags, preserving hidden bits
        // (important for dead key handling).
        let translatedNS = Self.cocoaMods(from: translatedGhostty)
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translatedNS.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        // Reuse the original event when mods match — required for Korean IME
        // (AppKit relies on object identity internally).
        if translationMods == event.modifierFlags {
            return (event, event.modifierFlags)
        }

        let reconstructed = NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: translationMods,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters(byApplyingModifiers: translationMods) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event

        return (reconstructed, translationMods)
    }

    override func keyDown(with event: NSEvent) {
        guard let surface = self.surface else { return }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Fast path for Ctrl+key — bypass interpretKeyEvents for deterministic
        // terminal control characters (Ctrl+C, Ctrl+D, etc.)
        let eventFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if eventFlags.contains(.control) && !eventFlags.contains(.command)
            && !eventFlags.contains(.option) && !hasMarkedText() {
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = action
            keyEvent.keycode = UInt32(event.keyCode)
            keyEvent.mods = Self.ghosttyMods(from: event)
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.composing = false
            if let chars = event.characters(byApplyingModifiers: []),
               let scalar = chars.unicodeScalars.first {
                keyEvent.unshifted_codepoint = scalar.value
            }

            let text = event.charactersIgnoringModifiers ?? event.characters ?? ""
            if text.isEmpty {
                keyEvent.text = nil
                _ = ghostty_surface_key(surface, keyEvent)
            } else {
                text.withCString { ptr in
                    keyEvent.text = ptr
                    _ = ghostty_surface_key(surface, keyEvent)
                }
            }
            return
        }

        // Normal path: mod translation + interpretKeyEvents
        let (translationEvt, translationMods) = translationEvent(for: event)

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0

        // Capture keyboard layout ID to detect IME switches
        let keyboardIdBefore: String? = if !markedTextBefore {
            Self.currentKeyboardLayoutId()
        } else {
            nil
        }

        interpretKeyEvents([translationEvt])

        // If the keyboard layout changed, an IME consumed the event
        if !markedTextBefore && keyboardIdBefore != Self.currentKeyboardLayoutId() {
            syncPreedit(clearIfNeeded: markedTextBefore)
            return
        }

        syncPreedit(clearIfNeeded: markedTextBefore)

        // Build the key event
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = Self.ghosttyMods(from: event)
        // Consumed mods: control and command never contribute to text translation
        // (Ghostty NSEvent+Extension.swift, MIT licensed).
        keyEvent.consumed_mods = Self.ghosttyMods(fromCocoa:
            translationMods.subtracting([.control, .command]))
        if let chars = event.characters(byApplyingModifiers: []),
           let scalar = chars.unicodeScalars.first {
            keyEvent.unshifted_codepoint = scalar.value
        }
        keyEvent.composing = markedText.length > 0 || markedTextBefore

        let accumulatedText = keyTextAccumulator ?? []
        if !accumulatedText.isEmpty {
            // Text from interpretKeyEvents (IME composition result)
            keyEvent.composing = false
            for text in accumulatedText {
                // Only send text with printable first byte (>= 0x20).
                // Control characters are encoded by Ghostty itself.
                // (Ghostty keyAction pattern, MIT licensed)
                if let codepoint = text.utf8.first, codepoint >= 0x20 {
                    text.withCString { ptr in
                        keyEvent.text = ptr
                        _ = ghostty_surface_key(surface, keyEvent)
                    }
                } else {
                    keyEvent.text = nil
                    _ = ghostty_surface_key(surface, keyEvent)
                }
            }
        } else {
            // No accumulated text — extract characters from the event
            // (Ghostty ghosttyCharacters pattern, MIT licensed)
            if let text = Self.ghosttyCharacters(for: translationEvt),
               let codepoint = text.utf8.first, codepoint >= 0x20,
               !keyEvent.composing {
                text.withCString { ptr in
                    keyEvent.text = ptr
                    _ = ghostty_surface_key(surface, keyEvent)
                }
            } else {
                keyEvent.text = nil
                _ = ghostty_surface_key(surface, keyEvent)
            }
        }
    }

    /// Extract the terminal-appropriate characters from a key event.
    /// Based on Ghostty's `ghosttyCharacters` (MIT, NSEvent+Extension.swift).
    /// Control characters are re-extracted without the Ctrl modifier so
    /// Ghostty's KeyEncoder can apply its own encoding. Function key
    /// characters (Private Use Area) are filtered out.
    private static func ghosttyCharacters(for event: NSEvent) -> String? {
        guard let characters = event.characters, !characters.isEmpty else { return nil }
        guard characters.count == 1,
              let scalar = characters.unicodeScalars.first else {
            return characters
        }
        if scalar.value < 0x20 {
            return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
        }
        if scalar.value >= 0xF700, scalar.value <= 0xF8FF {
            return nil
        }
        return characters
    }

    override func keyUp(with event: NSEvent) {
        // Deduplicate: the local event monitor (line 46) and the normal responder
        // chain can both deliver the same keyUp event.
        guard event.eventNumber != lastHandledKeyUpEventNumber else { return }
        lastHandledKeyUpEventNumber = event.eventNumber

        guard let surface = self.surface else { return }
        var input = ghosttyKeyInput(for: event)
        input.action = GHOSTTY_ACTION_RELEASE
        input.text = nil
        input.composing = false
        _ = ghostty_surface_key(surface, input)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface = self.surface else { return }
        let mods = Self.ghosttyMods(from: event)

        var input = ghostty_input_key_s()
        input.action = GHOSTTY_ACTION_PRESS
        input.mods = mods
        input.keycode = UInt32(event.keyCode)
        _ = ghostty_surface_key(surface, input)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard let surface = self.surface else { return false }

        // If the IME is composing and the key has no Cmd modifier, don't
        // intercept — let it flow through to keyDown so the input method
        // can process it normally.
        if hasMarkedText(),
           !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            return false
        }

        // Check if this event matches a Ghostty keybinding
        var keyEvent = ghosttyKeyInput(for: event)
        let text = event.characters ?? ""
        var flags = ghostty_binding_flags_e(rawValue: 0)
        let isBinding = text.withCString { ptr in
            keyEvent.text = ptr
            return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
        }

        if isBinding {
            // Route through keyDown for full text handling
            keyDown(with: event)
            return true
        }

        // Let Cmd+key shortcuts reach the menu system
        if event.modifierFlags.contains(.command) {
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                return true
            }
        }

        // Forward arrow/function keys that macOS might otherwise intercept
        let interceptKeys: Set<UInt16> = [123, 124, 125, 126, 115, 116, 117, 119, 121]
        if interceptKeys.contains(event.keyCode) {
            keyDown(with: event)
            return true
        }

        return false
    }

    override func doCommand(by selector: Selector) {
        // Intentionally empty — prevents NSBeep for unhandled keys
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface = self.surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                str.withCString { ptr in
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: - Drag and Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let surface = self.surface else { return false }
        let pasteboard = sender.draggingPasteboard

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            let text = urls.map { $0.isFileURL ? shellEscape($0.path) : $0.absoluteString }.joined(separator: " ")
            text.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
            }
            return true
        }

        if let text = pasteboard.string(forType: .string) {
            text.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
            }
            return true
        }

        return false
    }

    // MARK: - Reading Terminal Content

    /// Read the visible terminal content (for input detection / tab naming).
    func readVisibleContent() -> String? {
        guard let surface = self.surface else { return nil }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0, y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0, y: 0),
            rectangle: false
        )
        guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    // MARK: - Helpers

    private func shellEscape(_ value: String) -> String {
        let special = "\\ ()[]{}<>\"'`!#$&;|*?\t"
        var result = value
        for char in special {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }

    /// Convert NSEvent modifier flags to Ghostty modifier flags.
    static func ghosttyMods(from event: NSEvent) -> ghostty_input_mods_e {
        return ghosttyMods(fromCocoa: event.modifierFlags)
    }

    static func ghosttyMods(fromCocoa flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE
        if flags.contains(.shift) { mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_SHIFT.rawValue) }
        if flags.contains(.control) { mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_CTRL.rawValue) }
        if flags.contains(.option) { mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_ALT.rawValue) }
        if flags.contains(.command) { mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_SUPER.rawValue) }
        if flags.contains(.capsLock) { mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_CAPS.rawValue) }
        return mods
    }

    /// Convert Ghostty modifier flags back to NSEvent.ModifierFlags.
    static func cocoaMods(from mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    /// Return the current keyboard input source ID (for detecting IME switches).
    static func currentKeyboardLayoutId() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return unsafeBitCast(ptr, to: CFString.self) as String
    }

    /// Convert NSEvent keyCode to Ghostty key enum.
    /// Note: ghostty uses the keycode directly (not a translated key), so we just pass keyCode.
    static func ghosttyKey(from event: NSEvent) -> ghostty_input_key_e {
        // libghostty handles keycode-to-key translation internally
        return GHOSTTY_KEY_UNIDENTIFIED
    }
}

// MARK: - NSTextInputClient

extension TerminalNSView: NSTextInputClient {
    func hasMarkedText() -> Bool {
        return markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        return NSRange()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            self.markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            self.markedText = NSMutableAttributedString(string: v)
        default:
            break
        }

        // If called outside keyDown (e.g. keyboard layout change during compose),
        // sync preedit immediately.
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }

    func characterIndex(for point: NSPoint) -> Int {
        return 0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface = self.surface else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }
        var x: Double = 0
        var y: Double = 0
        var w: Double = 0
        var h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let viewRect = NSRect(x: x, y: frame.size.height - y, width: w, height: max(h, 1))
        let winRect = convert(viewRect, to: nil)
        guard let window = self.window else { return winRect }
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as String:
            chars = v
        default:
            return
        }
        unmarkText()
        keyTextAccumulator?.append(chars)
    }
}
