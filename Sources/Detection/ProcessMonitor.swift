import Foundation
import Darwin

/// Monitors terminal tab shell processes to detect CPU, disk, and network activity.
///
/// The window controller provides all tab info (surface IDs + isClaude flags).
/// We match login PIDs to tabs by sorted PID order ↔ sorted tab creation order,
/// skipping Claude tabs in both lists.
///
/// All mutable state is accessed exclusively on `queue` (a serial dispatch queue).
class ProcessMonitor {
    static let shared = ProcessMonitor()

    private let queue = DispatchQueue(label: "com.deckard.process-monitor")

    struct TabInfo {
        let surfaceId: UUID
        let isClaude: Bool
    }

    struct ActivityInfo: Equatable {
        var cpu: Bool = false
        var disk: Bool = false

        var isActive: Bool { cpu || disk }

        var description: String {
            isActive ? "Busy" : "Idle"
        }
    }

    /// Last known foreground PID per login (keyed by login PID).
    private var lastFgPids: [pid_t: pid_t] = [:]
    /// CPU time from the previous poll cycle (keyed by login PID).
    private var lastCpuTimes: [pid_t: UInt64] = [:]
    /// Disk I/O bytes from the previous poll cycle (keyed by login PID).
    private var lastDiskBytes: [pid_t: UInt64] = [:]

    /// Minimum CPU delta (nanoseconds) to count as activity.
    /// Filters out measurement noise while catching lightweight programs like ping.
    private let cpuThreshold: UInt64 = 1_000

    // MARK: - Public API

    /// Poll all tabs. Returns surface UUID → activity info for each terminal tab.
    /// `tabs` must be in creation order (matching PID creation order).
    func poll(tabs: [TabInfo]) -> [UUID: ActivityInfo] {
        queue.sync { _poll(tabs: tabs) }
    }

    // MARK: - Core Poll (called on queue)

    private func _poll(tabs: [TabInfo]) -> [UUID: ActivityInfo] {
        let terminalTabs = tabs.filter { !$0.isClaude }
        guard !terminalTabs.isEmpty else { return [:] }

        let allProcs = allProcesses() ?? []
        let myPid = getpid()

        // Find all login children of Deckard, sorted by PID (creation order)
        let loginPids = allProcs
            .filter { $0.kp_eproc.e_ppid == myPid }
            .map { $0.kp_proc.p_pid }
            .sorted()

        // Build parallel arrays: for each login, determine if it's Claude
        // by checking tab order. Tabs and logins are both in creation order,
        // so the Nth login corresponds to the Nth tab.
        var terminalLoginPids: [pid_t] = []
        var tabIdx = 0
        for loginPid in loginPids {
            guard tabIdx < tabs.count else { break }
            let tab = tabs[tabIdx]
            tabIdx += 1
            if !tab.isClaude {
                terminalLoginPids.append(loginPid)
            }
        }

        var results: [UUID: ActivityInfo] = [:]
        for (i, tab) in terminalTabs.enumerated() {
            if i < terminalLoginPids.count {
                results[tab.surfaceId] = checkActivity(
                    loginPid: terminalLoginPids[i], allProcs: allProcs)
            } else {
                results[tab.surfaceId] = ActivityInfo()
            }
        }

        // Clean up stale tracking data
        let activeLogins = Set(terminalLoginPids)
        lastFgPids = lastFgPids.filter { activeLogins.contains($0.key) }
        lastCpuTimes = lastCpuTimes.filter { activeLogins.contains($0.key) }
        lastDiskBytes = lastDiskBytes.filter { activeLogins.contains($0.key) }

        return results
    }

    // MARK: - Activity Detection

    private func checkActivity(loginPid: pid_t, allProcs: [kinfo_proc]) -> ActivityInfo {
        // Find the actual shell (login's child)
        let shellPid = allProcs
            .first(where: { $0.kp_eproc.e_ppid == loginPid })
            .map { $0.kp_proc.p_pid } ?? loginPid

        guard let info = getKInfoProc(pid: shellPid) else { return ActivityInfo() }

        let shellPgid = info.kp_eproc.e_pgid
        let termFgPgid = info.kp_eproc.e_tpgid

        // Shell itself is foreground → at prompt
        if shellPgid == termFgPgid {
            lastFgPids[loginPid] = nil
            return ActivityInfo()
        }

        // Find the foreground process group leader (stable, unlike leaf selection)
        let fgPid = termFgPgid

        // Get CPU time and disk I/O
        guard let cpuTime = getCpuTime(pid: fgPid) else { return ActivityInfo() }
        let diskBytes = getDiskBytes(pid: fgPid) ?? 0

        // First time seeing this login — just set baseline, don't pulse
        if lastFgPids[loginPid] == nil {
            lastFgPids[loginPid] = fgPid
            lastCpuTimes[loginPid] = cpuTime
            lastDiskBytes[loginPid] = diskBytes
            return ActivityInfo()
        }

        // Foreground process changed — new command started
        if lastFgPids[loginPid] != fgPid {
            lastFgPids[loginPid] = fgPid
            lastCpuTimes[loginPid] = cpuTime
            lastDiskBytes[loginPid] = diskBytes
            return ActivityInfo(cpu: true)
        }

        let prevCpu = lastCpuTimes[loginPid] ?? cpuTime
        let prevDisk = lastDiskBytes[loginPid] ?? diskBytes
        lastCpuTimes[loginPid] = cpuTime
        lastDiskBytes[loginPid] = diskBytes

        return ActivityInfo(
            cpu: cpuTime &- prevCpu > cpuThreshold,
            disk: diskBytes > prevDisk
        )
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
