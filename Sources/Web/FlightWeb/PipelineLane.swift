/// The name of a middleware lane — what `MiddlewareRegistration.lane("name", [...])`
/// declares and what a controller or route names in `pipelines:`.
///
/// This is a named type rather than a bare `String` for one reason that is
/// not cosmetic: the `@Controller` macro can only see *source text*, so
/// telling a security lane from a metrics lane means recognizing a canonical
/// spelling. With arbitrary strings there is nothing to recognize, and the
/// macro cannot warn when a route quietly drops the authentication its
/// controller declared. ``authenticated`` and ``authentication`` are those
/// canonical spellings.
///
/// It is `ExpressibleByStringLiteral`, so an application's own lanes stay as
/// short as they ever were:
///
/// ```swift
/// @Controller("/admin", pipelines: [.authenticated, "audit"])
/// ```
public struct PipelineLane: Hashable, Sendable, ExpressibleByStringLiteral,
    CustomStringConvertible, Codable
{
    public let name: String

    public init(_ name: String) { self.name = name }
    public init(stringLiteral value: StringLiteralType) { self.init(value) }

    public var description: String { name }

    // MARK: - Canonical lanes

    /// The lane every route runs through unless it names others — the one
    /// `MiddlewareRegistration.lane(.default, [...])` feeds. Spellable so a
    /// route can *combine* it with extras: `pipelines: [.default, "admin"]` means
    /// "everything the app normally does, then the admin stack".
    public static let `default` = PipelineLane("default")

    /// Establishes identity and rejects nobody: runs `Authentication`, which
    /// populates the principal when credentials are present and leaves the
    /// request anonymous when they are not. The lane for a route that serves
    /// both signed-in and anonymous callers differently.
    public static let authentication = PipelineLane("authentication")

    /// Identity required: `Authentication` followed by
    /// `RequireAuthentication`, which rejects an anonymous request before it
    /// reaches the handler.
    public static let authenticated = PipelineLane("authenticated")

    /// Explicitly no lanes — and the acknowledgment that this is deliberate.
    ///
    /// A route under an authenticated controller that narrows to something
    /// without a security lane draws a build warning, because silently
    /// dropping authentication is the mistake worth catching. Naming
    /// ``public`` *is* the acknowledgment, so the intent lives in the
    /// declaration rather than in a comment beside it — and "every
    /// deliberately-public route under an authenticated controller" becomes
    /// greppable.
    ///
    /// The framework declares it as an empty lane, so it needs no
    /// `MiddlewareRegistration.lane("public", [])` of its own.
    public static let `public` = PipelineLane("public")

    /// The lanes whose absence is worth a warning — the ones that carry
    /// identity. Authorization is deliberately not here: `requireRole` and
    /// `requireScope` depend on a *value*, not a lane, and live in handler
    /// bodies where no lane declaration can describe them.
    static let securityLanes: Set<PipelineLane> = [.authentication, .authenticated]
}
