import Foundation
import Darwin

/// Monitors terminal tab shell processes to detect CPU, disk, and network activity.
///
/// Discovery works by scanning children of the Deckard process (login processes),
/// finding their shell children, and excluding Claude sessions (which have a `claude`
/// process in their foreground group). The remaining shells are terminal tabs.
///
/// Since we can't map login PIDs to specific surface UUIDs via env vars (login is
/// setuid root), the window controller provides the list of terminal tab surface IDs
/// each poll cycle, and we match them to discovered login PIDs by order.
///
/// All mutable state is accessed exclusively on `queue` (a serial dispatch queue).
class ProcessMonitor {
    static let shared = ProcessMonitor()

    private let queue = DispatchQueue(label: "com.deckard.process-monitor")

    /// Last known foreground PID per login (keyed by login PID).
    private var lastFgPids: [pid_t: pid_t] = [:]
    /// CPU time from the previous poll cycle (keyed by login PID).
    private var lastCpuTimes: [pid_t: UInt64] = [:]
    /// Disk I/O bytes from the previous poll cycle (keyed by login PID).
    private var lastDiskBytes: [pid_t: UInt64] = [:]
    /// Total socket buffer bytes from the previous poll cycle (keyed by login PID).
    private var lastSocketBytes: [pid_t: UInt64] = [:]

    // MARK: - Public API

    /// Poll terminal shells. Takes ordered list of terminal tab surface IDs.
    /// Returns surface UUID → hasActivity for each terminal tab.
    func pollTerminalTabs(terminalSurfaceIds: [UUID]) -> [UUID: Bool] {
        queue.sync { _poll(terminalSurfaceIds: terminalSurfaceIds) }
    }

    // MARK: - Core Poll (called on queue)

    private func _poll(terminalSurfaceIds: [UUID]) -> [UUID: Bool] {
        guard !terminalSurfaceIds.isEmpty else { return [:] }

        let allProcs = allProcesses() ?? []
        let myPid = getpid()

        // Find all login children of Deckard
        let loginPids = allProcs
            .filter { $0.kp_eproc.e_ppid == myPid }
            .map { $0.kp_proc.p_pid }

        // For each login, find its shell child and determine if it's a terminal (non-Claude) tab
        var terminalLoginPids: [pid_t] = []
        for loginPid in loginPids {
            // Find the shell (login's child)
            guard let shellProc = allProcs.first(where: { $0.kp_eproc.e_ppid == loginPid }) else {
                continue
            }
            let shellPid = shellProc.kp_proc.p_pid

            // Check if this is a Claude session by looking at the foreground process name
            let shellInfo = getKInfoProc(pid: shellPid)
            let termFgPgid = shellInfo?.kp_eproc.e_tpgid ?? 0
            let shellPgid = shellInfo?.kp_eproc.e_pgid ?? 0

            if termFgPgid != shellPgid {
                // There's a foreground process — check if it's claude
                var name = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
                proc_name(termFgPgid, &name, UInt32(name.count))
                let processName = String(cString: name)
                if processName == "claude" {
                    continue  // Claude tab, skip
                }
            }

            // Also check if the shell itself was started by a claude wrapper
            // by checking if any child of the shell is named "claude"
            let shellChildren = allProcs.filter { $0.kp_eproc.e_ppid == shellPid }
            let hasClaude = shellChildren.contains { proc in
                var name = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
                proc_name(proc.kp_proc.p_pid, &name, UInt32(name.count))
                return String(cString: name) == "claude"
            }
            if hasClaude { continue }

            terminalLoginPids.append(loginPid)
        }

        // Match terminal logins to surface IDs by order
        // Both lists are in creation order (PIDs increase, tabs are appended in order)
        terminalLoginPids.sort()

        var results: [UUID: Bool] = [:]
        for (i, surfaceId) in terminalSurfaceIds.enumerated() {
            if i < terminalLoginPids.count {
                let loginPid = terminalLoginPids[i]
                results[surfaceId] = checkActivity(loginPid: loginPid, allProcs: allProcs)
            } else {
                results[surfaceId] = false
            }
        }

        // Clean up stale tracking data for logins no longer present
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

        // Find the leaf process in the foreground group
        let fgPid = findLeafProcess(inGroup: termFgPgid, allProcs: allProcs) ?? termFgPgid

        // Get CPU time, disk I/O, and network buffer state
        guard let cpuTime = getCpuTime(pid: fgPid) else { return false }
        let diskBytes = getDiskBytes(pid: fgPid) ?? 0
        let socketBytes = getSocketBufferBytes(pid: fgPid)

        // If the foreground process changed, reset baseline and show activity
        if lastFgPids[loginPid] != fgPid {
            lastFgPids[loginPid] = fgPid
            lastCpuTimes[loginPid] = cpuTime
            lastDiskBytes[loginPid] = diskBytes
            lastSocketBytes[loginPid] = socketBytes
            return true  // new process just started → pulse
        }

        let prevCpu = lastCpuTimes[loginPid] ?? cpuTime
        let prevDisk = lastDiskBytes[loginPid] ?? diskBytes
        let prevSocket = lastSocketBytes[loginPid] ?? socketBytes
        lastCpuTimes[loginPid] = cpuTime
        lastDiskBytes[loginPid] = diskBytes
        lastSocketBytes[loginPid] = socketBytes

        return cpuTime > prevCpu || diskBytes > prevDisk || socketBytes != prevSocket
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
