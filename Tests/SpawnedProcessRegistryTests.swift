import XCTest
@testable import Deckard

final class SpawnedProcessRegistryTests: XCTestCase {
    private var tempFile: URL!

    override func setUp() {
        super.setUp()
        tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawned-pids-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempFile)
        super.tearDown()
    }

    private func entry(pid: Int32, sec: Int64 = 100, usec: Int64 = 5) -> SpawnedProcessRegistry.Entry {
        SpawnedProcessRegistry.Entry(pid: pid, startSec: sec, startUsec: usec, surfaceId: "S")
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

    // MARK: - Registry behavior

    func testRecordPersistsAndReapKillsOnlyOrphans() {
        var snapshots: [pid_t: SpawnedProcessRegistry.ProcessSnapshot] = [
            101: .init(ppid: 500, startSec: 10, startUsec: 1),  // parented (alive Deckard)
            102: .init(ppid: 500, startSec: 20, startUsec: 2),  // will become orphan
            103: .init(ppid: 500, startSec: 30, startUsec: 3)   // will die
        ]
        let registry1 = SpawnedProcessRegistry(fileURL: tempFile,
                                               snapshotProvider: { snapshots[$0] },
                                               killer: { _ in XCTFail("no kill expected yet") })
        registry1.record(pid: 101, surfaceId: "A")
        registry1.record(pid: 102, surfaceId: "B")
        registry1.record(pid: 103, surfaceId: "C")
        registry1.flush()

        // Simulate app death and relaunch: 102 reparented to launchd, 103 gone.
        snapshots[102] = .init(ppid: 1, startSec: 20, startUsec: 2)
        snapshots[103] = nil

        var killedPids: [pid_t] = []
        let registry2 = SpawnedProcessRegistry(fileURL: tempFile,
                                               snapshotProvider: { snapshots[$0] },
                                               killer: { killedPids.append($0) })
        let reaped = registry2.reapOrphans()

        XCTAssertEqual(killedPids, [102])
        XCTAssertEqual(reaped, [102])

        // Registry file should retain only the still-parented process.
        let registry3 = SpawnedProcessRegistry(fileURL: tempFile,
                                               snapshotProvider: { snapshots[$0] },
                                               killer: { _ in XCTFail("nothing left to kill") })
        XCTAssertEqual(registry3.reapOrphans(), [])
    }

    func testRemoveDropsEntry() {
        let snap = SpawnedProcessRegistry.ProcessSnapshot(ppid: 1, startSec: 10, startUsec: 1)
        var killedPids: [pid_t] = []
        let registry = SpawnedProcessRegistry(fileURL: tempFile,
                                              snapshotProvider: { _ in snap },
                                              killer: { killedPids.append($0) })
        registry.record(pid: 201, surfaceId: "A")
        registry.remove(pid: 201)
        registry.flush()
        XCTAssertEqual(registry.reapOrphans(), [])
        XCTAssertTrue(killedPids.isEmpty)
    }

    func testRecordSamePidReplacesEntry() {
        let snap = SpawnedProcessRegistry.ProcessSnapshot(ppid: 1, startSec: 10, startUsec: 1)
        var killedPids: [pid_t] = []
        let registry = SpawnedProcessRegistry(fileURL: tempFile,
                                              snapshotProvider: { _ in snap },
                                              killer: { killedPids.append($0) })
        registry.record(pid: 301, surfaceId: "A")
        registry.record(pid: 301, surfaceId: "B")
        registry.flush()
        XCTAssertEqual(registry.reapOrphans(), [301])
        XCTAssertEqual(killedPids, [301])
    }

    // MARK: - System snapshot sanity

    func testSystemSnapshotOfSelf() {
        let snap = SpawnedProcessRegistry.systemSnapshot(pid: getpid())
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.ppid, getppid())
        XCTAssertGreaterThan(snap?.startSec ?? 0, 0)
    }

    func testSystemSnapshotOfDeadPidIsNil() {
        // PID 0 is the kernel; sysctl returns it, but a huge unused pid should fail.
        XCTAssertNil(SpawnedProcessRegistry.systemSnapshot(pid: 99_999_999))
    }
}
