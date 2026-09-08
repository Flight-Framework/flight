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
/// An app module *declares* its channels as a value and mounts the socket
/// route. It no longer depends on this module: a channel is declared without
/// a broadcaster, and given one when it is created.
///
///     struct AppModule: FlightModule {
///         let channels: [ChannelRegistration]
///         init() throws {
///             self.channels = [
///                 try ChannelRegistration("room:*", source: "AppModule") { context in
///                     RoomChannel(broadcaster: try context.resolve(ChannelBroadcaster.self))
///                 }
///             ]
///         }
///         func configure(_ container: Container) throws {
///             container.registerChannelSocket("/socket")
///         }
///     }
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
        self.settings = try ChannelsConfiguration(configuration: configuration)
        self.broadcaster = ChannelBroadcaster(pubsub: bus)
        self.router = try ChannelRouter(registrations: channels)
    }

    /// This module takes what it provides, so it cannot be built from its
    /// type — every supported path checks this and throws first.
    public static var isTypeConstructible: Bool { false }

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
    public func configure(_ container: Container) throws {
        let settings = self.settings
        let broadcaster = self.broadcaster
        let router = self.router
        container.register(ChannelsConfiguration.self, scope: .singleton) { _ in settings }
        container.register(ChannelRouter.self, scope: .singleton) { _ in router }
        container.register(ChannelBroadcaster.self, scope: .singleton) { _ in broadcaster }
    }
}

extension RouteRegistration {
    /// The channels WebSocket endpoint, as a route value — the value-level
    /// spelling of `container.registerChannelSocket(_:)`, for a module that
    /// declares its routes rather than registering them.
    ///
    ///     struct AppModule: FlightModule {
    ///         let routes = [RouteRegistration.channelSocket("/socket")]
    ///     }
    ///
    /// `authenticate` runs during the initial HTTP upgrade request, before
    /// the WebSocket exists — exactly where connection identity is
    /// established. Return the connection's principal (nil admits an
    /// anonymous socket); throw to refuse the upgrade outright.
    public static func channelSocket(
        _ path: String = "/socket",
        source: String = "FlightChannels",
        authenticate: (@Sendable (RequestContext) async throws -> (any ChannelPrincipal)?)? = nil
    ) -> RouteRegistration {
        RouteRegistration(
            method: "GET", path: path, kind: .upgrade(.webSocket), source: source
        ) { context in
            let principal = try await authenticate?(context)
            let handler = try ChannelSocketHandler(context: context, principal: principal)
            return .upgrade(handler: handler, context: context)
        }
    }
}

extension Container {
    /// Mounts the channels WebSocket endpoint as an ordinary upgrade
    /// route — the same `registerRoute` pipeline as everything else, so the
    /// endpoint shows up in startup logs and introspection like any route.
    ///
    /// `authenticate` runs during the initial HTTP upgrade request, before
    /// the WebSocket exists — exactly where connection identity is
    /// established. Return the connection's principal (nil admits an
    /// anonymous socket); throw to refuse the upgrade outright:
    ///
    ///     container.registerChannelSocket("/socket") { context in
    ///         guard let token = context.request.queryParam("token") else {
    ///             throw HTTPError(.unauthorized)
    ///         }
    ///         return try await verify(token) // any ChannelPrincipal
    ///     }
    public func registerChannelSocket(
        _ path: String = "/socket",
        source: String = "FlightChannels",
        authenticate: (@Sendable (RequestContext) async throws -> (any ChannelPrincipal)?)? = nil
    ) {
        // flight:hand-registered — this convenience *is* the mount, and the
        // path is its argument. An application that wants the route in the
        // static manifest declares it with `@WebSocketRoute` instead, which
        // is what the demo template does.
        registerRoute(.get, path, kind: .upgrade(.webSocket), source: source) { context in
            let principal = try await authenticate?(context)
            let handler = try ChannelSocketHandler(context: context, principal: principal)
            return .upgrade(handler: handler, context: context)
        }
    }
}
