/// The identity a `Socket` carries (§5), as Channels needs to see it.
///
/// Design delta, recorded in README: the design doc names Flight Security
/// Core's `Principal` here, but Security Core is not yet built — and
/// Channels' actual requirement is only "the join gate can read who this
/// is". So Channels owns the *seam*: a minimal protocol with exactly the
/// two members the design's own join example uses (`subject`,
/// `hasRole(_:)`). When flight-security-core ships, its `Principal`
/// conforms retroactively and the authentication middleware's task-local
/// feeds `registerChannelSocket`'s `authenticate` closure — no Channels
/// change required. Same "seam, not engine" posture as §5.
public protocol ChannelPrincipal: Sendable {
    /// The stable identity — a user ID, a service name.
    var subject: String { get }

    func hasRole(_ role: String) -> Bool
}

extension ChannelPrincipal {
    /// Roles are optional richness; a bare subject-only principal is valid.
    public func hasRole(_ role: String) -> Bool { false }
}

/// The simplest useful principal — enough for tests, examples, and apps
/// whose upgrade-time authentication produces (subject, roles) directly.
public struct BasicPrincipal: ChannelPrincipal, Equatable {
    public let subject: String
    public let roles: Set<String>

    public init(subject: String, roles: Set<String> = []) {
        self.subject = subject
        self.roles = roles
    }

    public func hasRole(_ role: String) -> Bool {
        roles.contains(role)
    }
}
