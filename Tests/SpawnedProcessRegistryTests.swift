import XCTest
@testable import Deckard

final class SpawnedProcessRegistryTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawned-pids-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func entry(pid: Int32, sec: Int64 = 100, usec: Int64 = 5) -> SpawnedProcessRegistry.Entry {
        SpawnedProcessRegistry.Entry(pid: pid, startSec: sec, startUsec: usec, surfaceId: "S")
    }

    private func makeRegistry(ownPid: pid_t,
                              snapshots: @escaping (pid_t) -> SpawnedProcessRegistry.ProcessSnapshot?,
                              killer: @escaping (pid_t) -> Int32) -> SpawnedProcessRegistry {
        SpawnedProcessRegistry(directory: tempDir, ownPid: ownPid,
                               snapshotProvider: snapshots, killer: killer)
    }

    private func registryFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []).sorted()
    }

    // MARK: - Decision logic

    func testDecideForgetsDeadProcess() {
        XCTAssertEqual(SpawnedProcessRegistry.decide(entry: entry(pid: 42), snapshot: nil), .forget)
    }

    func testDecideForgetsReusedPid() {
        let snap = SpawnedProcessRegistry.ProcessSnapshot(ppid: 1, startSec: 999, startUsec: 5)
        XCTAssertEqual(SpawnedProcessRegistry.decide(entry: entry(pid: 42), snapshot: snap), .forget)
    }

    func testDecideKeepsParentedProcess() {
        let snap = SpawnedProcessRegistry.ProcessSnapshot(ppid: 4321, startSec: 100, startUsec: 5)
        XCTAssertEqual(SpawnedProcessRegistry.decide(entry: entry(pid: 42), snapshot: snap), .keep)
    }

    func testDecideKillsMatchingOrphan() {
        let snap = SpawnedProcessRegistry.ProcessSnapshot(ppid: 1, startSec: 100, startUsec: 5)
        XCTAssertEqual(SpawnedProcessRegistry.decide(entry: entry(pid: 42), snapshot: snap), .kill)
    }

    func testDecideNeverSignalsNonPositivePids() {
        let snap = SpawnedProcessRegistry.ProcessSnapshot(ppid: 1, startSec: 100, startUsec: 5)
        XCTAssertEqual(SpawnedProcessRegistry.decide(entry: entry(pid: 0), snapshot: snap), .forget)
        XCTAssertEqual(SpawnedProcessRegistry.decide(entry: entry(pid: -1), snapshot: snap), .forget)
    }

    // MARK: - Cross-instance reaping

    func testReapKillsDeadInstanceOrphansAndSkipsDeadAndReused() {
        // Instance A (pid 900) records three children, then "dies".
        var snapshots: [pid_t: SpawnedProcessRegistry.ProcessSnapshot] = [
            900: .init(ppid: 1000, startSec: 1, startUsec: 0),
            101: .init(ppid: 900, startSec: 10, startUsec: 1),
            102: .init(ppid: 900, startSec: 20, startUsec: 2),
            103: .init(ppid: 900, startSec: 30, startUsec: 3)
        ]
        let instanceA = makeRegistry(ownPid: 900, snapshots: { snapshots[$0] },
                                     killer: { _ in XCTFail("no kill expected yet"); return 0 })
        instanceA.record(pid: 101, surfaceId: "A")
        instanceA.record(pid: 102, surfaceId: "B")
        instanceA.record(pid: 103, surfaceId: "C")
        instanceA.flush()
        XCTAssertEqual(registryFiles(), ["spawned-pids-900.json"])

        // A dies: 101 orphaned, 102 dead, 103's pid reused by another process.
        snapshots[900] = nil
        snapshots[101] = .init(ppid: 1, startSec: 10, startUsec: 1)
        snapshots[102] = nil
        snapshots[103] = .init(ppid: 1, startSec: 777, startUsec: 7)

        var killedPids: [pid_t] = []
        let instanceB = makeRegistry(ownPid: 901, snapshots: { snapshots[$0] },
                                     killer: { killedPids.append($0); return 0 })
        XCTAssertEqual(instanceB.reapOrphans(), [101])
        XCTAssertEqual(killedPids, [101])
        // Everything resolved — dead instance's file is gone.
        XCTAssertEqual(registryFiles(), [])
    }

    func testReapSkipsLiveSiblingInstanceFile() {
        var snapshots: [pid_t: SpawnedProcessRegistry.ProcessSnapshot] = [
            900: .init(ppid: 1000, startSec: 1, startUsec: 0),
            101: .init(ppid: 900, startSec: 10, startUsec: 1)
        ]
        let sibling = makeRegistry(ownPid: 900, snapshots: { snapshots[$0] },
                                   killer: { _ in XCTFail("sibling kill"); return 0 })
        sibling.record(pid: 101, surfaceId: "A")
        sibling.flush()

        // Sibling instance 900 is still alive — its file must be untouched,
        // even though 101 could look reapable if misattributed.
        snapshots[101] = .init(ppid: 1, startSec: 10, startUsec: 1)
        let me = makeRegistry(ownPid: 901, snapshots: { snapshots[$0] },
                              killer: { _ in XCTFail("must not kill"); return 0 })
        XCTAssertEqual(me.reapOrphans(), [])
        XCTAssertEqual(registryFiles(), ["spawned-pids-900.json"])
    }

    func testReapProcessesStaleFileWithReusedOwnerPid() {
        // A dead instance's file whose owner pid now belongs to *us*
        // (pid reuse): owner start time mismatch → must be processed.
        var snapshots: [pid_t: SpawnedProcessRegistry.ProcessSnapshot] = [
            900: .init(ppid: 1000, startSec: 1, startUsec: 0),
            101: .init(ppid: 900, startSec: 10, startUsec: 1)
        ]
        let oldInstance = makeRegistry(ownPid: 900, snapshots: { snapshots[$0] },
                                       killer: { _ in 0 })
        oldInstance.record(pid: 101, surfaceId: "A")
        oldInstance.flush()

        // Relaunch reuses pid 900 with a different start time; 101 orphaned.
        snapshots[900] = .init(ppid: 1000, startSec: 999, startUsec: 9)
        snapshots[101] = .init(ppid: 1, startSec: 10, startUsec: 1)
        var killedPids: [pid_t] = []
        let newInstance = makeRegistry(ownPid: 900, snapshots: { snapshots[$0] },
                                       killer: { killedPids.append($0); return 0 })
        XCTAssertEqual(newInstance.reapOrphans(), [101])
        XCTAssertEqual(killedPids, [101])
    }

    func testReapRetainsKeptEntriesInFile() {
        var snapshots: [pid_t: SpawnedProcessRegistry.ProcessSnapshot] = [
            900: .init(ppid: 1000, startSec: 1, startUsec: 0),
            101: .init(ppid: 900, startSec: 10, startUsec: 1),
            102: .init(ppid: 900, startSec: 20, startUsec: 2)
        ]
        let instanceA = makeRegistry(ownPid: 900, snapshots: { snapshots[$0] }, killer: { _ in 0 })
        instanceA.record(pid: 101, surfaceId: "A")
        instanceA.record(pid: 102, surfaceId: "B")
        instanceA.flush()

        // A dies; 101 still parented elsewhere (keep), 102 orphaned (kill).
        snapshots[900] = nil
        snapshots[101] = .init(ppid: 555, startSec: 10, startUsec: 1)
        snapshots[102] = .init(ppid: 1, startSec: 20, startUsec: 2)
        let instanceB = makeRegistry(ownPid: 901, snapshots: { snapshots[$0] }, killer: { _ in 0 })
        XCTAssertEqual(instanceB.reapOrphans(), [102])
        XCTAssertEqual(registryFiles(), ["spawned-pids-900.json"])

        // The kept entry must still be in the file: once 101 becomes an
        // orphan, a later reap must still find and kill it.
        snapshots[101] = .init(ppid: 1, startSec: 10, startUsec: 1)
        var killedPids: [pid_t] = []
        let instanceC = makeRegistry(ownPid: 902, snapshots: { snapshots[$0] },
                                     killer: { killedPids.append($0); return 0 })
        XCTAssertEqual(instanceC.reapOrphans(), [101])
        XCTAssertEqual(killedPids, [101])
        XCTAssertEqual(registryFiles(), [])
    }

    func testReapRetainsEntryWhenKillFails() {
        var snapshots: [pid_t: SpawnedProcessRegistry.ProcessSnapshot] = [
            101: .init(ppid: 1, startSec: 10, startUsec: 1)
        ]
        let dir = tempDir!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Legacy ownerless file so it is always processed.
        let legacy = [entry(pid: 101, sec: 10, usec: 1)]
        try? JSONEncoder().encode(legacy).write(to: dir.appendingPathComponent("spawned-pids.json"))

        let registry = makeRegistry(ownPid: 901, snapshots: { snapshots[$0] },
                                    killer: { _ in EPERM })
        XCTAssertEqual(registry.reapOrphans(), [])
        // Kill failed → entry retained for a future attempt.
        XCTAssertEqual(registryFiles(), ["spawned-pids.json"])

        var killedPids: [pid_t] = []
        let retry = makeRegistry(ownPid: 902, snapshots: { snapshots[$0] },
                                 killer: { killedPids.append($0); return 0 })
        XCTAssertEqual(retry.reapOrphans(), [101])
        XCTAssertEqual(killedPids, [101])
    }

    func testReapMigratesLegacyFormatAndIgnoresCorruptFiles() {
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let legacy = [entry(pid: 101, sec: 10, usec: 1)]
        try? JSONEncoder().encode(legacy).write(to: tempDir.appendingPathComponent("spawned-pids.json"))
        try? Data("not json{".utf8).write(to: tempDir.appendingPathComponent("spawned-pids-777.json"))

        var killedPids: [pid_t] = []
        let registry = makeRegistry(
            ownPid: 901,
            snapshots: { pid in pid == 101 ? .init(ppid: 1, startSec: 10, startUsec: 1) : nil },
            killer: { killedPids.append($0); return 0 })
        XCTAssertEqual(registry.reapOrphans(), [101])
        XCTAssertEqual(killedPids, [101])
        // Legacy file consumed; corrupt file left untouched, not treated as empty.
        XCTAssertEqual(registryFiles(), ["spawned-pids-777.json"])
    }

    // MARK: - Record/remove lifecycle

    func testRemoveDropsEntryAndDeletesEmptyFile() {
        let snap = SpawnedProcessRegistry.ProcessSnapshot(ppid: 900, startSec: 10, startUsec: 1)
        let registry = makeRegistry(ownPid: 900, snapshots: { _ in snap }, killer: { _ in 0 })
        registry.record(pid: 201, surfaceId: "A")
        registry.flush()
        XCTAssertEqual(registryFiles(), ["spawned-pids-900.json"])
        registry.remove(pid: 201)
        registry.flush()
        XCTAssertEqual(registryFiles(), [])
    }

    func testRecordSamePidReplacesEntry() {
        var snapshots: [pid_t: SpawnedProcessRegistry.ProcessSnapshot] = [
            900: .init(ppid: 1000, startSec: 1, startUsec: 0),
            301: .init(ppid: 900, startSec: 10, startUsec: 1)
        ]
        let instanceA = makeRegistry(ownPid: 900, snapshots: { snapshots[$0] }, killer: { _ in 0 })
        instanceA.record(pid: 301, surfaceId: "A")
        instanceA.record(pid: 301, surfaceId: "B")
        instanceA.flush()

        snapshots[900] = nil
        snapshots[301] = .init(ppid: 1, startSec: 10, startUsec: 1)
        var killedPids: [pid_t] = []
        let instanceB = makeRegistry(ownPid: 901, snapshots: { snapshots[$0] },
                                     killer: { killedPids.append($0); return 0 })
        XCTAssertEqual(instanceB.reapOrphans(), [301])
        XCTAssertEqual(killedPids, [301], "duplicate record must not kill twice")
    }

    // MARK: - System snapshot sanity

    func testSystemSnapshotOfSelf() {
        let snap = SpawnedProcessRegistry.systemSnapshot(pid: getpid())
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.ppid, getppid())
        XCTAssertGreaterThan(snap?.startSec ?? 0, 0)
    }

    func testSystemSnapshotOfDeadPidIsNil() {
        XCTAssertNil(SpawnedProcessRegistry.systemSnapshot(pid: 99_999_999))
    }
}
