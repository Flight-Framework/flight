/// The Flight YAML subset parser.
///
/// Flight Config deliberately parses a *subset* of YAML rather than depending
/// on a full YAML implementation: the package is a leaf (depends on nothing,
/// by design), and config files need exactly the shapes the design doc's
/// examples use — nested block mappings, block sequences, scalars, comments,
/// and quoting. Everything outside the subset fails **loudly at parse time**
/// with a message naming the construct and the alternative, in line with the
/// project-wide fail-fast rule: a silently misread config file is the
/// worst outcome a config library can produce.
///
/// ## Supported
/// - Block mappings (`key: value`), nested by indentation (spaces only)
/// - Block sequences (`- item`), including sequences of mappings
/// - Plain scalars (kept verbatim as strings — typing happens in
///   `Configuration.get`, not here)
/// - Single-quoted scalars (`''` escapes a quote) and double-quoted scalars
///   (`\\`, `\"`, `\n`, `\t`, `\r`, `\0`, `\uXXXX` escapes)
/// - Comments (`#` at line start, or preceded by whitespace)
/// - Quoted keys, `key:` with no value (null), `~`/`null` explicit nulls
/// - An optional leading `---` document-start marker and trailing `...`
///
/// ## Deliberately rejected (clear parse error, never a guess)
/// - Flow style (`[a, b]`, `{a: b}`) — use block form
/// - Block scalars (`|`, `>`) — long values belong in env vars or quoting
/// - Anchors/aliases/tags/merge keys (`&`, `*`, `!`, `<<:`)
/// - Multiple documents, directives (`%YAML`), tab indentation,
///   multi-line plain scalars
///
/// ## Flattening
/// The tree flattens to dot-separated keys, which is the currency of
/// `ConfigSource`: `datasource: {url: x}` → `datasource.url`. Sequences
/// flatten by index: `hosts: [a, b]` (block form) → `hosts.0`, `hosts.1`.
/// Null-valued keys are omitted — an empty `key:` means "this layer says
/// nothing about `key`", letting lower-precedence layers show through
/// (an explicitly-quoted `""` is a present, empty value instead).
enum FlightYAML {

    // MARK: - Model

    indirect enum Node {
        case mapping([MappingEntry])
        case sequence([SequenceItem])
        /// nil = explicit or implicit null.
        case scalar(String?, line: Int)
    }

    struct MappingEntry {
        let key: String
        let line: Int
        let value: Node
    }

    struct SequenceItem {
        let line: Int
        let value: Node
    }

    struct FlatEntry {
        let key: String
        let value: String
        let line: Int
    }

    struct ParseError: Error {
        let line: Int
        let column: Int
        let message: String
    }

    // MARK: - Line model

    private struct Line {
        let indent: Int
        /// Content with indentation removed and trailing whitespace trimmed;
        /// never empty, never a pure comment.
        let content: String
        let number: Int
    }

    // MARK: - Entry points

    /// Parses a document into a tree. Returns nil for an empty document
    /// (no content lines) — an empty config file is a valid, empty layer.
    /// The root must be a mapping: top-level sequences and bare scalars have
    /// no meaning as configuration.
    static func parse(_ text: String) throws -> Node? {
        let lines = try makeLines(text)
        guard !lines.isEmpty else { return nil }

        var parser = Parser(lines: lines)
        let root = try parser.parseBlock(indent: lines[0].indent)
        if let stray = parser.peek() {
            throw ParseError(
                line: stray.number,
                column: stray.indent + 1,
                message: "unexpected content at indentation \(stray.indent) — the document's top level starts at indentation \(lines[0].indent)"
            )
        }
        guard case .mapping = root else {
            throw ParseError(
                line: lines[0].number,
                column: lines[0].indent + 1,
                message: "the top level of a Flight config file must be a mapping of keys, not a sequence or scalar"
            )
        }
        return root
    }

