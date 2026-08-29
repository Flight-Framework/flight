import Testing
@testable import FlightConfig

@Suite("${VAR} substitution")
struct SubstitutionTests {

    private func resolve(_ yaml: String, env: [String: String]) throws -> YAMLConfigSource {
        try YAMLConfigSource(string: yaml, name: "sub.yaml", substitution: .resolve(env))
    }

    @Test("the design doc's flight-prod.yaml example resolves via the env")
    func designDocExample() throws {
        let source = try resolve("""
        datasource:
          url: "${FLIGHT_DATASOURCE_URL}"
          pool_size: 50
        """, env: ["FLIGHT_DATASOURCE_URL": "postgres://prod-db:5432/flight"])
        #expect(source.rawValue(for: "datasource.url") == "postgres://prod-db:5432/flight")
        #expect(source.rawValue(for: "datasource.pool_size") == "50")
    }

    @Test("substitution composes inside larger values, repeatedly")
    func composition() throws {
        let source = try resolve(
            "url: postgres://${DB_HOST}:${DB_PORT}/app",
            env: ["DB_HOST": "db.internal", "DB_PORT": "5432"]
        )
        #expect(source.rawValue(for: "url") == "postgres://db.internal:5432/app")
    }

    @Test("unset variable without a default fails the load, naming everything")
    func unsetFails() {
        do {
            _ = try resolve("datasource:\n  url: ${MISSING_VAR}", env: [:])
            Issue.record("expected unresolvedSubstitution")
        } catch let error as ConfigLoadError {
            guard case .unresolvedSubstitution(let file, let line, let key, let variable) = error
            else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(file == "sub.yaml")
            // The line was in hand and dropped, making this the one load
            // failure that did not name one.
            #expect(line == 2)
            #expect(key == "datasource.url")
            #expect(variable == "MISSING_VAR")
            #expect(error.description.contains("sub.yaml:2"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test(":- default applies when unset or empty, bash-style")
    func defaults() throws {
        let unset = try resolve("a: ${X:-fallback}", env: [:])
        #expect(unset.rawValue(for: "a") == "fallback")

        let empty = try resolve("a: ${X:-fallback}", env: ["X": ""])
        #expect(empty.rawValue(for: "a") == "fallback")

        let set = try resolve("a: ${X:-fallback}", env: ["X": "real"])
        #expect(set.rawValue(for: "a") == "real")

        let emptyDefault = try resolve("a: ${X:-}", env: [:])
        #expect(emptyDefault.rawValue(for: "a") == "")
    }

    @Test("set-but-empty resolves to empty for plain ${VAR}")
    func emptyIsSet() throws {
        let source = try resolve("a: pre${X}post", env: ["X": ""])
        #expect(source.rawValue(for: "a") == "prepost")
    }

    @Test("$$ escapes to a literal dollar; lone $ needs no escape")
    func dollarEscapes() throws {
        let source = try resolve("""
        escaped: "$${NOT_A_VAR}"
        price: "$5 or 5$"
        """, env: [:])
        #expect(source.rawValue(for: "escaped") == "${NOT_A_VAR}")
        #expect(source.rawValue(for: "price") == "$5 or 5$")
    }

    @Test("substitution applies to quoted and plain scalars alike")
    func quotingIrrelevant() throws {
        let source = try resolve("""
        plain: ${V}
        single: '${V}'
        double: "${V}"
        """, env: ["V": "x"])
        #expect(source.rawValue(for: "plain") == "x")
        #expect(source.rawValue(for: "single") == "x")
        #expect(source.rawValue(for: "double") == "x")
    }

    @Test("malformed substitutions are load errors with the value's line")
    func malformed() {
        func expectSyntaxError(_ yaml: String, line expectedLine: Int,
                               sourceLocation: SourceLocation = #_sourceLocation) {
            do {
                _ = try YAMLConfigSource(string: yaml, name: "sub.yaml", substitution: .resolve([:]))
                Issue.record("expected parseFailed for \(yaml)", sourceLocation: sourceLocation)
            } catch let error as ConfigLoadError {
                guard case .parseFailed(_, let line, _, _) = error else {
                    Issue.record("wrong case: \(error)", sourceLocation: sourceLocation)
                    return
                }
                #expect(line == expectedLine, sourceLocation: sourceLocation)
            } catch {
                Issue.record("unexpected: \(error)", sourceLocation: sourceLocation)
            }
        }
        expectSyntaxError("a: ok\nb: ${UNTERMINATED", line: 2)
        expectSyntaxError("a: ${}", line: 1)
        expectSyntaxError("a: ${1BAD}", line: 1)
        expectSyntaxError("a: ${V:default}", line: 1)  // ':' without '-' — not the supported form
    }

    @Test("substitution never touches keys")
    func keysUntouched() throws {
        let source = try resolve("${KEY}: value", env: ["KEY": "boom"])
        #expect(source.rawValue(for: "${KEY}") == "value")
        #expect(source.rawValue(for: "boom") == nil)
    }

    @Test(".none policy preserves placeholders and never fails on them")
    func nonePolicy() throws {
        let source = try YAMLConfigSource(
            string: "a: ${DEFINITELY_UNSET_VAR}",
            name: "tooling.yaml",
            substitution: .none
        )
        #expect(source.rawValue(for: "a") == "${DEFINITELY_UNSET_VAR}")
    }
}
