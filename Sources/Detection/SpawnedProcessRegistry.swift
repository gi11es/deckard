import Foundation
import Darwin

/// Tracks direct-spawn (non-tmux) shell PIDs across app runs so that a crash
/// or force-kill of Deckard doesn't leave orphaned agent processes behind.
///
/// Agent processes (claude, codex) ignore the PTY hangup when the app dies,
/// so they survive as invisible orphans — and session restore then resumes
/// the same sessions again, leaving two live processes appending to one
/// session file (#100).
///
/// Every direct spawn is recorded with the kernel process start time (to
/// guard against PID reuse); clean exits remove the record. At launch,
/// before session restore respawns anything, `reapOrphans()` kills recorded
/// processes that are still alive but have been reparented to launchd
/// (ppid == 1).
final class SpawnedProcessRegistry {
    static let shared = SpawnedProcessRegistry()

    struct Entry: Codable, Equatable {
        let pid: Int32
        /// Kernel process start time, seconds and microseconds since epoch.
        let startSec: Int64
        let startUsec: Int64
        let surfaceId: String
    }

    /// Live process facts used for reap decisions. Injectable for tests.
    struct ProcessSnapshot: Equatable {
        let ppid: pid_t
        let startSec: Int64
        let startUsec: Int64
    }

    enum ReapDecision: Equatable {
        /// Process is gone (or its PID was reused) — drop the record.
        case forget
        /// Process is alive but still parented (e.g. a second live Deckard
        /// instance owns it) — keep the record, do not touch the process.
        case keep
        /// Process is alive, matches the recorded start time, and has been
        /// reparented to launchd — kill it and drop the record.
        case kill
    }

    private let queue = DispatchQueue(label: "com.deckard.spawned-process-registry")
    private let fileURL: URL
    private let snapshotProvider: (pid_t) -> ProcessSnapshot?
    private let killer: (pid_t) -> Void
    private var entries: [Entry]

    init(fileURL: URL? = nil,
         snapshotProvider: @escaping (pid_t) -> ProcessSnapshot? = SpawnedProcessRegistry.systemSnapshot,
         killer: @escaping (pid_t) -> Void = { Darwin.kill($0, SIGKILL) }) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                      in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("Deckard")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("spawned-pids.json")
        }
        self.snapshotProvider = snapshotProvider
        self.killer = killer
        if let data = try? Data(contentsOf: self.fileURL),
           let loaded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = loaded
        } else {
            entries = []
        }
    }

    // MARK: - Public API

    /// Record a freshly spawned direct (non-tmux) shell PID.
    func record(pid: pid_t, surfaceId: String) {
        guard pid > 0, let snap = snapshotProvider(pid) else { return }
        queue.async { [self] in
            entries.removeAll { $0.pid == pid }
            entries.append(Entry(pid: pid, startSec: snap.startSec,
                                 startUsec: snap.startUsec, surfaceId: surfaceId))
            persist()
        }
    }

    /// Remove the record for a cleanly exited or terminated PID.
    func remove(pid: pid_t) {
        queue.async { [self] in
            entries.removeAll { $0.pid == pid }
            persist()
        }
    }

    /// Kill recorded processes orphaned by a previous app instance.
    /// Call at launch BEFORE session restore spawns replacements.
    /// Returns the PIDs that were killed.
    @discardableResult
    func reapOrphans() -> [pid_t] {
        queue.sync { [self] in
            var killed: [pid_t] = []
            var kept: [Entry] = []
            for entry in entries {
                switch Self.decide(entry: entry, snapshot: snapshotProvider(entry.pid)) {
                case .forget:
                    break
                case .keep:
                    kept.append(entry)
                case .kill:
                    killer(entry.pid)
                    killed.append(entry.pid)
                    DiagnosticLog.shared.log("surface",
                        "reapOrphans: killed orphaned pid=\(entry.pid) surfaceId=\(entry.surfaceId)")
                }
            }
            entries = kept
            persist()
            return killed
        }
    }

    /// Block until queued record/remove writes have been applied (for tests).
    func flush() {
        queue.sync {}
    }

    // MARK: - Decision logic (pure, tested)

    static func decide(entry: Entry, snapshot: ProcessSnapshot?) -> ReapDecision {
        guard let snapshot else { return .forget }
        // Start time mismatch means the PID was reused by an unrelated process.
        guard snapshot.startSec == entry.startSec, snapshot.startUsec == entry.startUsec else {
            return .forget
        }
        // Still parented — likely owned by another live Deckard instance.
        guard snapshot.ppid == 1 else { return .keep }
        return .kill
    }

    // MARK: - System snapshot

    static func systemSnapshot(pid: pid_t) -> ProcessSnapshot? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid else { return nil }
        return ProcessSnapshot(ppid: info.kp_eproc.e_ppid,
                               startSec: Int64(info.kp_proc.p_starttime.tv_sec),
                               startUsec: Int64(info.kp_proc.p_starttime.tv_usec))
    }

    // MARK: - Persistence (called on queue)

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
