import Foundation
import Darwin

/// Monitors terminal tab shell processes to detect CPU, disk, and network activity.
///
/// Claude tabs are matched to their login PIDs by finding the `deckard-hook-<SURFACE_ID>.sh`
/// reference in the claude process command line. Terminal tabs are matched by elimination.
///
/// All mutable state is accessed exclusively on `queue` (a serial dispatch queue).
class ProcessMonitor {
    static let shared = ProcessMonitor()

    private let queue = DispatchQueue(label: "com.deckard.process-monitor")

    struct TabInfo {
        let surfaceId: UUID
        let kind: TabKind
        let name: String
        let workspacePath: String

        var isClaude: Bool { kind == .claude }

        init(surfaceId: UUID, kind: TabKind, name: String, workspacePath: String) {
            self.surfaceId = surfaceId
            self.kind = kind
            self.name = name
            self.workspacePath = workspacePath
        }

        init(surfaceId: UUID, isClaude: Bool, name: String, workspacePath: String) {
            self.init(surfaceId: surfaceId, kind: isClaude ? .claude : .terminal, name: name, workspacePath: workspacePath)
        }
    }

    struct ActivityInfo: Equatable {
        var cpu: Bool = false
        var disk: Bool = false

        var isActive: Bool { cpu || disk }

        var description: String {
            isActive ? "Busy" : "Idle"
        }
    }

    /// Whether we've logged the initial PID-to-tab mapping.
    private var hasLoggedMapping = false

    /// Cached surface ID → (login PID, shell PID) mapping from socket registration.
    private var cachedPids: [UUID: (login: pid_t, shell: pid_t)] = [:]

    /// Shell PIDs registered via the control socket (surface UUID string → shell PID).
    /// Shell PID's parent is the login PID.
    private var registeredShellPids: [String: pid_t] = [:]

    /// Last known foreground PID per login (keyed by login PID).
    private var lastFgPids: [pid_t: pid_t] = [:]
    /// CPU time from the previous poll cycle (keyed by login PID).
    private var lastCpuTimes: [pid_t: UInt64] = [:]
    /// Disk I/O bytes from the previous poll cycle (keyed by login PID).
    private var lastDiskBytes: [pid_t: UInt64] = [:]

    /// Minimum CPU delta (nanoseconds) to count as activity.
    /// 800ns filters measurement noise while catching lightweight programs
    /// like ping (~2μs/1s). False positives from scheduler artifacts
    /// are handled by the consecutive-poll requirement in the window controller.
    private let cpuThreshold: UInt64 = 800

    /// Persistent shell for querying CPU time of root-owned processes via `ps`.
    /// proc_pidinfo fails with EPERM on setuid-root binaries (top, sudo, etc.),
    /// so we fall back to `ps -o cputime=`. A persistent shell (~2ms/query) avoids
    /// the ~66ms overhead of spawning a new Process per poll.
    private var psShell: Process?
    private var psStdin: FileHandle?
    private var psStdout: FileHandle?

    // MARK: - Public API

    /// Poll all tabs. Returns surface UUID → activity info for each terminal tab.
    func poll(tabs: [TabInfo]) -> [UUID: ActivityInfo] {
        queue.sync { _poll(tabs: tabs) }
    }

    /// Register a shell PID for a surface (called from the control socket handler).
    /// The shell PID's parent is the login PID used for activity detection.
    func registerShellPid(_ shellPid: pid_t, forSurface surfaceIdStr: String) {
        queue.async { [self] in
            registeredShellPids[surfaceIdStr] = shellPid
        }
    }

    /// Return the registered shell PID for a tab. Agent tabs use `exec`, so this
    /// PID becomes the long-running agent process after startup.
    func shellPid(forSurface surfaceId: UUID) -> pid_t? {
        queue.sync {
            if let cached = cachedPids[surfaceId] {
                return cached.shell
            }
            guard let shellPid = registeredShellPids[surfaceId.uuidString] else {
                return nil
            }
            if let info = getKInfoProc(pid: shellPid) {
                cachedPids[surfaceId] = (login: info.kp_eproc.e_ppid, shell: shellPid)
            }
            return shellPid
        }
    }

    // MARK: - Core Poll (called on queue)

