import FlightCore
import FlightWeb
import Testing

@testable import FlightSecurityCore

/// The security module holds its middleware as values — the composition root
/// hands them to `FlightWebModule` alongside every other module's. There is
/// no global registration to gate: an app that links the package but composes
/// no security module simply has no security middleware, and `Authentication`
/// cannot be built without a validator, so "linked but unwired" is not a state
/// the type system lets you reach.
@Suite("registration gating")
struct RegistrationGatingTests {

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
