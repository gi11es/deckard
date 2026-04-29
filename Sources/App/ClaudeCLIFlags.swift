import Foundation

/// Represents a single CLI flag parsed from a supported agent CLI's help output.
struct ClaudeFlag {
    let longName: String
    let shortName: String?
    let description: String
    let valueType: ValueType
    let valuePlaceholder: String?

    enum ValueType: Equatable {
        case boolean
        case freeText
        case enumeration([String])
    }
}

private enum CLIHelpParser {
    /// Parse CLI help output into structured flags.
    static func parse(
        helpOutput: String,
        blocklist: Set<String>,
        valueTypeOverrides: [String: ClaudeFlag.ValueType] = [:]
    ) -> [ClaudeFlag] {
        let lines = helpOutput.components(separatedBy: .newlines)
        var results: [ClaudeFlag] = []
        var index = 0

        while index < lines.count {
            guard let header = parseOptionHeader(lines[index]) else {
                index += 1
                continue
            }

            var descriptionParts: [String] = []
            if let inlineDescription = header.inlineDescription {
                descriptionParts.append(inlineDescription)
            }

            var nextIndex = index + 1
            while nextIndex < lines.count {
                let line = lines[nextIndex]
                if parseOptionHeader(line) != nil { break }
                if !line.isEmpty, line.first?.isWhitespace != true { break }

                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    descriptionParts.append(trimmed)
                }
                nextIndex += 1
            }

            index = max(nextIndex, index + 1)

            if blocklist.contains(header.longName) { continue }

            let description = descriptionParts
                .joined(separator: " ")
                .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            let parsedType = determineValueType(placeholder: header.placeholder, description: description)
            let valueType = valueTypeOverrides[header.longName] ?? parsedType

            results.append(ClaudeFlag(
                longName: header.longName,
                shortName: header.shortName,
                description: description,
                valueType: valueType,
                valuePlaceholder: valueType == .boolean ? nil : header.placeholder.map { "<\($0)>" }
            ))
        }

        return results
    }

    private struct OptionHeader {
        let shortName: String?
        let longName: String
        let placeholder: String?
        let inlineDescription: String?
    }

    private static func parseOptionHeader(_ line: String) -> OptionHeader? {
        // Matches lines like:
        //   --flag <value>   Description
        //   -s, --flag <value>
        //   --aliasA, --aliasB <value>   Description
        // Groups: (1) short flag, (2) last long flag, (3) value placeholder, (4) description
        let pattern = #"^\s+(?:(-\w),\s+)?(?:--[\w-]+,\s+)*(--[\w-]+)(?:\s+[\[<]([^\]>]+)[\]>](?:\.{3})?)?(?:\s{2,}(.+))?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        else { return nil }

        let nsString = line as NSString
        let shortName = match.range(at: 1).location != NSNotFound
            ? nsString.substring(with: match.range(at: 1)) : nil
        let longName = nsString.substring(with: match.range(at: 2))
        let placeholder = match.range(at: 3).location != NSNotFound
            ? nsString.substring(with: match.range(at: 3)) : nil
        let inlineDescription = match.range(at: 4).location != NSNotFound
            ? nsString.substring(with: match.range(at: 4)) : nil

        return OptionHeader(
            shortName: shortName,
            longName: longName,
            placeholder: placeholder,
            inlineDescription: inlineDescription
        )
    }

    private static func determineValueType(placeholder: String?, description: String) -> ClaudeFlag.ValueType {
        guard placeholder != nil else { return .boolean }

        // Explicit choices: (choices: "a", "b", "c")
        if let choicesMatch = description.range(of: #"\(choices:\s*(.+?)\)"#, options: .regularExpression) {
            let choicesStr = String(description[choicesMatch])
            let quotedPattern = #""([^"]+)""#
            if let quotedRegex = try? NSRegularExpression(pattern: quotedPattern) {
                let nsStr = choicesStr as NSString
                let matches = quotedRegex.matches(in: choicesStr, range: NSRange(location: 0, length: nsStr.length))
                let values = matches.map { nsStr.substring(with: $0.range(at: 1)) }
                if !values.isEmpty {
                    return .enumeration(values)
                }
            }
        }

        // Clap-style possible values: [possible values: a, b, c]
        if let valuesMatch = description.range(of: #"\[possible values:\s*([^\]]+)\]"#, options: [.regularExpression, .caseInsensitive]) {
            let valuesText = String(description[valuesMatch])
                .replacingOccurrences(of: #"\[possible values:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "]", with: "")
            let values = valuesText.split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !values.isEmpty {
                return .enumeration(values)
            }
        }

        // Clap-style bullet list after "Possible values:".
        if description.range(of: "Possible values:", options: .caseInsensitive) != nil {
            let pattern = #"-\s+([a-zA-Z][\w-]*)\s*:"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let nsStr = description as NSString
                let matches = regex.matches(in: description, range: NSRange(location: 0, length: nsStr.length))
                let values = matches.map { nsStr.substring(with: $0.range(at: 1)) }
                if !values.isEmpty {
                    return .enumeration(values)
                }
            }
        }

        // Simple parenthetical choices: (lmstudio or ollama)
        if let orMatch = description.range(
            of: #"\(([a-zA-Z][\w-]{0,19})\s+or\s+([a-zA-Z][\w-]{0,19})\)"#,
            options: .regularExpression
        ) {
            let text = String(description[orMatch].dropFirst().dropLast())
            let values = text.components(separatedBy: " or ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if values.count == 2 {
                return .enumeration(values)
            }
        }

        // Informal enum: description ends with (word, word, word)
        if let informalMatch = description.range(
            of: #"\(([a-zA-Z][\w-]{0,19}(?:,\s*[a-zA-Z][\w-]{0,19}){1,7})\)\s*$"#,
            options: .regularExpression
        ) {
            let inner = String(description[informalMatch].dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
            let items = inner.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            if items.count >= 2 && items.count <= 8 && items.allSatisfy({ !$0.contains(" ") && $0.count <= 20 }) {
                return .enumeration(items)
            }
        }

        return .freeText
    }
}

