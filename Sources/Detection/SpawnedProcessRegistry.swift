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
/// guard against PID reuse); confirmed process exits remove the record. At
/// launch, before session restore respawns anything, `reapOrphans()` kills
/// recorded processes that are still alive but have been reparented to
/// launchd (ppid == 1).
///
/// Each app instance writes its own registry file
/// (`spawned-pids-<pid>.json`, stamped with the owner's pid + start time)
/// so concurrent instances (e.g. a Debug build next to the installed app)
/// never clobber each other's records. `reapOrphans()` scans all registry
/// files: files whose owning instance is still alive are skipped; files of
/// dead instances are processed and deleted.
final class SpawnedProcessRegistry {
    static let shared = SpawnedProcessRegistry()

    struct Entry: Codable, Equatable {
        let pid: Int32
        /// Kernel process start time, seconds and microseconds since epoch.
        let startSec: Int64
        let startUsec: Int64
        let surfaceId: String
    }

    /// On-disk format: entries plus the identity of the app instance that
    /// owns the file, so reap can tell live siblings from dead ancestors.
    private struct RegistryFile: Codable {
        var version: Int
        var ownerPid: Int32
        var ownerStartSec: Int64
        var ownerStartUsec: Int64
        var entries: [Entry]
    }

    private static let formatVersion = 1
    private static let filePrefix = "spawned-pids"

    /// Live process facts used for reap decisions. Injectable for tests.
    struct ProcessSnapshot: Equatable {
        let ppid: pid_t
        let startSec: Int64
        let startUsec: Int64
    }

    enum ReapDecision: Equatable {
        /// Process is gone (or its PID was reused) — drop the record.
        case forget
        /// Process is alive but still parented — keep the record untouched.
        case keep
        /// Process is alive, matches the recorded start time, and has been
        /// reparented to launchd — kill it and drop the record.
        case kill
    }

    private let queue = DispatchQueue(label: "com.deckard.spawned-process-registry")
    private let directory: URL
    private let ownPid: pid_t
    private let snapshotProvider: (pid_t) -> ProcessSnapshot?
    /// Kills a pid and returns 0 on success or the failing errno.
    private let killer: (pid_t) -> Int32
    private var entries: [Entry] = []

