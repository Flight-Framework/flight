import FlightChannelsProtocol
import FlightCore
import FlightWeb

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
/// The factory takes the `RequestContext` the socket was upgraded from, which
/// is the same shape a route terminal has. Every component is a singleton
/// (``FlightCore/Lifetime``), so resolving from it later in the socket's life
/// is the same lookup it would have been at join time.
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
    public let makeChannel: @Sendable (RequestContext) throws -> any Channel

    public init(
        _ topicPattern: String,
        source: String = "<direct>",
        makeChannel: @escaping @Sendable (RequestContext) throws -> any Channel
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
