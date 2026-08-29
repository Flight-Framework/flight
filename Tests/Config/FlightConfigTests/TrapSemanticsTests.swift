import Configuration
import Testing

@testable import FlightConfig

/// `get(_:default:)` is non-throwing by contract, so its
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

    @Test("a key present as an array traps rather than taking the default")
    func unrepresentableValueTraps() async {
        // It resolved through the non-throwing `rawValue(for:)`, so the
        // unrepresentable throw became nil became the default — masking a
        // present value on the one accessor documented never to.
        await #expect(processExitsWith: .failure) {
            let config = Configuration(providers: [
                InMemoryProvider(values: [
                    "server.hosts": ConfigValue(.stringArray(["a", "b"]), isSecret: false)
                ])
            ])
            _ = config.get("server.hosts", default: "localhost")
        }
    }

    @Test("a failing provider traps rather than taking the default")
    func providerFailureTraps() async {
        await #expect(processExitsWith: .failure) {
            let config = Configuration(providers: [FailingProvider()])
            _ = config.get("datasource.password", default: "fallback")
        }
    }

    @Test("an absent key still takes the default — the one case it is for")
    func absentKeyTakesDefault() {
        let config = Configuration(values: [:])
        #expect(config.get("server.port", default: 8080) == 8080)
    }
}