    /// Flattens a parsed tree into dot-path entries, preserving source lines
    /// for downstream diagnostics (substitution errors point at the line).
    /// Detects path collisions — a literal dotted key (`a.b: 1`) colliding
    /// with a nested one (`a: {b: 2}`) is a configuration ambiguity, not a
    /// last-writer-wins race.
    static func flatten(_ root: Node) throws -> [FlatEntry] {
        var entries: [FlatEntry] = []
        var seen: [String: Int] = [:]  // flattened key → first line

        func walk(_ node: Node, path: String) throws {
            switch node {
            case .scalar(let value, let line):
                guard let value else { return }  // nulls are omitted
                if let firstLine = seen[path] {
                    throw ParseError(
                        line: line,
                        column: 1,
                        message: "key '\(path)' collides with the key already defined at line \(firstLine) (a dotted key and a nested mapping flatten to the same path)"
                    )
                }
                seen[path] = line
                entries.append(FlatEntry(key: path, value: value, line: line))
            case .mapping(let members):
                for member in members {
                    let childPath = path.isEmpty ? member.key : "\(path).\(member.key)"
                    try walk(member.value, path: childPath)
                }
            case .sequence(let items):
                for (index, item) in items.enumerated() {
                    try walk(item.value, path: path.isEmpty ? "\(index)" : "\(path).\(index)")
                }
            }
        }

        try walk(root, path: "")
        return entries
    }

    // MARK: - Line splitting

    private static func makeLines(_ text: String) throws -> [Line] {
        var result: [Line] = []
        var number = 0
        var pastDocumentEnd = false

        // A UTF-8 BOM is invisible but would otherwise become part of the
        // first key, so `server.port` would parse as "\u{FEFF}server.port"
        // and every lookup for it would report the key missing — from a file
        // that visibly contains it. Windows editors write this by default.
        var text = text
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }

