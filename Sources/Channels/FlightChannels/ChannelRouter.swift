import FlightChannelsProtocol
import FlightCore
import FlightWeb

/// What a channel is handed when a join creates it.
///
/// Carries the values `FlightChannelsModule` itself owns. They arrive here
/// rather than being injected because a channel is *declared* by a module the
/// channels module is built from — so a channel cannot depend on it at
/// construction without a cycle. At join time there is no such problem: the
/// broadcaster has existed since composition.
///
/// Everything else a channel needs — repositories, services, presence — is an
/// ordinary value the declaring module closes over.
public struct ChannelContext: Sendable {
    /// The topic that matched, with wildcards resolved.
    public let topic: String

    /// The broadcast seam, for fan-out from inside the channel.
    public let broadcaster: ChannelBroadcaster

    /// The socket's principal, established at upgrade.
    public let principal: (any ChannelPrincipal)?

    public init(
        topic: String,
        broadcaster: ChannelBroadcaster,
        principal: (any ChannelPrincipal)? = nil
    ) {
        self.topic = topic
        self.broadcaster = broadcaster
        self.principal = principal
    }
}

/// One declared channel: the topic pattern it serves plus the factory that
/// makes a fresh `Channel` instance per join ("joining creates a channel
/// instance").
///
/// A **value**, held by whichever module declares it, and handed to
/// `FlightChannelsModule` at composition. It used to be a container
/// registration that `FlightChannelsModule` collected at `freeze()`, which
/// made the two mutually dependent: a module declaring a channel needed the
/// `ChannelBroadcaster` that Channels provides, and Channels needed the
/// declarations that module contributed. Nothing about the *values* was
/// circular — `bus -> ChannelBroadcaster -> RoomChannel` is a chain — the
/// cycle was only that one module both provided and aggregated. Declaring
/// channels as values a module holds removes it.
///
/// The factory takes a ``ChannelContext`` — the values Channels owns, handed
/// over at join time. It used to take the upgrade's `RequestContext` and
/// resolve out of it, which meant a channel created ten minutes into a
/// socket's life reached through the request that opened it.
public struct ChannelRegistration: Sendable {
    /// The pattern as written. Parsed by ``ChannelRouter``, not here, so that
    /// declaring a channel is non-throwing: `FlightModule` requires a
    /// non-throwing `init()`, and a module that had to `try` to state its own
    /// channels could not conform. A malformed pattern still fails at
    /// composition — `ChannelRouter.init` is the single place that reports it,
    /// alongside duplicates.
    public let topicPattern: String
    /// Where this channel was declared, for startup logs and diagnostics.
    public let source: String
    /// Called once per successful topic match at join time.
    public let makeChannel: @Sendable (ChannelContext) throws -> any Channel

    public init(
        _ topicPattern: String,
        source: String = "<direct>",
        makeChannel: @escaping @Sendable (ChannelContext) throws -> any Channel
    ) {
        self.topicPattern = topicPattern
        self.source = source
        self.makeChannel = makeChannel
    }

}

/// Maps a join's topic to the channel registration that serves it.
/// Immutable: built once at composition from the declared registrations and
/// validated then (duplicate patterns fail startup, before the container is
/// even frozen).
public struct ChannelRouter: Sendable {
    /// Sorted most-specific-first at construction, so `match` is a linear
    /// scan returning the first hit. Channel tables are small (tens, not
    /// thousands); measure before anything cleverer.
    private let routes: [(pattern: TopicPattern, registration: ChannelRegistration)]

    /// Parses every declared pattern and rejects duplicates.
    ///
    /// Both failures land here rather than at the declaration, so a module can
    /// state its channels without `try` and every pattern in the application
    /// is validated in one pass at composition.
    public init(registrations: [ChannelRegistration]) throws {
        var seen = Set<String>()
        var routes: [(pattern: TopicPattern, registration: ChannelRegistration)] = []
        for registration in registrations {
            let pattern = try TopicPattern(parsing: registration.topicPattern)
            guard seen.insert(pattern.description).inserted else {
                throw ChannelsError.duplicateTopicPattern(pattern.description)
            }
            routes.append((pattern, registration))
        }
        self.routes = routes.sorted { $0.pattern.specificity > $1.pattern.specificity }
    }

    /// The most specific registration matching `topic`, or nil — which the
    /// session layer answers with an `unmatched_topic` join error.
    public func match(_ topic: String) -> ChannelRegistration? {
        routes.first { $0.pattern.matches(topic) }?.registration
    }

}