    init(directory: URL? = nil,
         ownPid: pid_t = getpid(),
         snapshotProvider: @escaping (pid_t) -> ProcessSnapshot? = SpawnedProcessRegistry.systemSnapshot,
         killer: @escaping (pid_t) -> Int32 = { Darwin.kill($0, SIGKILL) == 0 ? 0 : errno }) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                      in: .userDomainMask).first!
            self.directory = appSupport.appendingPathComponent("Deckard")
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        self.ownPid = ownPid
        self.snapshotProvider = snapshotProvider
        self.killer = killer
    }

    private var ownFileURL: URL {
        directory.appendingPathComponent("\(Self.filePrefix)-\(ownPid).json")
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

    /// Remove the record for a PID whose exit has been confirmed.
    /// Only call once the process is known dead (`processTerminated`) —
    /// removing on mere kill *intent* would make a SIGTERM-surviving agent
    /// permanently unreapable, recreating #100.
    func remove(pid: pid_t) {
        queue.async { [self] in
            entries.removeAll { $0.pid == pid }
            persist()
        }
    }

    /// Kill processes recorded by previous (now dead) app instances that are
    /// still alive as orphans. Call at launch BEFORE session restore spawns
    /// replacements. Returns the PIDs that were killed.
    @discardableResult
    func reapOrphans() -> [pid_t] {
        queue.sync { [self] in
            var killed: [pid_t] = []
            let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: nil))?
                .filter { $0.lastPathComponent.hasPrefix(Self.filePrefix) &&
                          $0.pathExtension == "json" } ?? []
            for file in files {
                guard let registry = Self.load(file) else {
                    // Unreadable or unknown future format — leave it alone.
                    DiagnosticLog.shared.log("surface",
                        "reapOrphans: skipping undecodable registry file \(file.lastPathComponent)")
                    continue
                }
                if let owner = registry.owner,
                   let snap = snapshotProvider(owner.pid),
                   snap.startSec == owner.startSec, snap.startUsec == owner.startUsec {
                    // Owning instance is alive (start time proves it's not a
                    // reused pid) — its records, its business. This also
                    // covers our own fresh file.
                    continue
                }
                var kept: [Entry] = []
                for entry in registry.entries {
                    switch Self.decide(entry: entry, snapshot: snapshotProvider(entry.pid)) {
                    case .forget:
                        break
                    case .keep:
                        kept.append(entry)
                    case .kill:
                        let err = killer(entry.pid)
                        if err == 0 {
                            killed.append(entry.pid)
                            DiagnosticLog.shared.log("surface",
                                "reapOrphans: killed orphaned pid=\(entry.pid) surfaceId=\(entry.surfaceId)")
                        } else {
                            kept.append(entry)
                            DiagnosticLog.shared.log("surface",
                                "reapOrphans: kill failed pid=\(entry.pid) errno=\(err)")
                        }
                    }
                }
                if kept.isEmpty {
                    try? FileManager.default.removeItem(at: file)
                } else if kept != registry.entries {
                    Self.save(kept, owner: registry.owner, to: file)
                }
            }
            return killed
        }
    }

    /// Block until queued record/remove writes have been applied (for tests).
    func flush() {
        queue.sync {}
    }

    // MARK: - Decision logic (pure, tested)

    static func decide(entry: Entry, snapshot: ProcessSnapshot?) -> ReapDecision {
        // Never signal pid <= 0 (kill(0)/kill(-1) target whole process groups).
        guard entry.pid > 0 else { return .forget }
        guard let snapshot else { return .forget }
        // Start time mismatch means the PID was reused by an unrelated process.
        guard snapshot.startSec == entry.startSec, snapshot.startUsec == entry.startUsec else {
            return .forget
        }
        // Still parented — not an orphan (should not happen for a dead owner,
        // but never kill a process some live parent still manages).
        guard snapshot.ppid == 1 else { return .keep }
        // SIGKILL rather than SIGTERM+wait: agents observably ignore SIGTERM
        // for seconds while idle-orphaned, and their session-file appends are
        // single write() calls, so a graceful window buys little and delays
        // every crash-recovery launch.
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

    // MARK: - Persistence

    private struct Owner {
        let pid: Int32
        let startSec: Int64
        let startUsec: Int64
    }

    private struct LoadedRegistry {
        let owner: Owner?
        let entries: [Entry]
    }

    private static func load(_ url: URL) -> LoadedRegistry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let file = try? JSONDecoder().decode(RegistryFile.self, from: data),
           file.version <= formatVersion {
            return LoadedRegistry(owner: Owner(pid: file.ownerPid,
                                               startSec: file.ownerStartSec,
                                               startUsec: file.ownerStartUsec),
                                  entries: file.entries)
        }
        // Legacy format: bare [Entry] array with no owner stamp.
        if let entries = try? JSONDecoder().decode([Entry].self, from: data) {
            return LoadedRegistry(owner: nil, entries: entries)
        }
        return nil
    }

    private static func save(_ entries: [Entry], owner: Owner?, to url: URL) {
        let file = RegistryFile(version: formatVersion,
                                ownerPid: owner?.pid ?? 0,
                                ownerStartSec: owner?.startSec ?? 0,
                                ownerStartUsec: owner?.startUsec ?? 0,
                                entries: entries)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Write our own registry file (called on queue).
    private func persist() {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: ownFileURL)
            return
        }
        let ownStart = snapshotProvider(ownPid)
        Self.save(entries,
                  owner: Owner(pid: ownPid,
                               startSec: ownStart?.startSec ?? 0,
                               startUsec: ownStart?.startUsec ?? 0),
                  to: ownFileURL)
    }
}