    private func _poll(tabs: [TabInfo]) -> [UUID: ActivityInfo] {
        let terminalTabs = tabs.filter { $0.kind == .terminal }
        guard !terminalTabs.isEmpty else { return [:] }

        // Resolve registered shell PIDs → (login, shell) pairs for uncached tabs.
        // Uses a single getKInfoProc per new tab instead of scanning all processes.
        for tab in tabs {
            if cachedPids[tab.surfaceId] != nil { continue }
            if let shellPid = registeredShellPids[tab.surfaceId.uuidString],
               let info = getKInfoProc(pid: shellPid) {
                cachedPids[tab.surfaceId] = (login: info.kp_eproc.e_ppid, shell: shellPid)
            }
        }

        // Remove cache entries for tabs that no longer exist
        let activeSurfaces = Set(tabs.map { $0.surfaceId })
        cachedPids = cachedPids.filter { activeSurfaces.contains($0.key) }

        // Log the mapping once all tabs are resolved
        if !hasLoggedMapping && cachedPids.count == tabs.count {
            hasLoggedMapping = true
            let lines = tabs.map { tab -> String in
                let prefix = tab.kind.rawValue.prefix(1).uppercased()
                let pid = cachedPids[tab.surfaceId].map { "login=\($0.login) shell=\($0.shell)" } ?? "?"
                return "  \(prefix):\(tab.name)@\(tab.workspacePath) → \(pid)"
            }
            DiagnosticLog.shared.log("processmon",
                "PID mapping (\(cachedPids.count)/\(tabs.count) matched):\n" +
                lines.joined(separator: "\n"))
        }

        var results: [UUID: ActivityInfo] = [:]
        for tab in terminalTabs {
            if let pids = cachedPids[tab.surfaceId] {
                results[tab.surfaceId] = checkActivity(pids: pids, tab: tab)
            } else {
                results[tab.surfaceId] = ActivityInfo()
            }
        }

        // Clean up stale tracking data (keyed by shell PID)
        let activeShells = Set(terminalTabs.compactMap { cachedPids[$0.surfaceId]?.shell })
        lastFgPids = lastFgPids.filter { activeShells.contains($0.key) }
        lastCpuTimes = lastCpuTimes.filter { activeShells.contains($0.key) }
        lastDiskBytes = lastDiskBytes.filter { activeShells.contains($0.key) }

        return results
    }

    // MARK: - Activity Detection

    private func checkActivity(pids: (login: pid_t, shell: pid_t), tab: TabInfo) -> ActivityInfo {
        let key = pids.shell  // unique per tab (login PID is shared in direct: mode)
        guard let info = getKInfoProc(pid: pids.shell) else { return ActivityInfo() }

        let shellPgid = info.kp_eproc.e_pgid
        let termFgPgid = info.kp_eproc.e_tpgid

        // Shell itself is foreground → at prompt
        if shellPgid == termFgPgid {
            lastFgPids[key] = nil
            return ActivityInfo()
        }

        // Find the foreground process group leader (stable, unlike leaf selection)
        let fgPid = termFgPgid

        // Get CPU time and disk I/O (fall back to ps for root-owned processes)
        guard let cpuTime = getCpuTime(pid: fgPid) ?? getCpuTimeViaPs(pid: fgPid) else {
            return ActivityInfo()
        }
        let diskBytes = getDiskBytes(pid: fgPid) ?? 0

        // First time seeing this foreground process — just set baseline, don't pulse
        if lastFgPids[key] == nil {
            lastFgPids[key] = fgPid
            lastCpuTimes[key] = cpuTime
            lastDiskBytes[key] = diskBytes
            return ActivityInfo()
        }

        // Foreground process changed — new command started
        if lastFgPids[key] != fgPid {
            lastFgPids[key] = fgPid
            lastCpuTimes[key] = cpuTime
            lastDiskBytes[key] = diskBytes
            let result = ActivityInfo(cpu: true)
            DiagnosticLog.shared.log("processmon",
                "ACTIVE: workspace=\(tab.workspacePath) tab=\"\(tab.name)\" " +
                "shell=\(key) fg=\(fgPid) reason=fg_changed")
            return result
        }

        let prevCpu = lastCpuTimes[key] ?? cpuTime
        let prevDisk = lastDiskBytes[key] ?? diskBytes
        lastCpuTimes[key] = cpuTime
        lastDiskBytes[key] = diskBytes

        let cpuDelta = cpuTime &- prevCpu
        let diskDelta = diskBytes > prevDisk ? diskBytes - prevDisk : 0
        let cpuActive = cpuDelta > cpuThreshold
        let diskActive = diskDelta > 0
        let result = ActivityInfo(cpu: cpuActive, disk: diskActive)

        if result.isActive {
            var reasons: [String] = []
            if cpuActive { reasons.append("cpu=\(cpuDelta)ns") }
            if diskActive { reasons.append("disk=+\(diskDelta)B") }
            DiagnosticLog.shared.log("processmon",
                "ACTIVE: workspace=\(tab.workspacePath) tab=\"\(tab.name)\" " +
                "shell=\(key) fg=\(fgPid) \(reasons.joined(separator: " "))")
        }

        return result
    }

