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
/// - `ChannelRouter` — built at `freeze()` from every `ChannelRegistration`
///   any module registered; duplicate or malformed topic patterns fail the
///   app at bootstrap, before the socket route ever serves.
/// - `ChannelBroadcaster` — the broadcast seam over `any PubSub`.
///
/// An app module declares the dependency, registers its channels, and mounts
/// the socket route:
///
///     struct AppModule: FlightModule {
///         static var dependencies: [any FlightModule.Type] { [FlightChannelsModule.self] }
///         func configure(_ container: Container) throws {
///             container.registerChannel("room:*") { c in
///                 RoomChannel(broadcaster: try c.resolve(ChannelBroadcaster.self))
///             }
///             container.registerChannelSocket("/socket")
///         }
///     }
public struct FlightChannelsModule: FlightModule {
    public static var dependencies: [any FlightModule.Type] {
        [FlightPubSubModule.self]
    }

    public init() {}

    public func configure(_ container: Container) throws {
        container.register(ChannelsConfiguration.self, scope: .singleton) { container in
            try ChannelsConfiguration(configuration: container.resolve(Configuration.self))
        }
        // The factory runs at freeze(), after every module's configure —
        // so registrations from modules that depend on this one are all
        // visible (the same post-configure collection Web's route table
        // relies on).
        container.register(ChannelRouter.self, scope: .singleton) { container in
            try ChannelRouter(registrations: container.collectChannelRegistrations())
        }
        container.register(ChannelBroadcaster.self, scope: .singleton) { container in
            ChannelBroadcaster(pubsub: try container.resolve((any PubSub).self))
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
        registerRoute(.get, path, kind: .upgrade, source: source) { context in
            let principal = try await authenticate?(context)
            let handler = try ChannelSocketHandler(context: context, principal: principal)
            return .upgrade(handler: handler, context: context)
        }
    }
}
