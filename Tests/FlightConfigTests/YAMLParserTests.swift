import Testing
@testable import FlightConfig

/// Parses with substitution disabled and returns the flat key → value map —
/// the parser suite cares about structure, not substitution (covered in
/// SubstitutionTests).
private func flatten(_ yaml: String) throws -> [String: String] {
    let source = try YAMLConfigSource(string: yaml, name: "test.yaml", substitution: .none)
    var result: [String: String] = [:]
    for key in source.keys {
        result[key] = source.rawValue(for: key)
    }
    return result
}

private func parseError(_ yaml: String) -> ConfigLoadError? {
    do {
        _ = try YAMLConfigSource(string: yaml, name: "test.yaml", substitution: .none)
        return nil
    } catch let error as ConfigLoadError {
        return error
    } catch {
        return nil
    }
}

@Suite("FlightYAML — supported grammar")
struct YAMLGrammarTests {

    @Test("the design doc's base-file example flattens as specified")
    func designDocExample() throws {
        let flat = try flatten("""
        # flight.yaml (base)
        datasource:
          url: "postgres://localhost:5432/flight_dev"
          pool_size: 5
        server:
          port: 8080
        """)
        #expect(flat == [
            "datasource.url": "postgres://localhost:5432/flight_dev",
            "datasource.pool_size": "5",
            "server.port": "8080",
        ])
    }

    @Test("scalars stay raw strings — typing is Configuration.get's job")
    func scalarsStayStrings() throws {
        let flat = try flatten("""
        a: 5
        b: true
        c: 1.25
        """)
        #expect(flat == ["a": "5", "b": "true", "c": "1.25"])
    }

    @Test("deep nesting joins with dots")
    func deepNesting() throws {
        let flat = try flatten("""
        a:
          b:
            c:
              d: deep
        """)
        #expect(flat == ["a.b.c.d": "deep"])
    }

    @Test("siblings after a nested block return to the outer level")
    func dedent() throws {
        let flat = try flatten("""
        outer:
          inner: 1
        next: 2
        """)
        #expect(flat == ["outer.inner": "1", "next": "2"])
    }

    @Test("plain scalars keep URLs and colon-adjacent text intact")
    func colonsInValues() throws {
        let flat = try flatten("""
        url: postgres://localhost:5432/db
        time: 12:30
        """)
        #expect(flat == ["url": "postgres://localhost:5432/db", "time": "12:30"])
    }

    @Test("comments: full-line, trailing, and #-in-value distinctions")
    func comments() throws {
        let flat = try flatten("""
        # full-line comment
        key: value # trailing comment
        anchor_url: http://example.com/page#fragment
        commented_null: # nothing here
        """)
        #expect(flat == [
            "key": "value",
            // '#' not preceded by whitespace is not a comment (YAML rule).
            "anchor_url": "http://example.com/page#fragment",
        ])
    }

    @Test("single-quoted scalars: literal text, '' escapes a quote")
    func singleQuoted() throws {
        let flat = try flatten("""
        a: 'plain'
        b: 'it''s quoted'
        c: 'has # no comment'
        d: 'trailing' # real comment
        """)
        #expect(flat == [
            "a": "plain",
            "b": "it's quoted",
            "c": "has # no comment",
            "d": "trailing",
        ])
    }

    @Test("double-quoted scalars: escape processing")
    func doubleQuoted() throws {
        let flat = try flatten(#"""
        a: "line\nbreak"
        b: "tab\there"
        c: "quote\"inside"
        d: "back\\slash"
        e: "café"
        f: "kept # inside"
        """#)
        #expect(flat == [
            "a": "line\nbreak",
            "b": "tab\there",
            "c": "quote\"inside",
            "d": "back\\slash",
            "e": "café",
            "f": "kept # inside",
        ])
    }

    @Test("empty and null values mean 'absent from this layer'")
    func nulls() throws {
        let flat = try flatten("""
        explicit_null: null
        tilde: ~
        upper: NULL
        empty:
        present_empty: ""
        present_word: "null"
        """)
        #expect(flat == [
            "present_empty": "",
            "present_word": "null",
        ])
    }

    @Test("quoted keys")
    func quotedKeys() throws {
        let flat = try flatten("""
        "quoted key": 1
        'single': 2
        """)
        #expect(flat == ["quoted key": "1", "single": "2"])
    }

    @Test("block sequences flatten by index")
    func sequences() throws {
        let flat = try flatten("""
        hosts:
          - alpha
          - beta
          - gamma
        """)
        #expect(flat == ["hosts.0": "alpha", "hosts.1": "beta", "hosts.2": "gamma"])
    }

    @Test("sequences of mappings — inline first key and continuation keys")
    func sequenceOfMappings() throws {
        let flat = try flatten("""
        servers:
          - host: alpha
            port: 8001
          - host: beta
            port: 8002
        """)
        #expect(flat == [
            "servers.0.host": "alpha",
            "servers.0.port": "8001",
            "servers.1.host": "beta",
            "servers.1.port": "8002",
        ])
    }

    @Test("sequence item as a bare dash with a nested block")
    func bareDashItems() throws {
        let flat = try flatten("""
        jobs:
          -
            name: cleanup
          -
            name: reindex
        """)
        #expect(flat == ["jobs.0.name": "cleanup", "jobs.1.name": "reindex"])
    }

    @Test("null sequence items are omitted but keep later indices")
    func nullSequenceItems() throws {
        let flat = try flatten("""
        items:
          - ~
          - real
        """)
        #expect(flat == ["items.1": "real"])
    }

    @Test("document markers: leading --- and trailing ... are tolerated")
    func documentMarkers() throws {
        let flat = try flatten("""
        ---
        key: value
        ...
        """)
        #expect(flat == ["key": "value"])
    }

    @Test("empty documents are valid, empty layers")
    func emptyDocuments() throws {
        #expect(try flatten("") == [:])
        #expect(try flatten("\n\n\n") == [:])
        #expect(try flatten("# only comments\n# nothing else\n") == [:])
    }

    @Test("CRLF line endings parse identically")
    func crlf() throws {
        let flat = try flatten("a: 1\r\nb:\r\n  c: 2\r\n")
        #expect(flat == ["a": "1", "b.c": "2"])
    }

    @Test("unicode keys and values survive")
    func unicode() throws {
        let flat = try flatten("""
        grüße: dünya
        emoji: ✈️
        """)
        #expect(flat == ["grüße": "dünya", "emoji": "✈️"])
    }

    @Test("values containing dollar text pass through with substitution disabled")
    func dollarsPreservedWithoutSubstitution() throws {
        let flat = try flatten("""
        url: ${FLIGHT_DATASOURCE_URL}
        """)
        #expect(flat == ["url": "${FLIGHT_DATASOURCE_URL}"])
    }

    @Test("keys containing literal dots merge into the same namespace")
    func literalDottedKeys() throws {
        let flat = try flatten("""
        datasource.url: direct
        """)
        #expect(flat == ["datasource.url": "direct"])
    }
}

@Suite("FlightYAML — rejected constructs fail loudly")
struct YAMLRejectionTests {

    private func expectParseError(_ yaml: String, containing fragment: String,
                                  sourceLocation: SourceLocation = #_sourceLocation) {
        guard let error = parseError(yaml) else {
            Issue.record("expected a ConfigLoadError for:\n\(yaml)", sourceLocation: sourceLocation)
            return
        }
        #expect("\(error)".contains(fragment),
                "error was: \(error)", sourceLocation: sourceLocation)
    }

    @Test("tabs in indentation")
    func tabs() {
        expectParseError("a:\n\tb: 1", containing: "tab")
    }

    @Test("flow style — sequences and mappings")
    func flowStyle() {
        expectParseError("a: [1, 2]", containing: "flow style")
        expectParseError("a: {b: 1}", containing: "flow style")
    }

    @Test("block scalars")
    func blockScalars() {
        expectParseError("a: |\n  text", containing: "block scalars")
        expectParseError("a: >\n  text", containing: "block scalars")
    }

    @Test("anchors, aliases, tags, merge keys")
    func anchorsAliasesTags() {
        expectParseError("a: &anchor 1", containing: "anchors")
        expectParseError("a: *anchor", containing: "aliases")
        expectParseError("a: !!int 5", containing: "tags")
        expectParseError("<<: *base", containing: "merge keys")
    }

    @Test("multiple documents")
    func multipleDocuments() {
        expectParseError("a: 1\n---\nb: 2", containing: "multiple YAML documents")
    }

    @Test("directives")
    func directives() {
        expectParseError("%YAML 1.2\n---\na: 1", containing: "directives")
    }

    @Test("content after the document-end marker")
    func contentAfterEnd() {
        expectParseError("a: 1\n...\nb: 2", containing: "document-end")
    }

    @Test("duplicate keys in one mapping")
    func duplicateKeys() {
        expectParseError("a: 1\na: 2", containing: "duplicate key 'a'")
    }

    @Test("nested duplicates are scoped to their own mapping (this is legal)")
    func scopedDuplicates() throws {
        let flat = try flatten("""
        a:
          port: 1
        b:
          port: 2
        """)
        #expect(flat == ["a.port": "1", "b.port": "2"])
    }

    @Test("dotted-key collision with nested mapping")
    func flattenCollision() {
        expectParseError("a.b: 1\na:\n  b: 2", containing: "collides")
    }

    @Test("multi-line plain scalars (continuation lines)")
    func multilinePlain() {
        expectParseError("a: first\n  second", containing: "unexpected indentation")
    }

    @Test("bare scalar where a key is expected")
    func bareScalar() {
        expectParseError("just a scalar", containing: "expected 'key: value'")
    }

    @Test("top-level sequence")
    func topLevelSequence() {
        expectParseError("- a\n- b", containing: "top level")
    }

    @Test("mixing sequence entries and keys at one indentation")
    func mixedBlock() {
        expectParseError("a: 1\n- b", containing: "cannot mix")
        expectParseError("list:\n  - a\n  b: 1", containing: "cannot mix")
    }

    @Test("unterminated quotes")
    func unterminatedQuotes() {
        expectParseError("a: \"never closed", containing: "unterminated")
        expectParseError("a: 'never closed", containing: "unterminated")
    }

    @Test("bad escape sequences")
    func badEscapes() {
        expectParseError(#"a: "\q""#, containing: "unsupported escape")
        expectParseError(#"a: "\u12""#, containing: "four hex digits")
        expectParseError(#"a: "\uD800""#, containing: "not a valid Unicode scalar")
    }

    @Test("trailing garbage after a quoted scalar")
    func trailingGarbage() {
        expectParseError("a: \"closed\" extra", containing: "after quoted scalar")
    }

    @Test("nested inline sequences")
    func nestedInlineSequences() {
        expectParseError("a:\n  - - x", containing: "nested inline sequences")
    }

    @Test("empty keys")
    func emptyKeys() {
        expectParseError(": value", containing: "empty key")
    }

    @Test("parse errors carry the file name and line number")
    func errorLocations() {
        guard case .parseFailed(let file, let line, _, _)? = parseError("a: 1\nb: [flow]\n") else {
            Issue.record("expected parseFailed")
            return
        }
        #expect(file == "test.yaml")
        #expect(line == 2)
    }
}
