import Testing
@testable import FlightConfig

/// `get(_:default:)` is non-throwing by contract (§2), so its
/// present-but-malformed case cannot throw — and silently returning the
/// default would mask a corrupted configuration. The documented behavior is
/// a trap; these exit tests pin it.
@Suite("get(_:default:) trap semantics")
struct TrapSemanticsTests {

    @Test("a present but malformed value traps instead of masking")
    func malformedValueTraps() async {
        await #expect(processExitsWith: .failure) {
            let config = Configuration(values: ["server.port": "not a number"])
            _ = config.get("server.port", default: 8080)
        }
    }

    @Test("the same key decodes fine as String — the trap is type-driven")
    func sameKeyDecodesAsString() {
        let config = Configuration(values: ["server.port": "not a number"])
        #expect(config.get("server.port", default: "x") == "not a number")
    }
}
