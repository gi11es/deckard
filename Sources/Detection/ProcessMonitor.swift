import Foundation
import Darwin

/// Monitors terminal tab shell processes to detect CPU, disk, and network activity.
/// Shell PIDs are registered by the window controller at tab creation time.
///
/// All mutable state is accessed exclusively on `queue` (a serial dispatch queue).
class ProcessMonitor {
    static let shared = ProcessMonitor()

    private let queue = DispatchQueue(label: "com.deckard.process-monitor")

    /// Registered mappings: surface UUID → login/shell PID (set by window controller).
    private var registeredPids: [UUID: pid_t] = [:]
    /// Last known foreground PID per shell (keyed by shell PID).
    private var lastFgPids: [pid_t: pid_t] = [:]
    /// CPU time (user + system nanoseconds) from the previous poll cycle (keyed by shell PID).
    private var lastCpuTimes: [pid_t: UInt64] = [:]
    /// Disk I/O bytes (read + written) from the previous poll cycle (keyed by shell PID).
    private var lastDiskBytes: [pid_t: UInt64] = [:]
    /// Total socket buffer bytes from the previous poll cycle (keyed by shell PID).
    private var lastSocketBytes: [pid_t: UInt64] = [:]

    // MARK: - Public API

    /// Register a shell/login PID for a surface. Called from the main thread at tab creation.
    func register(surfaceId: UUID, pid: pid_t) {
        queue.sync { registeredPids[surfaceId] = pid }
    }

    /// Unregister a surface (tab closed).
    func unregister(surfaceId: UUID) {
        queue.sync {
            if let pid = registeredPids.removeValue(forKey: surfaceId) {
                lastFgPids.removeValue(forKey: pid)
                lastCpuTimes.removeValue(forKey: pid)
                lastDiskBytes.removeValue(forKey: pid)
                lastSocketBytes.removeValue(forKey: pid)
            }
        }
    }

    /// Poll all registered terminal shells. Returns surface UUID → hasActivity.
    func pollAll() -> [UUID: Bool] {
        queue.sync { _pollAll() }
    }

    /// List PIDs of all direct children of this process.
    /// Used by the window controller to detect newly spawned shell processes.
    func childPids() -> [pid_t] {
        let myPid = getpid()
        guard let allProcs = allProcesses() else { return [] }
        return allProcs
            .filter { $0.kp_eproc.e_ppid == myPid }
            .map { $0.kp_proc.p_pid }
    }

    // MARK: - Core Poll (called on queue)

    private func _pollAll() -> [UUID: Bool] {
        let allProcs = allProcesses() ?? []

        var results: [UUID: Bool] = [:]
        for (surfaceId, shellPid) in registeredPids {
            guard getKInfoProc(pid: shellPid) != nil else {
                results[surfaceId] = false
                continue
            }
            results[surfaceId] = checkActivity(shellPid: shellPid, allProcs: allProcs)
        }
        return results
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

        // Get CPU time, disk I/O, and network buffer state for the foreground process
        guard let cpuTime = getCpuTime(pid: fgPid) else { return false }
        let diskBytes = getDiskBytes(pid: fgPid) ?? 0
        let socketBytes = getSocketBufferBytes(pid: fgPid)

        // If the foreground process changed, reset baseline and show activity
        if lastFgPids[shellPid] != fgPid {
            lastFgPids[shellPid] = fgPid
            lastCpuTimes[shellPid] = cpuTime
            lastDiskBytes[shellPid] = diskBytes
            lastSocketBytes[shellPid] = socketBytes
            return true  // new process just started → pulse
        }

        let prevCpu = lastCpuTimes[shellPid] ?? cpuTime
        let prevDisk = lastDiskBytes[shellPid] ?? diskBytes
        let prevSocket = lastSocketBytes[shellPid] ?? socketBytes
        lastCpuTimes[shellPid] = cpuTime
        lastDiskBytes[shellPid] = diskBytes
        lastSocketBytes[shellPid] = socketBytes

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

    /// Get cumulative disk I/O bytes (read + written) via proc_pid_rusage.
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
