import FlightChannels
import FlightCore
import FlightPubSub
import FlightWebTesting
import Testing

@Suite("Topic patterns and routing")
struct RouterTests {

    private func registration(_ pattern: String) -> ChannelRegistration {
        ChannelRegistration(pattern) { _ in CatchAllChannel() }
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
            registration("*"),
            registration("room:*"),
            registration("room:admin:*"),
            registration("room:admin:hq"),
        ])
        #expect(router.match("room:admin:hq")?.topicPattern == "room:admin:hq")
        #expect(router.match("room:admin:1")?.topicPattern == "room:admin:*")
        #expect(router.match("room:7")?.topicPattern == "room:*")
        #expect(router.match("elsewhere")?.topicPattern == "*")
    }

    @Test("no match is nil, not a crash")
    func noMatch() throws {
        let router = try ChannelRouter(registrations: [registration("room:*")])
        #expect(router.match("game:1") == nil)
    }

    @Test("duplicate patterns fail construction — a bootstrap error, not a runtime surprise")
    func duplicates() throws {
        #expect(throws: ChannelsError.duplicateTopicPattern("room:*")) {
            try ChannelRouter(registrations: [
                registration("room:*"),
                registration("room:*"),
            ])
        }
    }

    @Test("an invalid pattern declared by a module fails composition")
    func invalidPatternFailsBootstrap() throws {
        struct BadPatternModule: FlightModule {
            let channels = [ChannelRegistration("bad*pattern") { _ in CatchAllChannel() }]
            func configure(_ container: Container) throws {}
        }
        // Earlier than it used to be: this was a freeze() failure, because the
        // router was built from whatever the container had collected. The
        // router is now built when Channels is, so a malformed pattern fails
        // before there is a container at all.
        let configuration = Configuration()
        let pubsub = try FlightPubSubModule(configuration: configuration)
        #expect(throws: ChannelsError.self) {
            try FlightChannelsModule(
                bus: pubsub.bus,
                configuration: configuration,
                channels: BadPatternModule().channels)
        }
    }

    @Test("module wiring: router, broadcaster, configuration are resolvable components")
    func moduleBeans() throws {
        let harness = try Harness()
        let router = try harness.container.resolve(ChannelRouter.self)
        #expect(router.match("room:1") != nil)
        #expect(router.match("lobby")?.topicPattern == "lobby")
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
