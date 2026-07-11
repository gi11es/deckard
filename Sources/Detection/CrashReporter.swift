import Foundation

/// File-level storage for the crash file path — accessible from the C signal
/// handler without capturing any Swift context.
private var gCrashCPath: UnsafeMutablePointer<Int8>?

/// Installs signal handlers and an uncaught-exception handler that write crash
/// details to ~/Library/Application Support/Deckard/crash.log before the
/// process dies.  On next launch, call `logPreviousCrashIfAny()` to surface
/// the report in DiagnosticLog.
///
/// Signal handlers use only async-signal-safe functions (open/write/close/
/// backtrace/backtrace_symbols_fd).
enum CrashReporter {

    // MARK: - Public

    /// Install all handlers.  Call as early as possible (before NSApplication).
    static func install() {
        gCrashCPath = strdup(crashFileURL.path)
        installExceptionHandler()
        installSignalHandlers()
    }

    /// If a crash.log exists from a previous run, copy its contents into
    /// DiagnosticLog under the "crash" category, then rename it so it is not
    /// reported twice.
    static func logPreviousCrashIfAny() {
        let path = crashFileURL.path
        guard FileManager.default.fileExists(atPath: path),
              let contents = try? String(contentsOfFile: path, encoding: .utf8),
              !contents.isEmpty else { return }

        DiagnosticLog.shared.log("crash", "=== Previous crash report ===")
        for line in contents.components(separatedBy: "\n") where !line.isEmpty {
            DiagnosticLog.shared.log("crash", line)
        }
        DiagnosticLog.shared.log("crash", "=== End previous crash report ===")

        // Keep the file around for manual inspection, renamed with a timestamp.
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let archive = crashFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("crash-\(ts).log")
        try? FileManager.default.moveItem(at: crashFileURL, to: archive)
    }

    // MARK: - Paths

    private static let crashFileURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Deckard")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("crash.log")
    }()

    // MARK: - Uncaught Objective-C Exceptions

    private static func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "(no reason)"
            let symbols = exception.callStackSymbols.joined(separator: "\n")
            let report = """
            Uncaught Objective-C exception
            Name:   \(name)
            Reason: \(reason)
            Time:   \(ISO8601DateFormatter().string(from: Date()))

            Call stack:
            \(symbols)

            """
            try? report.write(to: CrashReporter.crashFileURL, atomically: false, encoding: .utf8)
        }
    }

    // MARK: - POSIX Signal Handlers

    private static let caughtSignals: [Int32] = [
        SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP,
    ]

    private static func installSignalHandlers() {
        for sig in caughtSignals {
            signal(sig, crashSignalHandler)
        }
        // SIGPIPE's default action silently kills the process — no crash
        // report, no chance to handle it. Any write to a peer-closed fd
        // (control-socket replies to hook clients that timed out, PTY or
        // child-process pipes) must return EPIPE instead.
        signal(SIGPIPE, SIG_IGN)
    }
}

/// Async-signal-safe crash handler.  Uses only POSIX write / open / close
/// plus `backtrace` / `backtrace_symbols_fd`.  Defined at file scope so it
/// does not capture any Swift context.
private func crashSignalHandler(_ sig: Int32) {
    guard let cPath = gCrashCPath else { _exit(128 + sig) }
    let fd = open(cPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { _exit(128 + sig) }

    func emit(_ s: StaticString) {
        s.withUTF8Buffer { buf in
            _ = write(fd, buf.baseAddress, buf.count)
        }
    }
    func emitInt(_ n: Int32) {
        var buf = [UInt8](repeating: 0, count: 12)
        var v = n < 0 ? -Int(n) : Int(n)
        var i = buf.count - 1
        if v == 0 { buf[i] = UInt8(ascii: "0"); i -= 1 }
        while v > 0 { buf[i] = UInt8(ascii: "0") + UInt8(v % 10); v /= 10; i -= 1 }
        if n < 0 { buf[i] = UInt8(ascii: "-"); i -= 1 }
        buf.withUnsafeBufferPointer { ptr in
            _ = write(fd, ptr.baseAddress!.advanced(by: i + 1), buf.count - i - 1)
        }
    }

    emit("Fatal signal: ")
    emitInt(sig)
    emit(" (")
    switch sig {
    case SIGABRT: emit("SIGABRT")
    case SIGSEGV: emit("SIGSEGV")
    case SIGBUS:  emit("SIGBUS")
    case SIGFPE:  emit("SIGFPE")
    case SIGILL:  emit("SIGILL")
    case SIGTRAP: emit("SIGTRAP")
    default:      emit("unknown")
    }
    emit(")\n\nBacktrace:\n")

    var callstack = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
    let frames = backtrace(&callstack, Int32(callstack.count))
    backtrace_symbols_fd(&callstack, frames, fd)

    emit("\n")
    close(fd)

    // Re-raise with default handler so macOS still generates a system crash
    // report if possible.
    signal(sig, SIG_DFL)
    raise(sig)
}
