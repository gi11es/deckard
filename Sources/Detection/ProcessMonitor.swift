import Foundation
import Darwin

/// Monitors terminal tab shell processes to detect CPU activity.
/// Shells are direct children of the Deckard process (fork/exec by libghostty).
/// We discover them by reading DECKARD_SURFACE_ID from their environment.
///
/// All mutable state is accessed exclusively on `queue` (a serial dispatch queue).
/// `pollAll()` must be called from this queue or a background queue — never from main.
class ProcessMonitor {
    static let shared = ProcessMonitor()

    private let queue = DispatchQueue(label: "com.deckard.process-monitor")

    /// Map from surface UUID to shell PID.
    private var shellPids: [UUID: pid_t] = [:]
    /// Last known foreground PID per shell (keyed by shell PID).
    private var lastFgPids: [pid_t: pid_t] = [:]
    /// CPU time (user + system nanoseconds) from the previous poll cycle (keyed by shell PID).
    private var lastCpuTimes: [pid_t: UInt64] = [:]
    /// Counter to trigger periodic re-discovery.
    private var pollsSinceDiscovery = 0
    private let rediscoveryInterval = 12  // re-discover every ~30s at 2.5s poll

    // MARK: - Public API

    /// Poll all known terminal shells. Returns surface UUID → hasActivity.
    func pollAll() -> [UUID: Bool] {
        queue.sync { _pollAll() }
    }

    /// Get the name of the foreground process for a surface (for tooltips).
    func foregroundProcessName(forSurface surfaceId: UUID) -> String? {
        queue.sync {
            guard let shellPid = shellPids[surfaceId] else { return nil }
            guard let info = getKInfoProc(pid: shellPid) else { return nil }
            let fgPgid = info.kp_eproc.e_tpgid
            guard fgPgid != info.kp_eproc.e_pgid else { return nil }
            // Use a single-PID lookup rather than scanning all processes
            return processName(pid: fgPgid)
        }
    }

    // MARK: - Core Poll (called on queue)

    private func _pollAll() -> [UUID: Bool] {
        pollsSinceDiscovery += 1

        // Fetch the full process table once per poll cycle
        let allProcs = allProcesses() ?? []

        if shellPids.isEmpty || pollsSinceDiscovery >= rediscoveryInterval {
            discoverShells(allProcs: allProcs)
            pollsSinceDiscovery = 0
        }

        var results: [UUID: Bool] = [:]
        for (surfaceId, shellPid) in shellPids {
            guard getKInfoProc(pid: shellPid) != nil else {
                results[surfaceId] = false
                continue
            }
            results[surfaceId] = checkActivity(shellPid: shellPid, allProcs: allProcs)
        }
        return results
    }

    // MARK: - Shell Discovery

    private func discoverShells(allProcs: [kinfo_proc]) {
        let myPid = getpid()
        var newMap: [UUID: pid_t] = [:]

        for proc in allProcs {
            guard proc.kp_eproc.e_ppid == myPid else { continue }
            let childPid = proc.kp_proc.p_pid

            guard let env = readProcessEnv(pid: childPid) else { continue }

            // Skip Claude sessions — they have their own badge system
            if env["DECKARD_SESSION_TYPE"] == "claude" { continue }

            if let surfaceIdStr = env["DECKARD_SURFACE_ID"],
               let surfaceId = UUID(uuidString: surfaceIdStr) {
                newMap[surfaceId] = childPid
            }
        }

        // Clean up state for shells no longer tracked
        let activePids = Set(newMap.values)
        lastCpuTimes = lastCpuTimes.filter { activePids.contains($0.key) }
        lastFgPids = lastFgPids.filter { activePids.contains($0.key) }

        shellPids = newMap
    }

    // MARK: - Activity Detection

    private func checkActivity(shellPid: pid_t, allProcs: [kinfo_proc]) -> Bool {
        guard let info = getKInfoProc(pid: shellPid) else { return false }

        let shellPgid = info.kp_eproc.e_pgid
        let termFgPgid = info.kp_eproc.e_tpgid

        // Shell itself is foreground → at prompt
        if shellPgid == termFgPgid {
            lastFgPids[shellPid] = nil
            return false
        }

        // Find the leaf process in the foreground group
        let fgPid = findLeafProcess(inGroup: termFgPgid, allProcs: allProcs) ?? termFgPgid

        // Get CPU time for the foreground process
        guard let cpuTime = getCpuTime(pid: fgPid) else { return false }

        // If the foreground process changed, reset baseline and show activity
        if lastFgPids[shellPid] != fgPid {
            lastFgPids[shellPid] = fgPid
            lastCpuTimes[shellPid] = cpuTime
            return true  // new process just started → pulse
        }

        let prevTime = lastCpuTimes[shellPid] ?? cpuTime
        lastCpuTimes[shellPid] = cpuTime
        return cpuTime > prevTime
    }

    private func findLeafProcess(inGroup pgid: pid_t, allProcs: [kinfo_proc]) -> pid_t? {
        let groupProcs = allProcs.filter { $0.kp_eproc.e_pgid == pgid }
        guard !groupProcs.isEmpty else { return pgid }

        let pidsInGroup = Set(groupProcs.map { $0.kp_proc.p_pid })
        let parentsInGroup = Set(groupProcs.compactMap { proc -> pid_t? in
            let ppid = proc.kp_eproc.e_ppid
            return pidsInGroup.contains(ppid) ? ppid : nil
        })

        let leaves = pidsInGroup.subtracting(parentsInGroup)
        return leaves.first ?? pgid
    }

    // MARK: - System Calls

    private func getKInfoProc(pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    private func allProcesses() -> [kinfo_proc]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return nil }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        return Array(procs.prefix(actualCount))
    }

    private func getCpuTime(pid: pid_t) -> UInt64? {
        var taskInfo = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(size))
        guard ret == size else { return nil }
        return taskInfo.pti_total_user + taskInfo.pti_total_system
    }

    private func processName(pid: pid_t) -> String {
        var name = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
        proc_name(pid, &name, UInt32(name.count))
        return String(cString: name)
    }

    private func readProcessEnv(pid: pid_t) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        // KERN_PROCARGS2 layout:
        // [4 bytes: argc] [executable path\0] [padding \0s] [argv strings\0...] [env strings\0...]
        guard size > 4 else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var offset = 4

        // Skip executable path
        while offset < size && buffer[offset] != 0 { offset += 1 }
        // Skip padding nulls
        while offset < size && buffer[offset] == 0 { offset += 1 }

        // Skip argv (argc strings)
        var argsSkipped: Int32 = 0
        while offset < size && argsSkipped < argc {
            while offset < size && buffer[offset] != 0 { offset += 1 }
            offset += 1  // skip null terminator
            argsSkipped += 1
        }

        // Read environment variables
        var env: [String: String] = [:]
        while offset < size {
            let start = offset
            while offset < size && buffer[offset] != 0 { offset += 1 }
            if offset > start {
                let str = String(bytes: buffer[start..<offset], encoding: .utf8) ?? ""
                if let eqIdx = str.firstIndex(of: "=") {
                    let key = String(str[str.startIndex..<eqIdx])
                    let value = String(str[str.index(after: eqIdx)...])
                    env[key] = value
                    // Early exit once we have what we need
                    if env["DECKARD_SURFACE_ID"] != nil && env["DECKARD_SESSION_TYPE"] != nil {
                        break
                    }
                }
            }
            offset += 1
        }

        return env.isEmpty ? nil : env
    }
}