/// Parses and caches CLI flags from `claude --help`.
final class ClaudeCLIFlags {

    static let shared = ClaudeCLIFlags()
    private init() {}

    /// Parsed flags. Empty until `load()` completes (or if claude is not installed).
    private(set) var flags: [ClaudeFlag] = []

    /// Flags Deckard manages internally — excluded from suggestions.
    static let blocklist: Set<String> = [
        "--resume", "--continue", "--fork-session", "--print", "--version", "--help",
        "--output-format", "--input-format", "--include-partial-messages",
        "--replay-user-messages", "--json-schema", "--max-budget-usd",
        "--no-session-persistence", "--fallback-model", "--from-pr", "--session-id",
    ]

    /// Flags whose parsed valueType is overridden.
    /// e.g. --worktree normally takes an optional [name], but we force it to boolean
    /// so users can't pin a worktree name as a persistent default (which breaks sessions).
    static let valueTypeOverrides: [String: ClaudeFlag.ValueType] = [
        "--worktree": .boolean,
        "--tmux": .boolean,
    ]

    /// Posted on the main thread when flags finish loading.
    static let didLoadNotification = Notification.Name("ClaudeCLIFlagsDidLoad")

    /// Run `claude --help` asynchronously and parse the output.
    func load() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let output = Self.runClaudeHelp() else { return }
            let parsed = Self.parse(helpOutput: output)
            DispatchQueue.main.async {
                self?.flags = parsed
                NotificationCenter.default.post(name: Self.didLoadNotification, object: nil)
            }
        }
    }

    /// Parse `claude --help` output into structured flags.
    static func parse(helpOutput: String) -> [ClaudeFlag] {
        CLIHelpParser.parse(
            helpOutput: helpOutput,
            blocklist: blocklist,
            valueTypeOverrides: valueTypeOverrides
        )
    }

    private static func runClaudeHelp() -> String? {
        // Use a login shell so the user's full PATH is available.
        // macOS apps launched from Finder get a minimal PATH that won't include
        // homebrew, npm global, or other common install locations.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "claude --help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

/// Parses and caches CLI flags from `codex --help`.
final class CodexCLIFlags {

    static let shared = CodexCLIFlags()
    private init() {}

    /// Parsed flags. Empty until `load()` completes (or if codex is not installed).
    private(set) var flags: [ClaudeFlag] = []

    /// Flags Deckard manages internally — excluded from suggestions.
    static let blocklist: Set<String> = [
        "--help", "--version",
        // Deckard launches Codex in the project directory already; suggesting
        // --cd as a persistent default would make tabs ignore their project root.
        "--cd",
    ]

    /// Posted on the main thread when flags finish loading.
    static let didLoadNotification = Notification.Name("CodexCLIFlagsDidLoad")

    /// Run `codex --help` asynchronously and parse the output.
    func load() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let output = Self.runCodexHelp() else { return }
            let parsed = Self.parse(helpOutput: output)
            DispatchQueue.main.async {
                self?.flags = parsed
                NotificationCenter.default.post(name: Self.didLoadNotification, object: nil)
            }
        }
    }

    /// Parse `codex --help` output into structured flags.
    static func parse(helpOutput: String) -> [ClaudeFlag] {
        CLIHelpParser.parse(helpOutput: helpOutput, blocklist: blocklist)
    }

    private static func runCodexHelp() -> String? {
        // Use a login shell so the user's full PATH is available.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "codex --help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

/// A single chip representing one CLI argument (flag + optional value).
struct ArgsChip: Equatable {
    let flag: String     // e.g. "--permission-mode"
    let value: String?   // e.g. "auto", nil for boolean flags

    /// Join chips into a CLI argument string.
    static func serialize(_ chips: [ArgsChip]) -> String {
        chips.map { chip in
            if let value = chip.value {
                return "\(chip.flag) \(value)"
            }
            return chip.flag
        }.joined(separator: " ")
    }

    /// Parse a CLI argument string into chips, using known flags to determine
    /// which flags take values. Unknown flags are assumed to take a value if
    /// the next token doesn't start with "-".
    static func deserialize(_ string: String, knownFlags: [ClaudeFlag]) -> [ArgsChip] {
        let tokens = string.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return [] }

        let flagMap = Dictionary(uniqueKeysWithValues: knownFlags.map { ($0.longName, $0) })
        var chips: [ArgsChip] = []
        var i = 0

        while i < tokens.count {
            let token = tokens[i]
            guard token.hasPrefix("-") else {
                i += 1
                continue
            }

            if let known = flagMap[token] {
                switch known.valueType {
                case .boolean:
                    chips.append(ArgsChip(flag: token, value: nil))
                    i += 1
                case .freeText, .enumeration:
                    let value = (i + 1 < tokens.count && !tokens[i + 1].hasPrefix("-"))
                        ? tokens[i + 1] : nil
                    chips.append(ArgsChip(flag: token, value: value))
                    i += (value != nil ? 2 : 1)
                }
            } else {
                let value = (i + 1 < tokens.count && !tokens[i + 1].hasPrefix("-"))
                    ? tokens[i + 1] : nil
                chips.append(ArgsChip(flag: token, value: value))
                i += (value != nil ? 2 : 1)
            }
        }

        return chips
    }
}
