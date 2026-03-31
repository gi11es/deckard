import XCTest
@testable import Deckard

final class ClaudeCLIFlagsTests: XCTestCase {

    // Sample help output (subset of real `claude --help`)
    private let sampleHelp = """
    Options:
      --add-dir <directories...>                        Additional directories to allow tool access to
      --verbose                                         Override verbose mode setting from config
      --permission-mode <mode>                          Permission mode to use for the session (choices: "acceptEdits", "bypassPermissions", "default", "dontAsk", "plan", "auto")
      --effort <level>                                  Effort level for the current session (low, medium, high, max)
      --model <model>                                   Model for the current session. Provide an alias for the latest model (e.g. 'sonnet' or 'opus') or a model's full name (e.g. 'claude-sonnet-4-6').
      -c, --continue                                    Continue the most recent conversation in the current directory
      -d, --debug [filter]                              Enable debug mode with optional category filtering (e.g., "api,hooks" or "!1p,!file")
      -p, --print                                       Print response and exit (useful for pipes).
      --allowedTools, --allowed-tools <tools...>        Comma or space-separated list of tool names to allow (e.g. "Bash(git:*) Edit")
      -v, --version                                     Output the version number
      -h, --help                                        Display help for command
      --resume [value]                                  Resume a conversation by session ID
    """

    func testParsesBooleanFlag() {
        let flags = ClaudeCLIFlags.parse(helpOutput: sampleHelp)
        let verbose = flags.first { $0.longName == "--verbose" }
        XCTAssertNotNil(verbose)
        XCTAssertEqual(verbose?.valueType, .boolean)
        XCTAssertNil(verbose?.shortName)
    }

    func testParsesFlagWithShortName() {
        let flags = ClaudeCLIFlags.parse(helpOutput: sampleHelp)
        let debug = flags.first { $0.longName == "--debug" }
        XCTAssertNotNil(debug)
        XCTAssertEqual(debug?.shortName, "-d")
    }

    func testParsesExplicitChoices() {
        let flags = ClaudeCLIFlags.parse(helpOutput: sampleHelp)
        let permMode = flags.first { $0.longName == "--permission-mode" }
        XCTAssertNotNil(permMode)
        guard case .enumeration(let values) = permMode?.valueType else {
            XCTFail("Expected enumeration"); return
        }
        XCTAssertEqual(values, ["acceptEdits", "bypassPermissions", "default", "dontAsk", "plan", "auto"])
    }

    func testParsesInformalEnum() {
        let flags = ClaudeCLIFlags.parse(helpOutput: sampleHelp)
        let effort = flags.first { $0.longName == "--effort" }
        XCTAssertNotNil(effort)
        guard case .enumeration(let values) = effort?.valueType else {
            XCTFail("Expected enumeration"); return
        }
        XCTAssertEqual(values, ["low", "medium", "high", "max"])
    }

    func testParsesFreeTextValue() {
        let flags = ClaudeCLIFlags.parse(helpOutput: sampleHelp)
        let model = flags.first { $0.longName == "--model" }
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.valueType, .freeText)
        XCTAssertEqual(model?.valuePlaceholder, "<model>")
    }

    func testBlocklistExcludesInternalFlags() {
        let flags = ClaudeCLIFlags.parse(helpOutput: sampleHelp)
        let longNames = flags.map(\.longName)
        XCTAssertFalse(longNames.contains("--continue"))
        XCTAssertFalse(longNames.contains("--print"))
        XCTAssertFalse(longNames.contains("--version"))
        XCTAssertFalse(longNames.contains("--help"))
        XCTAssertFalse(longNames.contains("--resume"))
    }

    func testParsesAliasedFlag() {
        let flags = ClaudeCLIFlags.parse(helpOutput: sampleHelp)
        // --allowedTools, --allowed-tools should produce one entry
        let allowed = flags.first { $0.longName == "--allowed-tools" }
        XCTAssertNotNil(allowed)
        XCTAssertEqual(allowed?.valueType, .freeText)
    }

    func testEmptyInputReturnsEmptyArray() {
        let flags = ClaudeCLIFlags.parse(helpOutput: "")
        XCTAssertTrue(flags.isEmpty)
    }
}
