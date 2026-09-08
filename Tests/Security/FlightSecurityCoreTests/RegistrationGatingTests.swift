import FlightCore
import FlightWeb
import Testing

@testable import FlightSecurityCore

/// Registration gating: which side registers the security middleware, and
/// what happens to an app that links this package without including a
/// security module.
///
/// `Authentication` injects `(any TokenValidator)`, which only a security
/// module provides, and `Container.freeze()` builds every singleton eagerly.
/// So while the generated `flightRegisterAll` registered it — which it did,
/// because `@Middleware` is a scanned attribute — merely *linking*
/// FlightSecurityCore was enough to fail the freeze and stop the app booting.
/// The `flight:module-registered` marker is what keeps the scan's hands off
/// it; these pin both halves of that.
@Suite("registration gating")
struct RegistrationGatingTests {

    /// The generated file no longer emits these, so an app that links the
    /// package and includes no security module registers nothing and boots.
    @Test("an app that links the package without a security module boots")
    func linkingWithoutTheModuleBoots() throws {
        let container = Container()
        try container.freeze()
        // Nothing registered it, so nothing to resolve — and, crucially, no
        // eager singleton failed on the way here.
        #expect(throws: (any Error).self) {
            _ = try container.resolve(Authentication.self)
        }
    }

    /// What the scan *would* have done, kept as the statement of why the
    /// marker exists: registering it without a validator still fails the
    /// freeze. If this ever stops throwing, the hazard is gone and the
    /// marker can be revisited.
    @Test("registering it without a validator still fails the freeze")
    func registeringWithoutAValidatorStillFails() throws {
        let container = Container()
        try Authentication._flightRegister(container)
        #expect(throws: (any Error).self) {
            try container.freeze()
        }
    }

    /// The module registers both, so an app that includes it resolves them.
    @Test("the security module declares both middleware types")
    func moduleRegistersBothMiddleware() throws {
        // They used to be container registrations resolved per request. The
        // module holds the instances now, so this reads what it declares.
        let module = FlightSecurityModule(validator: StubValidator(principalsByToken: [:]))
        let names = Set(module.middleware.map(\.name))
        #expect(names.contains { $0.hasSuffix(".Authentication") })
        #expect(names.contains { $0.hasSuffix(".RequireAuthentication") })
    }
}
