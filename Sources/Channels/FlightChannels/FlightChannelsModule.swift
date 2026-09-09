import FlightChannelsProtocol
import FlightCore
import FlightPubSub
import FlightWeb
import HTTPTypes

/// Registers Channels with the container. Three components, no service —
/// the socket-owning handler's lifetime is per connection, driven by the
/// upgrade hook, not a `ServiceGroup` member:
///
/// - `ChannelsConfiguration` — heartbeat settings, read from the app
///   configuration once.
/// - `ChannelRouter` — built at composition from every `ChannelRegistration`
///   any module declared; duplicate or malformed topic patterns fail before
///   the container is frozen, let alone before the socket route serves.
/// - `ChannelBroadcaster` — the broadcast seam over `any PubSub`.
///
/// An app module *declares* its channels as a value. It no longer depends on
/// this module: a channel is declared without a broadcaster, and given one
/// (in the `ChannelContext`) when it is created.
///
///     struct AppChannels: FlightModule {
///         let channels: [ChannelRegistration]
///         init() {
///             self.channels = [
///                 ChannelRegistration("room:*", source: "AppChannels") { channel in
///                     RoomChannel(broadcaster: channel.broadcaster)
///                 }
///             ]
///         }
///     }
///     // The socket route is a value too: `channels.socketRoute("/socket") { ... }`,
///     // handed to `FlightWebModule` alongside every other route.
///
/// The composer collects `channels` from every module declaring any and
/// passes them here, so an extension package contributes without the
/// application listing it.
public struct FlightChannelsModule: FlightModule {
    public static var dependencies: [any FlightModule.Type] {
        [FlightPubSubModule.self]
    }

    /// Heartbeat and buffering settings, read once at composition.
    public let settings: ChannelsConfiguration

    /// The broadcast seam over `any PubSub`.
    public let broadcaster: ChannelBroadcaster

    /// Built here, from the channels every module declared — not at
    /// `freeze()` from what the container happened to hold. Duplicate or
    /// malformed topic patterns therefore fail composition, which is earlier
    /// than bootstrap and much earlier than the first join.
    public let router: ChannelRouter

    /// What a socket route needs, as one injectable value — so a declared
    /// route injects it instead of resolving three components per upgrade.
    public let sockets: ChannelSockets

    /// - Parameters:
    ///   - bus: The application's PubSub, from `FlightPubSubModule.bus`.
    ///   - configuration: For `flight.channels.*`.
    ///   - channels: Every declared channel, from every module that declares
    ///     any. The composer concatenates them — see `ChannelRegistration`
    ///     for why they are values rather than container registrations, and
    ///     what cycle that removes.
    public init(
        bus: any PubSub,
        configuration: Configuration,
        channels: [ChannelRegistration] = []
    ) throws {
        let settings = try ChannelsConfiguration(configuration: configuration)
        let broadcaster = ChannelBroadcaster(pubsub: bus)
        let router = try ChannelRouter(registrations: channels)
        self.settings = settings
        self.broadcaster = broadcaster
        self.router = router
        self.sockets = ChannelSockets(
            router: router, pubsub: bus, configuration: settings, broadcaster: broadcaster)
    }

    public init() {
        preconditionFailure(
            "FlightChannelsModule takes its bus, configuration and channels in "
                + "init(bus:configuration:channels:), so it cannot be instantiated from its type. "
                + "Pass `composedBy: flightComposeModules` to Flight.run — `flight new` writes "
                + "that argument — or construct the module yourself and use the entry point "
                + "taking module instances.")
    }

    /// Projects what this module already holds. Nothing is built here, and in
    /// particular the router is not: it exists before any container does.
    /// This module's socket endpoint, as a route value.
    ///
    /// Nothing is looked up: the handler is built from what this module
    /// already holds. This is the value form of a socket mount — a declared
    /// `@WebSocketRoute` controller injecting ``ChannelSockets`` is the other.
    public func socketRoute(
        _ path: String = "/socket",
        source: String = "FlightChannels",
        authenticate: (@Sendable (RequestContext) async throws -> (any ChannelPrincipal)?)? = nil
    ) -> RouteRegistration {
        let sockets = self.sockets
        return RouteRegistration(
            method: "GET", path: path, kind: .upgrade(.webSocket), source: source
        ) { context in
            let principal = try await authenticate?(context)
            return .upgrade(handler: sockets.handler(principal: principal), context: context)
        }
    }
}
