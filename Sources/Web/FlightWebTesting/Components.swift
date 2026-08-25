import FlightCore

/// Registers named components into a test container, without the application
/// module that would normally register them.
///
///     let container = try TestContainer.build {
///         Components(UserController.self, UserService.self)
///         FakeRepository(users: [ada])
///     }
///
/// This is the middle of three ways to test. Calling a handler directly is
/// the smallest; booting the application's real modules and overriding one
/// seam is the largest and the only one that checks the wiring. This sits
/// between them: the real controller, the real routing, the real dependency
/// injection, and nothing else — so a suite is not coupled to modules it does
/// not exercise.
///
/// It works through `_flightRegister`, the same registration thunk the
/// generated `flightRegisterAll` calls in production, so a component reaches
/// the container exactly as it would in the running application.
public struct Components: FlightModule {
    private let types: [any _FlightRegistrable.Type]

    /// Required by `FlightModule`; registers nothing.
    public init() { self.types = [] }

    public init(_ types: any _FlightRegistrable.Type...) {
        self.types = types
    }

    public init(_ types: [any _FlightRegistrable.Type]) {
        self.types = types
    }

    public func configure(_ container: Container) throws {
        for type in types {
            try type._flightRegister(container)
        }
    }
}
