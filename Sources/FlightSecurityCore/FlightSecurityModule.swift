import FlightCore
import FlightWeb
import Logging
import ServiceLifecycle

/// Module wiring (design §6).
///
/// Registers:
/// - the ``TokenValidator`` singleton — the generic ``OIDCTokenValidator``
///   configured from `security.oidc.*`, unless the application registered
///   its own `(any TokenValidator)` bean first (the §3.3 seam: configure a
///   custom-validator module *before* this one in the bootstrap module
///   list);
/// - the request-scoped ``PrincipalHolder`` carrying the principal;
/// - the authentication middleware, early in Flight Web's pipeline
///   (order ``middlewareOrder``);
/// - a maintenance `Service` that pre-warms the JWKS at startup and
///   refreshes it on the cache-TTL cadence.
///
/// ``requireAuthentication`` is deliberately *not* registered — apps add it
/// where wanted (design §5.1).
///
/// Missing required configuration (`security.oidc.issuer`/`audience`) fails
/// at container freeze — startup, not first request.
public final class FlightSecurityModule: FlightModule {
    /// Authentication runs early so every later middleware and handler sees
    /// the principal. Lower than the default 0 of app middleware.
    public static let middlewareOrder = -100

    private var container: Container?
    private var registeredOIDCValidator = false

    public init() {}

    public func configure(_ container: Container) throws {
        self.container = container

        container.register(PrincipalHolder.self, scope: .scoped) { _ in
            PrincipalHolder()
        }

        // The §3.3 seam: an already-registered validator wins; the generic
        // OIDC implementation is the default, not a mandate.
        // String(reflecting:) matches how the container names bean types.
        let validatorTypeName = String(reflecting: (any TokenValidator).self)
        let hasCustomValidator = container.allRegistrations().contains {
            $0.typeName == validatorTypeName && $0.qualifier == nil
        }
        if !hasCustomValidator {
            registeredOIDCValidator = true
            container.register(OIDCSecurityConfiguration.self, scope: .singleton) { c in
                try OIDCSecurityConfiguration(configuration: c.resolve(Configuration.self))
            }
            container.register((any TokenValidator).self, scope: .singleton) { c in
                OIDCTokenValidator(configuration: try c.resolve(OIDCSecurityConfiguration.self))
            }
        }

        container.registerMiddleware(
            "flight.security.authentication",
            order: Self.middlewareOrder,
            authenticationMiddleware()
        )
    }

    public var service: (any Service)? {
        guard registeredOIDCValidator, let container else { return nil }
        return JWKSMaintenanceService(container: container)
    }
}

/// Keeps the process-wide JWKS cache warm (design §3.2, §6): one fetch at
/// startup so the first request never pays IdP latency, then a refresh per
/// cache-TTL. Fetch failures are logged and retried on the next tick —
/// token validation falls back to lazy fetching (and stale-serving), so an
/// IdP blip never takes the app down.
final class JWKSMaintenanceService: Service {
    private let container: Container
    private let logger = Logger(label: "flight.security.jwks")

    init(container: Container) {
        self.container = container
    }

    func run() async throws {
        guard
            let validator = try? container.resolve((any TokenValidator).self)
                as? OIDCTokenValidator
        else {
            // Custom validator slotted in: nothing to maintain. Park until
            // shutdown — returning early would read as a service failure.
            try? await cancelWhenGracefulShutdown {
                while true {
                    try await Task.sleep(for: .seconds(3600))
                }
            }
            return
        }

        let interval = Duration.seconds(max(validator.keyRefreshInterval, 60))
        do {
            try await cancelWhenGracefulShutdown {
                await self.refresh(validator, context: "pre-warm")
                while !Task.isCancelled {
                    try await Task.sleep(for: interval)
                    await self.refresh(validator, context: "scheduled refresh")
                }
            }
        } catch is CancellationError {
            // Graceful shutdown.
        }
    }

    private func refresh(_ validator: OIDCTokenValidator, context: String) async {
        do {
            try await validator.refreshKeys()
            logger.debug("JWKS \(context) complete")
        } catch {
            logger.warning(
                "JWKS \(context) failed; validation will fetch lazily",
                metadata: ["reason": "\(error)"]
            )
        }
    }
}