    // MARK: - System Calls

    private func getKInfoProc(pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    private func getCpuTime(pid: pid_t) -> UInt64? {
        var taskInfo = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(size))
        guard ret == size else { return nil }
        return taskInfo.pti_total_user + taskInfo.pti_total_system
    }

    /// Fallback for root-owned processes where proc_pidinfo fails with EPERM.
    /// Uses a persistent `/bin/sh` to run `ps -o cputime=` (~2ms vs ~66ms per spawn).
    /// Parses output (format: `M:SS.cc`) into nanoseconds.
    private func getCpuTimeViaPs(pid: pid_t) -> UInt64? {
        let (stdin, stdout) = ensurePsShell()
        guard let stdin, let stdout else { return nil }

        let sentinel = "__DONE_\(pid)__"
        let cmd = "ps -o cputime= -p \(pid); echo \(sentinel)\n"
        guard let cmdData = cmd.data(using: .utf8) else { return nil }
        do { try stdin.write(contentsOf: cmdData) } catch { resetPsShell(); return nil }

        // Read until sentinel line appears
        var accumulated = Data()
        let sentinelData = sentinel.data(using: .utf8)!
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            let chunk = stdout.availableData
            if chunk.isEmpty { usleep(200); continue }
            accumulated.append(chunk)
            if accumulated.range(of: sentinelData) != nil { break }
        }

        guard let raw = String(data: accumulated, encoding: .utf8) else { return nil }
        // Extract the cputime line (everything before the sentinel)
        let lines = raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("__DONE_") }
        guard let str = lines.first else { return nil }

        return parseCpuTime(str)
    }

    /// Parse ps cputime format "M:SS.cc" or "H:MM:SS.cc" into nanoseconds.
    private func parseCpuTime(_ str: String) -> UInt64? {
        let parts = str.split(separator: ":")
        guard parts.count >= 2, let secPart = parts.last else { return nil }
        let minutes: Double
        if parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]) {
            minutes = h * 60 + m
        } else {
            minutes = Double(parts[0]) ?? 0
        }
        guard let seconds = Double(secPart) else { return nil }
        return UInt64((minutes * 60 + seconds) * 1_000_000_000)
    }

    private func ensurePsShell() -> (stdin: FileHandle?, stdout: FileHandle?) {
        if let shell = psShell, shell.isRunning { return (psStdin, psStdout) }
        resetPsShell()
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        let inPipe = Pipe()
        let outPipe = Pipe()
        shell.standardInput = inPipe
        shell.standardOutput = outPipe
        shell.standardError = FileHandle.nullDevice
        do { try shell.run() } catch { return (nil, nil) }
        psShell = shell
        psStdin = inPipe.fileHandleForWriting
        psStdout = outPipe.fileHandleForReading
        return (psStdin, psStdout)
    }

    private func resetPsShell() {
        psShell?.terminate()
        psShell = nil
        psStdin = nil
        psStdout = nil
    }

    private func getDiskBytes(pid: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let ret = withUnsafeMutablePointer(to: &usage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rusagePtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rusagePtr)
            }
        }
        guard ret == 0 else { return nil }
        return usage.ri_diskio_bytesread + usage.ri_diskio_byteswritten
    }

}