        // "\r\n" is a single Character (grapheme cluster) in Swift, so a
        // split on the newline *Character* alone would never break CRLF
        // files. Match all three line-ending styles as separators.
        let lineBreaks: Set<Character> = ["\n", "\r\n", "\r"]
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { lineBreaks.contains($0) }) {
            number += 1
            let lineText = String(rawLine)

            var indent = 0
            var index = lineText.startIndex
            while index < lineText.endIndex, lineText[index] == " " {
                indent += 1
                index = lineText.index(after: index)
            }
            if index < lineText.endIndex, lineText[index] == "\t" {
                throw ParseError(
                    line: number,
                    column: indent + 1,
                    message: "tab character in indentation — YAML indentation must use spaces"
                )
            }

            let content = String(lineText[index...]).trimmingTrailingWhitespace()
            if content.isEmpty || content.hasPrefix("#") { continue }

            if pastDocumentEnd {
                throw ParseError(
                    line: number, column: indent + 1,
                    message: "content after the '...' document-end marker"
                )
            }
            if content.hasPrefix("%") {
                throw ParseError(
                    line: number, column: indent + 1,
                    message: "YAML directives ('%…') are not supported by the Flight YAML subset"
                )
            }
            if content == "..." {
                pastDocumentEnd = true
                continue
            }
            if content == "---" || content.hasPrefix("--- ") {
                if result.isEmpty {
                    // Optional document-start marker; inline content after it
                    // would be a second way to write the same thing — reject.
                    if content != "---" {
                        throw ParseError(
                            line: number, column: indent + 5,
                            message: "content on the '---' document-start line is not supported — start the mapping on the next line"
                        )
                    }
                    continue
                }
                throw ParseError(
                    line: number, column: indent + 1,
                    message: "multiple YAML documents in one file are not supported — one flight config file is one document"
                )
            }

            result.append(Line(indent: indent, content: content, number: number))
        }
        return result
    }

    // MARK: - Parser

    private struct Parser {
        let lines: [Line]
        var index = 0

        func peek() -> Line? {
            index < lines.count ? lines[index] : nil
        }

        mutating func advance() {
            index += 1
        }

        // A block is the run of lines at one exact indentation level; the
        // first line decides whether it is a mapping or a sequence.
        mutating func parseBlock(indent: Int) throws -> Node {
            guard let first = peek() else {
                // Callers only enter a block after peeking a line; kept as a
                // guard rather than a trap for parser-internal robustness.
                throw ParseError(line: 0, column: 0, message: "internal: parseBlock past end of input")
            }
            if isSequenceEntry(first.content) {
                return try parseSequence(indent: indent)
            }
            return try parseMapping(indent: indent, firstInline: nil)
        }

        // MARK: Mappings

        /// Parses a mapping whose entries sit at exactly `indent`.
        ///
        /// `firstInline` carries the already-consumed first entry for the
        /// inline sequence-item form (`- key: value`), where the entry text
        /// lives on the `-` line and continuation keys align under it.
        mutating func parseMapping(
            indent: Int,
            firstInline: (content: String, line: Line)?
        ) throws -> Node {
            var entries: [MappingEntry] = []
            var seenKeys: [String: Int] = [:]

            if let firstInline {
                entries.append(try parseMappingEntry(
                    content: firstInline.content,
                    line: firstInline.line,
                    indent: indent,
                    seenKeys: &seenKeys
                ))
            }

            while let line = peek() {
                if line.indent < indent { break }
                if line.indent > indent {
                    throw ParseError(
                        line: line.number,
                        column: line.indent + 1,
                        message: "unexpected indentation — expected a key at indentation \(indent) (multi-line plain scalars are not supported by the Flight YAML subset; quote long values)"
                    )
                }
                if isSequenceEntry(line.content) {
                    throw ParseError(
                        line: line.number,
                        column: line.indent + 1,
                        message: "cannot mix '-' sequence entries and 'key:' entries at the same indentation"
                    )
                }
                advance()
                entries.append(try parseMappingEntry(
                    content: line.content,
                    line: line,
                    indent: indent,
                    seenKeys: &seenKeys
                ))
            }
            return .mapping(entries)
        }

        private mutating func parseMappingEntry(
            content: String,
            line: Line,
            indent: Int,
            seenKeys: inout [String: Int]
        ) throws -> MappingEntry {
            let (key, rest) = try splitKey(content: content, line: line)

            if key == "<<" {
                throw ParseError(
                    line: line.number, column: indent + 1,
                    message: "merge keys ('<<:') are not supported by the Flight YAML subset — repeat the keys explicitly"
                )
            }
            if let firstLine = seenKeys[key] {
                throw ParseError(
                    line: line.number, column: indent + 1,
                    message: "duplicate key '\(key)' — already defined at line \(firstLine)"
                )
            }
            seenKeys[key] = line.number

            let value = try parseValueOrChildBlock(rest: rest, line: line, parentIndent: indent)
            return MappingEntry(key: key, line: line.number, value: value)
        }

        /// A mapping entry's right-hand side: an inline scalar, or a child
        /// block on the following (deeper-indented) lines, or null.
        private mutating func parseValueOrChildBlock(
            rest: String,
            line: Line,
            parentIndent: Int
        ) throws -> Node {
            if !rest.isEmpty {
                return try parseScalar(text: rest, line: line)
            }
            if let next = peek(), next.indent > parentIndent {
                return try parseBlock(indent: next.indent)
            }
            return .scalar(nil, line: line.number)
        }

        // MARK: Sequences

        private mutating func parseSequence(indent: Int) throws -> Node {
            var items: [SequenceItem] = []
            while let line = peek() {
                if line.indent < indent { break }
                if line.indent > indent {
                    throw ParseError(
                        line: line.number,
                        column: line.indent + 1,
                        message: "unexpected indentation — expected a '-' sequence entry at indentation \(indent)"
                    )
                }
                guard isSequenceEntry(line.content) else {
                    throw ParseError(
                        line: line.number,
                        column: line.indent + 1,
                        message: "cannot mix 'key:' entries and '-' sequence entries at the same indentation"
                    )
                }
                advance()
                items.append(try parseSequenceItem(line: line, indent: indent))
            }
            return .sequence(items)
        }

        private mutating func parseSequenceItem(line: Line, indent: Int) throws -> SequenceItem {
            // "-" alone: the item is the block on the following deeper lines.
            if line.content == "-" {
                if let next = peek(), next.indent > indent {
                    return SequenceItem(line: line.number, value: try parseBlock(indent: next.indent))
                }
                return SequenceItem(line: line.number, value: .scalar(nil, line: line.number))
            }

            // "- rest": rest is a scalar, or the first entry of an inline
            // mapping whose continuation keys align under rest's column.
            let afterDash = line.content.dropFirst(1)  // keep spaces for column math
            let extraSpaces = afterDash.prefix(while: { $0 == " " }).count
            let rest = String(afterDash.dropFirst(extraSpaces))
            let restIndent = line.indent + 1 + extraSpaces

            if rest.hasPrefix("#") {
                // "- " followed by a comment is a null item.
                return SequenceItem(line: line.number, value: .scalar(nil, line: line.number))
            }
            if rest == "-" || rest.hasPrefix("- ") {
                throw ParseError(
                    line: line.number,
                    column: restIndent + 1,
                    message: "nested inline sequences ('- - x') are not supported — put the inner sequence on its own indented lines under a bare '-'"
                )
            }
            if looksLikeMappingEntry(rest) {
                let value = try parseMapping(
                    indent: restIndent,
                    firstInline: (content: rest, line: line)
                )
                return SequenceItem(line: line.number, value: value)
            }
            return SequenceItem(line: line.number, value: try parseScalar(text: rest, line: line))
        }

        private func isSequenceEntry(_ content: String) -> Bool {
            content == "-" || content.hasPrefix("- ")
        }

        // MARK: Keys

        /// Splits "key: rest" (or "key:"). Returns the processed key and the
        /// raw remainder with leading whitespace stripped; a remainder that is
        /// only a comment comes back empty.
        private func splitKey(content: String, line: Line) throws -> (key: String, rest: String) {
            let key: String
            var remainder: Substring

            if content.hasPrefix("\"") || content.hasPrefix("'") {
                let (parsed, after) = try parseQuoted(Substring(content), line: line)
                key = parsed
                remainder = after.drop(while: { $0 == " " })
                guard remainder.hasPrefix(":") else {
                    throw ParseError(
                        line: line.number, column: line.indent + 1,
                        message: "expected ':' after quoted key"
                    )
                }
                remainder = remainder.dropFirst()
                guard remainder.isEmpty || remainder.hasPrefix(" ") else {
                    throw ParseError(
                        line: line.number, column: line.indent + 1,
                        message: "expected a space between ':' and the value"
                    )
                }
            } else {
                guard let colon = keyColonIndex(in: content) else {
                    throw ParseError(
                        line: line.number,
                        column: line.indent + 1,
                        message: "expected 'key: value', 'key:', or '- item' — found a bare scalar (multi-line plain scalars are not supported by the Flight YAML subset)"
                    )
                }
                let rawKey = String(content[..<colon]).trimmingTrailingWhitespace()
                if rawKey.isEmpty {
                    throw ParseError(
                        line: line.number, column: line.indent + 1,
                        message: "empty key before ':'"
                    )
                }
                if let bad = unsupportedLeadingMarker(rawKey) {
                    throw ParseError(
                        line: line.number, column: line.indent + 1,
                        message: "\(bad) is not supported by the Flight YAML subset — quote the key if the character is literal"
                    )
                }
                key = rawKey
                remainder = content[content.index(after: colon)...]
            }

            var rest = String(remainder.drop(while: { $0 == " " }))
            // A remainder that is entirely a comment means "no inline value".
            if rest.hasPrefix("#") { rest = "" }
            return (key, rest)
        }

        /// The index of the first ':' that terminates a plain key — a ':'
        /// followed by a space or end-of-line. A ':' hugging its next
        /// character (URLs: `postgres://…`, times: `12:30`) is scalar text.
        private func keyColonIndex(in content: String) -> String.Index? {
            var index = content.startIndex
            while let colon = content[index...].firstIndex(of: ":") {
                let next = content.index(after: colon)
                if next == content.endIndex || content[next] == " " {
                    return colon
                }
                index = next
            }
            return nil
        }

        /// Would this text start a mapping entry (rather than a scalar)?
        /// Mirrors `splitKey`'s two forms: quoted-key-then-colon, or a plain
        /// key with a terminating colon.
        private func looksLikeMappingEntry(_ text: String) -> Bool {
            if text.hasPrefix("\"") || text.hasPrefix("'") {
                guard let (_, after) = try? parseQuoted(Substring(text), line: Line(indent: 0, content: text, number: 0)) else {
                    return false
                }
                let trimmed = after.drop(while: { $0 == " " })
                return trimmed.hasPrefix(":")
                    && (trimmed.dropFirst().isEmpty || trimmed.dropFirst().hasPrefix(" "))
            }
            return keyColonIndex(in: text) != nil
        }

        // MARK: Scalars

        private func parseScalar(text: String, line: Line) throws -> Node {
            if text.hasPrefix("\"") || text.hasPrefix("'") {
                let (value, after) = try parseQuoted(Substring(text), line: line)
                let trailing = after.drop(while: { $0 == " " })
                if !trailing.isEmpty && !trailing.hasPrefix("#") {
                    throw ParseError(
                        line: line.number, column: line.indent + 1,
                        message: "unexpected content after quoted scalar: '\(trailing)'"
                    )
                }
                // Quoted scalars are never null — "" is a present, empty value.
                return .scalar(value, line: line.number)
            }

            if let bad = unsupportedLeadingMarker(text) {
                throw ParseError(
                    line: line.number, column: line.indent + 1,
                    message: "\(bad) is not supported by the Flight YAML subset — quote the value if the character is literal"
                )
            }

            let plain = stripTrailingComment(from: text).trimmingTrailingWhitespace()
            switch plain {
            case "", "~", "null", "Null", "NULL":
                return .scalar(nil, line: line.number)
            default:
                return .scalar(plain, line: line.number)
            }
        }

        /// Names the unsupported YAML feature a leading marker implies, or
        /// nil if the text is a plain scalar. Rejecting these outright is the
        /// subset's core promise: never *misread* real YAML that means
        /// something this parser doesn't implement.
        private func unsupportedLeadingMarker(_ text: String) -> String? {
            switch text.first {
            case "[", "{":
                return "flow style ('[…]' / '{…}')"
            case "|", ">":
                return "block scalars ('|' / '>')"
            case "&":
                return "anchors ('&')"
            case "*":
                return "aliases ('*')"
            case "!":
                return "tags ('!')"
            case "@", "`":
                return "the reserved indicator '\(text.first!)'"
            default:
                return nil
            }
        }

        /// Removes a trailing comment from plain-scalar text: '#' preceded by
        /// whitespace starts a comment (YAML's rule — `http://x#frag` has no
        /// comment, `value # note` does).
        private func stripTrailingComment(from text: String) -> String {
            var previous: Character? = nil
            for index in text.indices {
                let character = text[index]
                if character == "#", let prev = previous, prev == " " || prev == "\t" {
                    return String(text[..<index])
                }
                previous = character
            }
            return text
        }

        /// Parses a leading quoted scalar; returns the processed value and
        /// the unconsumed remainder (used for both keys and values).
        private func parseQuoted(_ text: Substring, line: Line) throws -> (value: String, rest: Substring) {
            let quote = text.first!
            var value = ""
            var index = text.index(after: text.startIndex)

            while index < text.endIndex {
                let character = text[index]
                if quote == "'" {
                    if character == "'" {
                        let next = text.index(after: index)
                        if next < text.endIndex, text[next] == "'" {
                            value.append("'")  // '' escape
                            index = text.index(after: next)
                            continue
                        }
                        return (value, text[next...])
                    }
                    value.append(character)
                    index = text.index(after: index)
                } else {
                    if character == "\"" {
                        return (value, text[text.index(after: index)...])
                    }
                    if character == "\\" {
                        let (escaped, after) = try parseEscape(text, at: index, line: line)
                        value.append(escaped)
                        index = after
                        continue
                    }
                    value.append(character)
                    index = text.index(after: index)
                }
            }
            throw ParseError(
                line: line.number, column: line.indent + 1,
                message: "unterminated \(quote == "'" ? "single" : "double")-quoted scalar (multi-line scalars are not supported by the Flight YAML subset)"
            )
        }

        private func parseEscape(
            _ text: Substring,
            at backslash: Substring.Index,
            line: Line
        ) throws -> (Character, Substring.Index) {
            let escapeIndex = text.index(after: backslash)
            guard escapeIndex < text.endIndex else {
                throw ParseError(
                    line: line.number, column: line.indent + 1,
                    message: "dangling '\\' at end of double-quoted scalar"
                )
            }
            let escape = text[escapeIndex]
            let after = text.index(after: escapeIndex)
            switch escape {
            case "\\": return ("\\", after)
            case "\"": return ("\"", after)
            case "n": return ("\n", after)
            case "t": return ("\t", after)
            case "r": return ("\r", after)
            case "0": return ("\0", after)
            case "u":
                var hex = ""
                var cursor = after
                for _ in 0..<4 {
                    guard cursor < text.endIndex, text[cursor].isHexDigit else {
                        throw ParseError(
                            line: line.number, column: line.indent + 1,
                            message: "'\\u' escape requires exactly four hex digits (e.g. \\u00e9)"
                        )
                    }
                    hex.append(text[cursor])
                    cursor = text.index(after: cursor)
                }
                guard let value = UInt32(hex, radix: 16), let unicode = Unicode.Scalar(value) else {
                    throw ParseError(
                        line: line.number, column: line.indent + 1,
                        message: "'\\u\(hex)' is not a valid Unicode scalar"
                    )
                }
                return (Character(unicode), cursor)
            default:
                throw ParseError(
                    line: line.number, column: line.indent + 1,
                    message: "unsupported escape '\\\(escape)' in double-quoted scalar (supported: \\\\ \\\" \\n \\t \\r \\0 \\uXXXX)"
                )
            }
        }
    }
}

extension String {
    func trimmingTrailingWhitespace() -> String {
        var view = Substring(self)
        while let last = view.last, last == " " || last == "\t" {
            view.removeLast()
        }
        return String(view)
    }
}
