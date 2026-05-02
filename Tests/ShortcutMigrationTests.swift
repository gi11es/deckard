import XCTest
@testable import Deckard

final class ShortcutMigrationTests: XCTestCase {

    // Each test runs in an isolated UserDefaults suite to avoid touching the user's
    // real shortcut configuration.
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "DeckardShortcutMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMigratesOldIdentifierToNewKey() {
        // Simulate a user override saved under the v2 identifier.
        defaults.set("legacy-value", forKey: "KeyboardShortcuts_newSidebarFolder")

        DeckardShortcutMigration.migrate(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "KeyboardShortcuts_newGroup"), "legacy-value")
        XCTAssertNil(defaults.object(forKey: "KeyboardShortcuts_newSidebarFolder"),
                     "Old key must be removed after migration")
        XCTAssertTrue(defaults.bool(forKey: DeckardShortcutMigration.migrationFlagKey),
                      "Migration flag must be set so it doesn't run again")
    }

    func testMigratesAllRenamedIdentifiers() {
        defaults.set("a", forKey: "KeyboardShortcuts_newSidebarFolder")
        defaults.set("b", forKey: "KeyboardShortcuts_moveOutOfFolder")
        defaults.set("c", forKey: "KeyboardShortcuts_openFolder")
        defaults.set("d", forKey: "KeyboardShortcuts_closeFolder")
        defaults.set("e", forKey: "KeyboardShortcuts_nextProject")
        defaults.set("f", forKey: "KeyboardShortcuts_previousProject")

        DeckardShortcutMigration.migrate(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "KeyboardShortcuts_newGroup"), "a")
        XCTAssertEqual(defaults.string(forKey: "KeyboardShortcuts_moveOutOfGroup"), "b")
        XCTAssertEqual(defaults.string(forKey: "KeyboardShortcuts_openWorkspace"), "c")
        XCTAssertEqual(defaults.string(forKey: "KeyboardShortcuts_closeWorkspace"), "d")
        XCTAssertEqual(defaults.string(forKey: "KeyboardShortcuts_nextWorkspace"), "e")
        XCTAssertEqual(defaults.string(forKey: "KeyboardShortcuts_previousWorkspace"), "f")
        // All old keys removed
        for old in ["newSidebarFolder", "moveOutOfFolder", "openFolder", "closeFolder", "nextProject", "previousProject"] {
            XCTAssertNil(defaults.object(forKey: "KeyboardShortcuts_\(old)"),
                         "Old key \(old) must be removed")
        }
    }

    func testDoesNotRunTwice() {
        defaults.set("first-run", forKey: "KeyboardShortcuts_newSidebarFolder")
        DeckardShortcutMigration.migrate(defaults: defaults)

        // Simulate the user later setting an override on the OLD key (e.g. by
        // downgrading then upgrading again). The second migration call must be
        // a no-op so the user's recent choice on the new key isn't clobbered.
        defaults.set("late-legacy", forKey: "KeyboardShortcuts_newSidebarFolder")
        defaults.set("user-choice", forKey: "KeyboardShortcuts_newGroup")
        DeckardShortcutMigration.migrate(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "KeyboardShortcuts_newGroup"), "user-choice")
        XCTAssertEqual(defaults.string(forKey: "KeyboardShortcuts_newSidebarFolder"), "late-legacy",
                       "Second migration call must be a no-op — flag prevents re-run")
    }

    func testNoLegacyKeysIsNoop() {
        // First run with no legacy keys present: migration just sets the flag.
        DeckardShortcutMigration.migrate(defaults: defaults)

        XCTAssertTrue(defaults.bool(forKey: DeckardShortcutMigration.migrationFlagKey))
        XCTAssertNil(defaults.object(forKey: "KeyboardShortcuts_newGroup"))
        XCTAssertNil(defaults.object(forKey: "KeyboardShortcuts_moveOutOfGroup"))
    }

    func testDoesNotOverwriteExistingNewKey() {
        // If the user already has a value under the new key, don't clobber it
        // with the legacy value.
        defaults.set("legacy", forKey: "KeyboardShortcuts_newSidebarFolder")
        defaults.set("already-set", forKey: "KeyboardShortcuts_newGroup")

        DeckardShortcutMigration.migrate(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "KeyboardShortcuts_newGroup"), "already-set")
        XCTAssertNil(defaults.object(forKey: "KeyboardShortcuts_newSidebarFolder"),
                     "Old key is still removed even when new key already had a value")
    }
}
