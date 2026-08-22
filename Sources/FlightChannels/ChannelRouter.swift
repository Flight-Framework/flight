import FlightChannelsProtocol
import FlightCore

/// One registered channel: the topic pattern it serves plus the factory
/// that makes a fresh `Channel` instance per join (§2: "joining creates a
/// channel instance"). Registered through the same container pipeline as
/// every other component — the Web `RouteRegistration` precedent, applied to
/// channels — so registrations show up in Core introspection like anything
/// else.
public struct ChannelRegistration: Sendable {
    public let pattern: TopicPattern
    /// Where this channel was declared, for startup logs and diagnostics.
    public let source: String
    /// Called once per successful topic match at join time.
    public let makeChannel: @Sendable () throws -> any Channel

    public init(
        pattern: TopicPattern,
        source: String = "<direct>",
        makeChannel: @escaping @Sendable () throws -> any Channel
    ) {
        self.pattern = pattern
        self.source = source
        self.makeChannel = makeChannel
    }
}

extension Container {
    /// Registers a `Channel` for a topic pattern (§9) — from any module's
    /// `configure(_:)`:
    ///
    ///     container.registerChannel("room:*") { _ in RoomChannel() }
    ///
    /// The factory receives the container so a channel can resolve its
    /// dependencies (the broadcaster, a repository) at join time; it runs
    /// post-freeze, so resolution is the ordinary lock-free read.
    public func registerChannel(
        _ topicPattern: String,
        source: String = "<direct>",
        factory: @escaping @Sendable (Container) throws -> any Channel
    ) {
        register(
            ChannelRegistration.self,
            qualifier: "channel \(topicPattern) @\(source)",
            scope: .singleton
        ) { container in
            ChannelRegistration(
                pattern: try TopicPattern(parsing: topicPattern),
                source: source,
                makeChannel: { try factory(container) }
            )
        }
    }

    /// All channel registrations, in registration order.
    internal func collectChannelRegistrations() throws -> [ChannelRegistration] {
        let typeName = String(reflecting: ChannelRegistration.self)
        return try allRegistrations()
            .filter { $0.typeName == typeName }
            .map { try resolve(ChannelRegistration.self, qualifier: $0.qualifier) }
    }
}

/// Maps a join's topic to the channel registration that serves it.
/// Immutable after bootstrap: built once from the frozen container's
/// registrations, validated then (duplicate patterns fail startup).
public struct ChannelRouter: Sendable {
    /// Sorted most-specific-first at construction, so `match` is a linear
    /// scan returning the first hit. Channel tables are small (tens, not
    /// thousands); measure before anything cleverer.
    private let registrations: [ChannelRegistration]

    public init(registrations: [ChannelRegistration]) throws {
        var seen = Set<String>()
        for registration in registrations {
            guard seen.insert(registration.pattern.description).inserted else {
                throw ChannelsError.duplicateTopicPattern(registration.pattern.description)
            }
        }
        self.registrations = registrations.sorted {
            $0.pattern.specificity > $1.pattern.specificity
        }
    }

    /// The most specific registration matching `topic`, or nil — which the
    /// session layer answers with an `unmatched_topic` join error.
    public func match(_ topic: String) -> ChannelRegistration? {
        registrations.first { $0.pattern.matches(topic) }
    }

    public var isEmpty: Bool { registrations.isEmpty }
}
