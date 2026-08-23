import FlightConfig

/// Compiler-visible marker attached by `@Component`. The build
/// plugin's generator enumerates conformances of this protocol (via source
/// scanning) and the
/// generated `_registerAll` calls each type's `_flightRegister`.
public protocol _FlightRegistrable {
    static func _flightRegister(_ container: Container) throws
}

/// Marks a type as container-managed. Expansion:
/// 1. a memberwise resolving initializer `init(_flight:)` that constructs the
/// type with every `@Autowired` property resolved against the container
/// and every `@ConfigValue` property resolved against `Configuration`;
/// 2. a static registration thunk `_flightRegister(_:)`;
/// 3. conformance to `_FlightRegistrable`.
///
/// The exact expansions are pinned by Tests/FlightCoreMacroTests — those
/// fixtures are the spec, more precise than this comment.
@attached(member, names: named(init), named(_flightRegister))
@attached(extension, conformances: _FlightRegistrable)
public macro Component(
    scope: Lifetime = .singleton,
    qualifier: String? = nil
) = #externalMacro(module: "FlightCoreMacrosImpl", type: "ComponentMacro")

/// Stereotype for business logic and third-party clients. Expands
/// *identically* to `@Component` except the registration is tagged
/// `.service` — the tag feeds Actuator's layer grouping and any future AOP
/// pointcut; resolution never consults it. Lives in Core (not Web/Data)
/// because a service must be equally callable from a controller, a CLI
/// command, or a background job.
@attached(member, names: named(init), named(_flightRegister))
@attached(extension, conformances: _FlightRegistrable)
public macro Service(
    scope: Lifetime = .singleton,
    qualifier: String? = nil
) = #externalMacro(module: "FlightCoreMacrosImpl", type: "ServiceMacro")

/// Stereotype for data access. Same expansion as `@Component`,
/// tagged `.repository`. (`@Controller` is deliberately NOT here — it lives
/// in Flight Web, carrying route metadata meaningless outside HTTP dispatch;
/// only the `Stereotype.controller` case belongs to Core's vocabulary.)
@attached(member, names: named(init), named(_flightRegister))
@attached(extension, conformances: _FlightRegistrable)
public macro Repository(
    scope: Lifetime = .singleton,
    qualifier: String? = nil
) = #externalMacro(module: "FlightCoreMacrosImpl", type: "RepositoryMacro")

/// Marks a property as container-resolved at construction time.
/// A pure marker: the generated code lives in `@Component`'s expansion; this
/// macro's own expansion is empty and exists to validate the attachment site.
/// When two properties share a type, explicit qualifiers are *required* —
/// `@Component` emits a compile error otherwise.
@attached(peer)
public macro Autowired(_ qualifier: String? = nil) =
    #externalMacro(module: "FlightCoreMacrosImpl", type: "AutowiredMacro")

/// Marks a property as config-resolved instead. Same macro family,
/// same registration thunk.
///
/// The no-default form is a *required* key: per Flight Config, the build
/// plugin checks it against flight.yaml (the base layer) at compile time —
/// absent there and with no default is a build error at this site. A key
/// present in base but overridden per-environment still resolves normally;
/// only genuinely runtime-unknowable absence (wrong env file, unset env var)
/// surfaces as ConfigError.missingKey during bootstrap.
@attached(peer)
public macro ConfigValue(_ key: String) =
    #externalMacro(module: "FlightCoreMacrosImpl", type: "ConfigValueMacro")

/// The optional-key form (Flight Config): `default:` applies when the key
/// is absent from every source. A key that is present but *malformed* still
/// fails module configuration loudly — the expansion resolves through
/// `Configuration.getIfPresent`, so a bad value throws instead of being
/// silently papered over by the default.
@attached(peer)
public macro ConfigValue<T: ConfigDecodable>(_ key: String, default: T) =
    #externalMacro(module: "FlightCoreMacrosImpl", type: "ConfigValueMacro")

/// Wraps a method body in begin/commit/rollback against the task-local
/// `FlightTransactions.coordinator`. A flat compile-time expansion —
/// no runtime proxy, fully inspectable. Requires a `throws` method (rollback
/// semantics are meaningless without an error path); works on both sync and
/// `async` methods.
///
/// Implemented as an SE-0415 function body macro — requires Swift 6.1+.
@attached(body)
public macro Transactional() =
    #externalMacro(module: "FlightCoreMacrosImpl", type: "TransactionalMacro")
