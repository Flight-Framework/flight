import Foundation
import Testing

/// The list of attributes the generator scans for, checked against the
/// registering macros the framework actually declares.
///
/// `@Scheduler` shipped in 0.2.0 with a working macro, a working runtime, and
/// no entry in that list — so the generator never scanned `@Scheduler` types
/// and scheduled jobs silently never ran. This is the general guard against
/// that: every macro that expands to a composed component — i.e. one whose
/// declaration attaches a member initializer — must be a name the generator
/// scans for.
///
/// Reading the sources rather than restating the list is the point. A test
/// that hard-coded the expected names would have been written from the same
/// wrong list and passed just as happily.
@Suite("Registrable attributes")
struct RegistrableAttributesTests {

    private static func packageRoot() -> URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Package.swift").path)
        {
            let parent = root.deletingLastPathComponent()
            precondition(parent.path != root.path, "no Package.swift above \(#filePath)")
            root = parent
        }
        return root
    }

    /// Macros whose expansion attaches a member initializer — every macro that
    /// makes a type the generator must scan and build. The peer macros
    /// (`@Inject`, `@ConfigValue`, `@Secret`, the route attributes,
    /// `@Scheduled`) attach no initializer and are not scanned components.
    private func registeringMacros() throws -> Set<String> {
        var found: Set<String> = []
        for file in packageRootSwiftFiles() {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                guard let name = macroName(declaredOn: line) else { continue }
                // The attribute/doc block above the declaration, back to the
                // blank line that separates it from whatever precedes it.
                var block: [String] = []
                var i = index - 1
                while i >= 0, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    block.append(lines[i])
                    i -= 1
                }
                if block.joined(separator: "\n").range(
                    of: #"@attached\(\s*member[\s\S]*?named\(init\)"#,
                    options: .regularExpression) != nil
                {
                    found.insert(name)
                }
            }
        }
        return found
    }

    /// `public macro Component(` → "Component".
    private func macroName(declaredOn line: String) -> String? {
        guard
            let range = line.range(
                of: #"public macro ([A-Z][A-Za-z0-9_]*)"#, options: .regularExpression)
        else { return nil }
        return String(line[range].dropFirst("public macro ".count))
    }

    private func packageRootSwiftFiles() -> [URL] {
        let root = Self.packageRoot().appendingPathComponent("Sources")
        guard
            let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func scannedAttributes() throws -> Set<String> {
        let file = Self.packageRoot()
            .appendingPathComponent("Sources/Core/flight-registration-gen/main.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        guard
            let start = text.range(of: "registrableAttributes: Set<String> = ["),
            let end = text.range(of: "]", range: start.upperBound..<text.endIndex)
        else {
            Issue.record("could not find registrableAttributes")
            return []
        }
        return Set(
            text[start.upperBound..<end.lowerBound]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(["\""])) }
                .filter { !$0.isEmpty })
    }

    @Test("every registering macro is one the generator scans for")
    func everyRegisteringMacroIsScanned() throws {
        let macros = try registeringMacros()
        let scanned = try scannedAttributes()
        #expect(!macros.isEmpty, "found no registering macros — the scan is broken")

        let unscanned = macros.subtracting(scanned).sorted()
        #expect(
            unscanned.isEmpty,
            """
            \(unscanned.joined(separator: ", ")) expand to a composed component but are \
            not scanned, so types using them are silently left out of composition. \
            Add them to registrableAttributes in flight-registration-gen.
            """)
    }

    @Test("the generator scans for @Scheduler")
    func schedulerIsScanned() throws {
        // The specific regression, named, so its absence cannot be argued
        // away as a change in how the general check works.
        #expect(try scannedAttributes().contains("Scheduler"))
    }
}

/// The generator's always-available list, checked against what resolves
/// without registration.
///
/// Same failure shape as the attribute list above, one layer over: the
/// generator warns about any `@Inject` type it cannot see a registration
/// for, and `Configuration` needs none — bootstrap always provides it. A
/// demand for it is correct code, so a warning on it is noise on every build
/// — and a warning that is noise on every build is one nobody reads when it
/// is real.
///
/// Reading the list from source rather than restating it is again the point.
@Suite("Always-available types")
struct AlwaysAvailableTests {

    private static func packageRoot() -> URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Package.swift").path)
        {
            let parent = root.deletingLastPathComponent()
            precondition(parent.path != root.path, "no Package.swift above \(#filePath)")
            root = parent
        }
        return root
    }

    /// The names the generator will not warn about, read out of its source.
    private func alwaysAvailableNames() throws -> Set<String> {
        let source = Self.packageRoot()
            .appendingPathComponent("Sources/Core/flight-registration-gen/main.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        guard let start = text.range(of: "let alwaysAvailable: Set<String> = ["),
            let end = text.range(of: "]", range: start.upperBound..<text.endIndex)
        else {
            Issue.record("could not find alwaysAvailable in \(source.path)")
            return []
        }

        var names: Set<String> = []
        for line in text[start.upperBound..<end.lowerBound].split(separator: "\n") {
            let code = line.split(separator: "//", maxSplits: 1).first ?? ""
            for piece in code.split(separator: ",") {
                let name = piece.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !name.isEmpty { names.insert(name) }
            }
        }
        return names
    }

    @Test("configuration is on the list, because bootstrap registers it")
    func configurationIsAlwaysAvailable() throws {
        let names = try alwaysAvailableNames()
        #expect(names.contains("Configuration"))
    }

    @Test("the list is short — it is a list of exceptions, not a workaround")
    func listStaysSmall() throws {
        // If this ever fails, the question to ask is whether the entries
        // added are genuinely resolvable without registration, or whether
        // someone silenced a true warning by adding a name to a list.
        #expect(try alwaysAvailableNames().count <= 6)
    }
}
