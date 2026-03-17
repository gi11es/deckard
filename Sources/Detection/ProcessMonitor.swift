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

    /// Last known foreground PID per login (keyed by login PID).
    private var lastFgPids: [pid_t: pid_t] = [:]
    /// CPU time from the previous poll cycle (keyed by login PID).
    private var lastCpuTimes: [pid_t: UInt64] = [:]
    /// Disk I/O bytes from the previous poll cycle (keyed by login PID).
    private var lastDiskBytes: [pid_t: UInt64] = [:]
    /// Total socket buffer bytes from the previous poll cycle (keyed by login PID).
    private var lastSocketBytes: [pid_t: UInt64] = [:]

    /// Minimum CPU delta (nanoseconds) to count as activity.
    /// Filters out micro-variations from idle shells (~10ms per 2.5s poll).
    private let cpuThreshold: UInt64 = 10_000_000

    // MARK: - Public API

    /// Poll all tabs. Returns surface UUID → hasActivity for each terminal tab.
    /// `tabs` must be in creation order (matching PID creation order).
    func poll(tabs: [TabInfo]) -> [UUID: Bool] {
        queue.sync { _poll(tabs: tabs) }
    }

    // MARK: - Core Poll (called on queue)

    private func _poll(tabs: [TabInfo]) -> [UUID: Bool] {
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

        var results: [UUID: Bool] = [:]
        for (i, tab) in terminalTabs.enumerated() {
            if i < terminalLoginPids.count {
                results[tab.surfaceId] = checkActivity(
                    loginPid: terminalLoginPids[i], allProcs: allProcs)
            } else {
                results[tab.surfaceId] = false
            }
        }

        // Clean up stale tracking data
        let activeLogins = Set(terminalLoginPids)
        lastFgPids = lastFgPids.filter { activeLogins.contains($0.key) }
        lastCpuTimes = lastCpuTimes.filter { activeLogins.contains($0.key) }
        lastDiskBytes = lastDiskBytes.filter { activeLogins.contains($0.key) }
        lastSocketBytes = lastSocketBytes.filter { activeLogins.contains($0.key) }

        return results
    }

    // MARK: - Activity Detection

    private func checkActivity(loginPid: pid_t, allProcs: [kinfo_proc]) -> Bool {
        // Find the actual shell (login's child)
        let shellPid = allProcs
            .first(where: { $0.kp_eproc.e_ppid == loginPid })
            .map { $0.kp_proc.p_pid } ?? loginPid

        guard let info = getKInfoProc(pid: shellPid) else { return false }

        let shellPgid = info.kp_eproc.e_pgid
        let termFgPgid = info.kp_eproc.e_tpgid

        // Shell itself is foreground → at prompt
        if shellPgid == termFgPgid {
            lastFgPids[loginPid] = nil
            return false
        }

        // Find the foreground process group leader (stable, unlike leaf selection)
        let fgPid = termFgPgid

        // Get CPU time, disk I/O, and network buffer state
        guard let cpuTime = getCpuTime(pid: fgPid) else { return false }
        let diskBytes = getDiskBytes(pid: fgPid) ?? 0
        let socketBytes = getSocketBufferBytes(pid: fgPid)

        // First time seeing this login — just set baseline, don't pulse
        if lastFgPids[loginPid] == nil {
            lastFgPids[loginPid] = fgPid
            lastCpuTimes[loginPid] = cpuTime
            lastDiskBytes[loginPid] = diskBytes
            lastSocketBytes[loginPid] = socketBytes
            return false
        }

        // Foreground process changed — new command started, pulse
        if lastFgPids[loginPid] != fgPid {
            lastFgPids[loginPid] = fgPid
            lastCpuTimes[loginPid] = cpuTime
            lastDiskBytes[loginPid] = diskBytes
            lastSocketBytes[loginPid] = socketBytes
            return true
        }

        let prevCpu = lastCpuTimes[loginPid] ?? cpuTime
        let prevDisk = lastDiskBytes[loginPid] ?? diskBytes
        let prevSocket = lastSocketBytes[loginPid] ?? socketBytes
        lastCpuTimes[loginPid] = cpuTime
        lastDiskBytes[loginPid] = diskBytes
        lastSocketBytes[loginPid] = socketBytes

        let cpuDelta = cpuTime &- prevCpu > cpuThreshold
        let diskDelta = diskBytes > prevDisk
        let sockDelta = socketBytes != prevSocket
        return cpuDelta || diskDelta || sockDelta
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

    /// Get total bytes across all socket buffers (receive + send).
    /// A change between polls indicates active network I/O.
    private func getSocketBufferBytes(pid: pid_t) -> UInt64 {
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufSize > 0 else { return 0 }

        let fdCount = Int(bufSize) / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)
        let ret = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufSize)
        guard ret > 0 else { return 0 }

        let actualCount = Int(ret) / MemoryLayout<proc_fdinfo>.size
        var total: UInt64 = 0

        for i in 0..<min(actualCount, 256) {
            guard fds[i].proc_fdtype == PROX_FDTYPE_SOCKET else { continue }

            var socketInfo = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            let infoRet = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO,
                                         &socketInfo, infoSize)
            guard infoRet == infoSize else { continue }

            total += UInt64(socketInfo.psi.soi_rcv.sbi_cc)
            total += UInt64(socketInfo.psi.soi_snd.sbi_cc)
        }

        return total
    }
}
