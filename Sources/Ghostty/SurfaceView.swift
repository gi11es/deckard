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
    /// Timestamp of the last performKeyEquivalent event that needs redispatch.
    /// Used to handle Cmd+key events that AppKit sends back through doCommand.
    private var lastPerformKeyEvent: TimeInterval?

    var title: String = ""
    var pwd: String?

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
    //
    // Ported from Ghostty's SurfaceView_AppKit.swift (MIT license).
    // Adapted for Deckard's simpler architecture (no splits, no key sequences).

    override func keyDown(with event: NSEvent) {
        guard let surface = self.surface else {
            interpretKeyEvents([event])
            return
        }

        // Translate mods to handle configs like option-as-alt.
        let translationModsGhostty = Self.cocoaMods(from:
            ghostty_surface_key_translation_mods(surface, Self.ghosttyMods(from: event)))

        // Preserve hidden bits in the modifier flags (important for dead keys).
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        // IMPORTANT: reuse the original event if mods match — Korean IME
        // relies on object identity within AppKit.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
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
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0

        let keyboardIdBefore: String? = if !markedTextBefore {
            Self.currentKeyboardLayoutId()
        } else {
            nil
        }

        // Reset redispatch state before interpretKeyEvents may trigger it.
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        // If the keyboard layout changed, an IME consumed the event.
        if !markedTextBefore && keyboardIdBefore != Self.currentKeyboardLayoutId() {
            return
        }

        syncPreedit(clearIfNeeded: markedTextBefore)

        if let list = keyTextAccumulator, !list.isEmpty {
            // Composed text from IME — never composing.
            for text in list {
                _ = keyAction(action, event: event,
                              translationMods: translationMods, text: text)
            }
        } else {
            _ = keyAction(action, event: event,
                          translationMods: translationMods,
                          text: Self.ghosttyCharacters(for: translationEvent),
                          composing: markedText.length > 0 || markedTextBefore)
        }
    }

    override func keyUp(with event: NSEvent) {
        // Deduplicate: the local event monitor and the normal responder
        // chain can both deliver the same keyUp event.
        guard event.eventNumber != lastHandledKeyUpEventNumber else { return }
        lastHandledKeyUpEventNumber = event.eventNumber

        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard self.surface != nil else { return }

        // Determine press vs release based on whether the modifier is active.
        if hasMarkedText() { return }

        let mods = Self.ghosttyMods(from: event)
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            action = GHOSTTY_ACTION_PRESS
        }

        _ = keyAction(action, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard let surface = self.surface else { return false }

        // Don't intercept during IME composition (unless Cmd is held).
        if hasMarkedText(),
           !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            return false
        }

        // Let Deckard's menu shortcuts (Cmd+Q, Cmd+W, Cmd+T, etc.) take
        // priority over Ghostty's default keybindings.
        if event.modifierFlags.contains(.command) {
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                return true
            }
        }

        // Check if this event matches a Ghostty keybinding.
        var keyEv = Self.ghosttyKeyEvent(event, GHOSTTY_ACTION_PRESS)
        let isBinding: Bool = (event.characters ?? "").withCString { ptr in
            keyEv.text = ptr
            var flags = ghostty_binding_flags_e(rawValue: 0)
            return ghostty_surface_key_is_binding(surface, keyEv, &flags)
        }

        if isBinding {
            keyDown(with: event)
            return true
        }

        // Handle Ctrl+Return (prevent default context menu equivalent).
        if event.charactersIgnoringModifiers == "\r",
           event.modifierFlags.contains(.control) {
            let finalEvent = NSEvent.keyEvent(
                with: .keyDown, location: event.locationInWindow,
                modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                windowNumber: event.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: event.isARepeat, keyCode: event.keyCode
            )
            if let finalEvent { keyDown(with: finalEvent) }
            return true
        }

        // Handle Ctrl+/ (prevent system beep).
        if event.charactersIgnoringModifiers == "/",
           event.modifierFlags.contains(.control),
           event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) {
            let finalEvent = NSEvent.keyEvent(
                with: .keyDown, location: event.locationInWindow,
                modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                windowNumber: event.windowNumber, context: nil,
                characters: "_", charactersIgnoringModifiers: "_",
                isARepeat: event.isARepeat, keyCode: event.keyCode
            )
            if let finalEvent { keyDown(with: finalEvent) }
            return true
        }

        // Ignore synthetic events (zero timestamp).
        if event.timestamp == 0 { return false }

        // Cmd+key redispatch: AppKit sometimes needs a second pass.
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            if let last = lastPerformKeyEvent, last == event.timestamp {
                lastPerformKeyEvent = nil
                let chars = event.characters ?? ""
                let finalEvent = NSEvent.keyEvent(
                    with: .keyDown, location: event.locationInWindow,
                    modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                    windowNumber: event.windowNumber, context: nil,
                    characters: chars, charactersIgnoringModifiers: chars,
                    isARepeat: event.isARepeat, keyCode: event.keyCode
                )
                if let finalEvent { keyDown(with: finalEvent) }
                return true
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }

        lastPerformKeyEvent = nil

        // Forward arrow/function keys that macOS might otherwise intercept.
        let interceptKeys: Set<UInt16> = [123, 124, 125, 126, 115, 116, 117, 119, 121]
        if interceptKeys.contains(event.keyCode) {
            keyDown(with: event)
            return true
        }

        return false
    }

    override func doCommand(by selector: Selector) {
        // If we're processing a Cmd+key event that was redispatched by
        // performKeyEquivalent, send it back through the event system
        // so it can be encoded by keyDown.
        if let lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
            return
        }
    }

    // MARK: - Key Action Helper

    /// Send a key event to Ghostty. Based on Ghostty's keyAction (MIT).
    /// Text is only sent if the first codepoint is printable (>= 0x20).
    @discardableResult
    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationMods: NSEvent.ModifierFlags? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface = self.surface else { return false }

        var keyEv = Self.ghosttyKeyEvent(event, action, translationMods: translationMods)
        keyEv.composing = composing

        if let text, !text.isEmpty,
           let codepoint = text.utf8.first, codepoint >= 0x20 {
            return text.withCString { ptr in
                keyEv.text = ptr
                return ghostty_surface_key(surface, keyEv)
            }
        } else {
            return ghostty_surface_key(surface, keyEv)
        }
    }

    /// Build a ghostty_input_key_s from an NSEvent.
    /// Based on Ghostty's NSEvent.ghosttyKeyEvent (MIT).
    private static func ghosttyKeyEvent(
        _ event: NSEvent,
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var keyEv = ghostty_input_key_s()
        keyEv.action = action
        keyEv.keycode = UInt32(event.keyCode)
        keyEv.text = nil
        keyEv.composing = false

        keyEv.mods = ghosttyMods(from: event)
        // Control and command never contribute to text translation.
        keyEv.consumed_mods = ghosttyMods(fromCocoa:
            (translationMods ?? event.modifierFlags)
                .subtracting([.control, .command]))

        keyEv.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp {
            if let chars = event.characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                keyEv.unshifted_codepoint = codepoint.value
            }
        }

        return keyEv
    }

    /// Extract the terminal-appropriate characters from a key event.
    /// Based on Ghostty's NSEvent.ghosttyCharacters (MIT).
    private static func ghosttyCharacters(for event: NSEvent) -> String? {
        guard let characters = event.characters, !characters.isEmpty else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700, scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
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
