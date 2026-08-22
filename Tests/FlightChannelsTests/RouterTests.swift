import FlightChannels
import FlightCore
import FlightWebTesting
import Testing

@Suite("Topic patterns and routing")
struct RouterTests {

    private func registration(_ pattern: String) throws -> ChannelRegistration {
        ChannelRegistration(pattern: try TopicPattern(parsing: pattern)) { CatchAllChannel() }
    }

    @Test("pattern language: exact, trailing wildcard, catch-all — nothing else")
    func patternParsing() throws {
        #expect(try TopicPattern(parsing: "room:42").matches("room:42"))
        #expect(!(try TopicPattern(parsing: "room:42").matches("room:421")))
        #expect(try TopicPattern(parsing: "room:*").matches("room:42"))
        #expect(try TopicPattern(parsing: "room:*").matches("room:"))
        #expect(!(try TopicPattern(parsing: "room:*").matches("game:1")))
        #expect(try TopicPattern(parsing: "*").matches("anything"))

        #expect(throws: ChannelsError.invalidTopicPattern("", "pattern must not be empty")) {
            try TopicPattern(parsing: "")
        }
        #expect(throws: ChannelsError.self) { try TopicPattern(parsing: "room:*:sub") }
        #expect(throws: ChannelsError.self) { try TopicPattern(parsing: "*:room") }
    }

    @Test("most specific wins: exact over wildcard, longer prefix over shorter")
    func specificity() throws {
        let router = try ChannelRouter(registrations: [
            try registration("*"),
            try registration("room:*"),
            try registration("room:admin:*"),
            try registration("room:admin:hq"),
        ])
        #expect(router.match("room:admin:hq")?.pattern.description == "room:admin:hq")
        #expect(router.match("room:admin:1")?.pattern.description == "room:admin:*")
        #expect(router.match("room:7")?.pattern.description == "room:*")
        #expect(router.match("elsewhere")?.pattern.description == "*")
    }

    @Test("no match is nil, not a crash")
    func noMatch() throws {
        let router = try ChannelRouter(registrations: [try registration("room:*")])
        #expect(router.match("game:1") == nil)
    }

    @Test("duplicate patterns fail construction — a bootstrap error, not a runtime surprise")
    func duplicates() throws {
        #expect(throws: ChannelsError.duplicateTopicPattern("room:*")) {
            try ChannelRouter(registrations: [
                try registration("room:*"),
                try registration("room:*"),
            ])
        }
    }

    @Test("an invalid pattern registered via a module fails the app at freeze()")
    func invalidPatternFailsBootstrap() {
        struct BadPatternModule: FlightModule {
            static var dependencies: [any FlightModule.Type] { [FlightChannelsModule.self] }
            func configure(_ container: Container) throws {
                container.registerChannel("bad*pattern") { _ in CatchAllChannel() }
            }
        }
        #expect(throws: (any Error).self) {
            try TestContainer.build { BadPatternModule() }
        }
    }

    @Test("module wiring: router, broadcaster, configuration are resolvable components (§9)")
    func moduleBeans() throws {
        let harness = try Harness()
        let router = try harness.container.resolve(ChannelRouter.self)
        #expect(router.match("room:1") != nil)
        #expect(router.match("lobby")?.pattern.description == "lobby")
        _ = try harness.container.resolve(ChannelBroadcaster.self)
        let configuration = try harness.container.resolve(ChannelsConfiguration.self)
        #expect(configuration.heartbeatTimeout == .seconds(5))
        #expect(configuration.heartbeatCheckInterval == .milliseconds(50))
    }

    @Test("configuration defaults: 60s timeout, quarter-interval check")
    func configurationDefaults() throws {
        let configuration = try ChannelsConfiguration(configuration: .init())
        #expect(configuration.heartbeatTimeout == .seconds(60))
        #expect(configuration.heartbeatCheckInterval == .seconds(15))
    }
}
