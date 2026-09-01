import FlightCore

/// Everything the dashboard serves, assembled per request: data Core
/// already tracks as a natural consequence of bootstrap — no new
/// instrumentation, no caching or polling layer. Both underlying calls are
/// cheap reads against frozen (or externally-tracked, for module health)
/// state.
public struct ActuatorSnapshot: Sendable {
    public let environment: FlightEnvironment
    public let modules: [ModuleStatus]
    public let components: [ComponentDescriptor]

    public init(
        environment: FlightEnvironment,
        modules: [ModuleStatus],
        components: [ComponentDescriptor]
    ) {
        self.environment = environment
        self.modules = modules
        self.components = components
    }

    /// The per-request assembly the controller performs, as a public
    /// convenience for anyone building their own surface over the same data.
    public init(container: Container, environment: FlightEnvironment) {
        self.init(
            environment: environment,
            modules: container.moduleStatuses(),
            components: container.allRegistrations()
        )
    }
}

// MARK: - JSON rendering

/// Hand-written encoding rather than retroactive `Codable` conformances on
/// Core's types: the JSON shape is Actuator's public contract for external
/// front-ends, so it is pinned here — Core remains free to evolve its
/// introspection structs without silently changing this wire format.
///
/// Shape:
/// ```json
/// {
///   "environment": "dev",
///   "modules": [{"module": "WebModule", "health": "running", "error": null}],
///   "components": [{"type": "App.UserService", "scope": "singleton",
///              "stereotype": "service", "qualifier": null,
///              "sourceModule": "AppModule"}]
/// }
/// ```
extension ActuatorSnapshot: Encodable {
    private enum CodingKeys: String, CodingKey {
        case environment, modules, components
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(environment.rawValue, forKey: .environment)
        try container.encode(modules.map(ModuleStatusRepresentation.init), forKey: .modules)
        try container.encode(components.map(ComponentRepresentation.init), forKey: .components)
    }
}

/// One module row on the wire. `error` is present (non-null) only when
/// `health` is "failed".
struct ModuleStatusRepresentation: Encodable {
    let module: String
    let health: String
    let error: String?

    init(_ status: ModuleStatus) {
        self.module = status.moduleName
        self.health = status.health.actuatorLabel
        self.error = status.health.failureDescription
    }
}

/// One component row on the wire — `ComponentDescriptor`, field for field, with
/// enums rendered as their stable labels.
struct ComponentRepresentation: Encodable {
    let type: String
    let scope: String
    let stereotype: String
    let qualifier: String?
    let sourceModule: String

    init(_ descriptor: ComponentDescriptor) {
        self.type = descriptor.typeName
        self.scope = descriptor.scope.actuatorLabel
        self.stereotype = descriptor.stereotype.actuatorLabel
        self.qualifier = descriptor.qualifier
        self.sourceModule = descriptor.sourceModule
    }
}
