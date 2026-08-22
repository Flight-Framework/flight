import FlightActuator
import FlightCore
import FlightWeb
import FlightWebTesting
import HTTPTypes
import Testing

/// §5: `actuator.format` read once at bootstrap. Absent → ssr; present but
/// malformed → loud bootstrap failure, never a silent default.
@Suite("Format configuration")
struct ConfigTests {

    private func contentType(for values: [String: String]) async throws -> String? {
        let container = try TestContainer.build(configuration: Configuration(values: values)) {
            ActuatorModule(environment: .dev)
        }
        let client = try TestClient(container: container)
        return await client.get("/actuator").headers[.contentType]
    }

    @Test("absent key defaults to SSR")
    func defaultIsSSR() async throws {
        #expect(try await contentType(for: [:]) == "text/html; charset=utf-8")
    }

    @Test("'ssr' selects SSR explicitly")
    func explicitSSR() async throws {
        #expect(try await contentType(for: ["actuator.format": "ssr"]) == "text/html; charset=utf-8")
    }

    @Test("'json' selects the JSON rendering")
    func explicitJSON() async throws {
        #expect(try await contentType(for: ["actuator.format": "json"]) == "application/json; charset=utf-8")
    }

    @Test("case and surrounding whitespace are tolerated")
    func lenientSpelling() async throws {
        #expect(try await contentType(for: ["actuator.format": " JSON "]) == "application/json; charset=utf-8")
    }

    @Test("a malformed value fails bootstrap loudly instead of defaulting")
    func malformedValueFailsBootstrap() {
        #expect(throws: ConfigError.self) {
            _ = try TestContainer.build(
                configuration: Configuration(values: ["actuator.format": "xml"])
            ) {
                ActuatorModule(environment: .dev)
            }
        }
    }
}

@Suite("ActuatorFormat decoding")
struct ActuatorFormatTests {
    @Test("decodes the two valid spellings, leniently", arguments: [
        ("ssr", ActuatorFormat.ssr),
        ("json", ActuatorFormat.json),
        ("SSR", ActuatorFormat.ssr),
        ("Json", ActuatorFormat.json),
        ("  json\t", ActuatorFormat.json),
    ])
    func decodesValid(raw: String, expected: ActuatorFormat) {
        #expect(ActuatorFormat(configValue: raw) == expected)
    }

    @Test("rejects anything else", arguments: ["xml", "", "html", "ssr json", "1"])
    func rejectsInvalid(raw: String) {
        #expect(ActuatorFormat(configValue: raw) == nil)
    }
}
