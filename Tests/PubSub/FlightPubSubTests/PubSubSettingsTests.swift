import FlightCore
import Testing

@testable import FlightPubSub

/// The module's deployment knobs, which until 0.13.0 were `init` parameters
/// no deployment could reach: both public entry points take
/// `[any FlightModule.Type]` and instantiate with `init()`, so buffering,
/// node identity and the broadcast timeout were unreachable — and the
/// documented example passed a module instance and did not compile.
@Suite("PubSub settings")
struct PubSubSettingsTests {

    // MARK: Buffering

    @Test("unbounded is the default when nothing is configured")
    func bufferingDefaultsToUnbounded() throws {
        let settings = try PubSubSettings(configuration: Configuration())
        #expect(settings.bufferingPolicy == .unbounded)
        #expect(settings.nodeID == nil)
        #expect(settings.broadcastTimeout == .after(.seconds(5)))
    }

    @Test(
        "a bound and a count parse",
        arguments: [
            ("newest:1024", PubSubBufferingPolicy.bufferingNewest(1024)),
            ("oldest:512", .bufferingOldest(512)),
            ("unbounded", .unbounded),
            ("  NEWEST : 16  ", .bufferingNewest(16)),
        ])
    func bufferingParses(_ written: String, _ expected: PubSubBufferingPolicy) throws {
        let settings = try PubSubSettings(
            configuration: Configuration(values: [PubSubSettings.bufferingKey: written]))
        #expect(settings.bufferingPolicy == expected)
    }

    /// Loudly, not silently: a node told to bound its buffers and quietly
    /// running unbounded is the failure the setting exists to prevent.
    @Test(
        "a malformed buffering policy fails bootstrap",
        arguments: ["newest", "newest:0", "newest:-4", "sideways:10", "1024", ""])
    func malformedBufferingThrows(_ written: String) {
        #expect(throws: (any Error).self) {
            try PubSubSettings(
                configuration: Configuration(values: [PubSubSettings.bufferingKey: written]))
        }
    }

    // MARK: Broadcast timeout

    @Test("a duration parses, and `never` is distinct from absent")
    func broadcastTimeoutParses() throws {
        let bounded = try PubSubSettings(
            configuration: Configuration(values: [PubSubSettings.broadcastTimeoutKey: "250ms"]))
        #expect(bounded.broadcastTimeout == .after(.milliseconds(250)))
        #expect(bounded.broadcastTimeout.duration == .milliseconds(250))

        let forever = try PubSubSettings(
            configuration: Configuration(values: [PubSubSettings.broadcastTimeoutKey: "never"]))
        #expect(forever.broadcastTimeout == .never)
        // The distinction a bare `Duration?` could not carry: "wait forever"
        // and "not configured" are different answers.
        #expect(forever.broadcastTimeout.duration == nil)
    }

    @Test("a bare number is rejected, as everywhere else a Duration is read")
    func broadcastTimeoutRequiresAUnit() {
        #expect(throws: (any Error).self) {
            try PubSubSettings(
                configuration: Configuration(values: [PubSubSettings.broadcastTimeoutKey: "30"]))
        }
    }

    // MARK: Reaching the pool

    @Test("the configured policy reaches LocalPubSub through the module")
    func settingsReachTheComponent() throws {
        let container = Container()
        container.register(Configuration.self, scope: .singleton) { _ in
            Configuration(values: [
                PubSubSettings.bufferingKey: "oldest:8",
                PubSubSettings.nodeIDKey: "api-3",
            ])
        }
        try FlightPubSubModule().configure(container)
        try container.freeze()
        // Resolvable at all is the assertion that matters: the factory reads
        // and validates the settings at freeze(), so a malformed value here
        // would have failed the freeze above.
        _ = try container.resolve(LocalPubSub.self)
        _ = try container.resolve((any PubSub).self)
    }
}
