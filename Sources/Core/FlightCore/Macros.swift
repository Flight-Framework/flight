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
/// type with every `@Inject` property resolved against the container
/// and every `@ConfigValue` property resolved against `Configuration`;
/// 2. a static registration thunk `_flightRegister(_:)`;
/// 3. conformance to `_FlightRegistrable`.
///
/// The exact expansions are pinned by Tests/Core/FlightCoreMacroTests — those
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
public macro Inject(_ qualifier: String? = nil) =
    #externalMacro(module: "FlightCoreMacrosImpl", type: "InjectMacro")

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

/// A typed slice of configuration, bound once at bootstrap.
///
/// Every stored property becomes a binding under
/// `namespace.<kebab-cased-property-name>` — `signingKey` under `@Settings("auth")`
/// resolves `auth.signing-key`. A property with its own default value is
/// optional (the default applies when the key is absent from every
/// configuration source); a property with none is required, and — same rule
/// as the no-default form of `@ConfigValue` — the build plugin checks it
/// against `flight.yaml`'s base layer at compile time, so a missing required
/// key is a build error naming the site, not a bootstrap-time surprise.
///
/// ```swift
/// @Settings("auth")
/// struct AuthSettings {
///     var issuer: String = "myapp"
///     var audience: String = "myapp-web"
///     @Secret var signingKey: String              // required — no default
///     var tokenLifetime: Duration = .hours(12)     // "12h", "500ms", ...
///
///     func validate() throws {
///         guard signingKey.count >= 32 else { throw AuthConfigurationError.signingKeyTooShort }
///     }
/// }
/// ```
///
/// The type is registered as an ordinary `.singleton` component — resolve it
/// with `@Inject var settings: AuthSettings` anywhere, exactly like any
/// other dependency. A `validate()` method with no parameters, if the type
/// declares one, runs once, right after construction, at bootstrap: the
/// place a bad value should fail, not the first request that reads it.
///
/// A property may not be `Optional` — `@Settings` binds a value once, and a
/// key that may or may not exist has no single answer for "what did we
/// configure"; give it a concrete default instead. A property with its own
/// default must be `var`, since the generated initializer overrides that
/// default when configuration supplies a value — Swift does not allow a
/// custom initializer to reassign a `let` that already has one.
///
/// This binds the *value*, not the lookup — flight.yaml, the per-environment
/// overlay file, and environment variables remain exactly what they are
/// today; `@Settings` only replaces the hand-written `init(configuration:)`
/// that used to turn them into a typed object.
///
/// The exact expansion is pinned by Tests/Core/FlightCoreMacroTests.
@attached(member, names: named(init), named(_flightRegister), named(description))
@attached(extension, conformances: _FlightRegistrable, CustomStringConvertible)
public macro Settings(_ namespace: String) =
    #externalMacro(module: "FlightCoreMacrosImpl", type: "SettingsMacro")

/// Marks a `@Settings` property whose value must not leak into logs or
/// diagnostics. When at least one property carries `@Secret`, `@Settings`
/// generates a `description` that redacts those fields to `<REDACTED>` —
/// so printing or logging the settings object by accident (a stray
/// `context.logger.info("\(settings)")`, a crash report) does not leak it.
///
/// This governs only the settings object's own textual representation. It
/// does not mark the underlying configuration key secret in Flight Config's
/// own diagnostic dump (`Configuration.debugDescription`) — that redaction
/// is a property of the *provider* the value came from
/// (`Configuration.load(secrets:)`), a separate and already-existing
/// mechanism.
@attached(peer)
public macro Secret() = #externalMacro(module: "FlightCoreMacrosImpl", type: "SecretMacro")

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
