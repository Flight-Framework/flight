// Internal storage model shared by Container and Scope.
//
// The public contract (§2.1) deliberately does not expose these. The design
// doc reserves the right for storage to become a handle-indexed arena; the
// dictionary form here is the measurable baseline. Post-freeze, `Frozen` is
// immutable, so swapping the representation later is invisible to callers.

/// Composite lookup key: type identity plus optional qualifier (§5.4 fixture 6:
/// two components of the same type are disambiguated by an explicit qualifier).
struct ComponentKey: Hashable, Sendable, CustomStringConvertible {
    let type: ObjectIdentifier
    let typeName: String
    let qualifier: String?

    init<T>(_ type: T.Type, qualifier: String?) {
        self.type = ObjectIdentifier(type)
        self.typeName = String(reflecting: type)
        self.qualifier = qualifier
    }

    // typeName is derived from `type`; exclude it from identity so that
    // hashing stays cheap and equality can't drift from ObjectIdentifier.
    static func == (lhs: ComponentKey, rhs: ComponentKey) -> Bool {
        lhs.type == rhs.type && lhs.qualifier == rhs.qualifier
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(type)
        hasher.combine(qualifier)
    }

    var description: String {
        if let qualifier { return "\(typeName) (qualifier: \"\(qualifier)\")" }
        return typeName
    }
}

/// One registered component. `factory` is type-erased; `Container.resolve` restores
/// the static type at the single generic entry point.
struct Registration: @unchecked Sendable {
    // @unchecked: `Any`-producing factories and the descriptor are only
    // touched (a) single-threaded pre-freeze, or (b) read-only post-freeze.
    let key: ComponentKey
    let scope: Lifetime
    let descriptor: ComponentDescriptor
    let factory: (Container) throws -> Any
}

/// The immutable, post-`freeze()` view. Built exactly once; never mutated.
/// This immutability is what makes lock-free `resolve` sound (§2.1, §8).
struct FrozenStorage: @unchecked Sendable {
    let registrations: [ComponentKey: Registration]
    let order: [ComponentKey]
    /// Every `.singleton` component, eagerly constructed during `freeze()` in
    /// registration order. Eager construction is a deliberate implementation
    /// choice (mirrors Spring's default): it is precisely what removes any
    /// need for synchronization on the post-freeze singleton path.
    let singletons: [ComponentKey: Any]
}
