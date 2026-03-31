import Foundation

/// Represents a single CLI flag parsed from `claude --help`.
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

    /// Run `claude --help` asynchronously and parse the output.
    func load() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let output = Self.runClaudeHelp() else { return }
            let parsed = Self.parse(helpOutput: output)
            DispatchQueue.main.async {
                self?.flags = parsed
            }
        }
    }

    /// Parse `claude --help` output into structured flags.
    static func parse(helpOutput: String) -> [ClaudeFlag] {
        // Matches lines like:
        //   --flag <value>   Description
        //   -s, --flag <value>   Description
        //   --aliasA, --aliasB <value>   Description
        // Groups: (1) short flag, (2) last long flag, (3) value placeholder, (4) description
        let pattern = #"^\s+(?:(-\w),\s+)?(?:--[\w-]+,\s+)*(--[\w-]+)(?:\s+[\[<]([^\]>]+)[\]>](?:\.{3})?)?\s{2,}(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else {
            return []
        }

        var results: [ClaudeFlag] = []
        let nsString = helpOutput as NSString

        regex.enumerateMatches(in: helpOutput, range: NSRange(location: 0, length: nsString.length)) { match, _, _ in
            guard let match else { return }

            let shortName = match.range(at: 1).location != NSNotFound
                ? nsString.substring(with: match.range(at: 1)) : nil
            let longName = nsString.substring(with: match.range(at: 2))
            let placeholder = match.range(at: 3).location != NSNotFound
                ? nsString.substring(with: match.range(at: 3)) : nil
            let desc = nsString.substring(with: match.range(at: 4))
                .replacingOccurrences(of: "  +", with: " ", options: .regularExpression) // Collapse multi-space runs from column alignment

            // Skip blocklisted flags
            if blocklist.contains(longName) { return }

            let valueType = Self.determineValueType(placeholder: placeholder, description: desc)

            results.append(ClaudeFlag(
                longName: longName,
                shortName: shortName,
                description: desc,
                valueType: valueType,
                valuePlaceholder: placeholder.map { "<\($0)>" }
            ))
        }

        return results
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

    private static func runClaudeHelp() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "--help"]
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
