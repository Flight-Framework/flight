import Foundation
import HTTPTypes

/// One `Set-Cookie` value: the name, the value, and the attributes that
/// decide who may read it back and for how long.
///
/// The defaults are the safe ones rather than the permissive ones —
/// `httpOnly` and `sameSite: .lax` are on unless you turn them off. A
/// session cookie that JavaScript can read is one XSS away from being a
/// stolen session, and that is not a default worth making people opt out of.
public struct Cookie: Sendable, Equatable {
    public enum SameSite: String, Sendable {
        case strict = "Strict"
        /// Sent on top-level navigations to this site, not on cross-site
        /// subrequests — the setting a login cookie wants, because a form
        /// post that redirects must still arrive authenticated.
        case lax = "Lax"
        /// Requires `secure`; browsers reject it otherwise.
        case none = "None"
    }

    public var name: String
    public var value: String
    public var path: String?
    public var domain: String?
    /// Lifetime. `nil` makes it a session cookie, dropped when the browser
    /// closes. `.zero` (or a past `expires`) is how a cookie is deleted.
    public var maxAge: Duration?
    public var expires: Date?
    /// HTTPS only. Left to the caller because a development server on
    /// loopback has no TLS, and a cookie that silently never gets set is a
    /// worse failure than one that is explicitly insecure in development.
    public var isSecure: Bool
    /// Unreadable from JavaScript. On by default.
    public var isHTTPOnly: Bool
    public var sameSite: SameSite?

    public init(
        name: String,
        value: String,
        path: String? = "/",
        domain: String? = nil,
        maxAge: Duration? = nil,
        expires: Date? = nil,
        isSecure: Bool = false,
        isHTTPOnly: Bool = true,
        sameSite: SameSite? = .lax
    ) {
        // A name is developer-supplied — a literal, at every call site anyone
        // writes — so a bad one is a programming error and trapping on it
        // finds the bug. `=` would split the pair somewhere the browser
        // decides; `;` would end it entirely.
        precondition(
            !name.isEmpty && !name.contains(where: Cookie.isForbiddenInName),
            """
            Cookie name "\(name)" contains a character that cannot appear in a Set-Cookie \
            name (=, ;, comma, whitespace, or a control character). Set-Cookie has no \
            escaping mechanism, so there is nothing to escape it to.
            """)
        self.name = name
        self.value = value
        self.path = path
        self.domain = domain
        self.maxAge = maxAge
        self.expires = expires
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.sameSite = sameSite
    }

    /// A cookie that deletes the one with this name: empty, already expired.
    /// Path and domain must match what set it, or the browser keeps the
    /// original — the single most common reason a "logout" does not log out.
    public static func expiring(
        _ name: String, path: String? = "/", domain: String? = nil
    ) -> Cookie {
        Cookie(
            name: name, value: "", path: path, domain: domain,
            maxAge: .zero, expires: Date(timeIntervalSince1970: 0))
    }

    /// The `Set-Cookie` field value.
    ///
    /// Structural characters are removed from the value on the way out. A
    /// `;` in a value does not corrupt it — it *forges attributes*, so a
    /// value carrying `; SameSite=None; Secure` used to reach the wire as
    /// exactly that, silently, on a type whose whole framing is safe
    /// defaults. `Set-Cookie` has no escaping mechanism, so there is nothing
    /// to escape them to; percent-encode or base64 a value that needs them,
    /// and decode it yourself on the way back in.
    ///
    /// The name is checked at construction instead: it is always a literal
    /// in practice, so a bad one is a programming error worth finding.
    public var headerValue: String {
        var parts = ["\(name)=\(Cookie.sanitized(value))"]
        if let path { parts.append("Path=\(path)") }
        if let domain { parts.append("Domain=\(domain)") }
        if let maxAge { parts.append("Max-Age=\(maxAge.components.seconds)") }
        if let expires { parts.append("Expires=\(HTTPDate.format(expires))") }
        if isSecure { parts.append("Secure") }
        if isHTTPOnly { parts.append("HttpOnly") }
        if let sameSite { parts.append("SameSite=\(sameSite.rawValue)") }
        return parts.joined(separator: "; ")
    }
}

extension Cookie {
    /// Characters that cannot appear in a `Set-Cookie` name: they would end
    /// the pair, split it, or end the whole field.
    fileprivate static func isForbiddenInName(_ character: Character) -> Bool {
        character == "=" || character == ";" || character == ","
            || character.isWhitespace || character.unicodeScalars.contains { $0.value < 0x21 }
    }

    /// RFC 6265's `cookie-value`, minus everything it excludes: `;` and `,`
    /// (which forge attributes and split the field), whitespace, `\` and
    /// `"` (which the quoted form uses), and control characters.
    fileprivate static func sanitized(_ value: String) -> String {
        String(
            value.filter { character in
                guard let scalar = character.unicodeScalars.first,
                    character.unicodeScalars.count == 1
                else { return true }
                switch scalar {
                case ";", ",", "\\", "\"", " ": return false
                default: return scalar.value > 0x20 && scalar.value != 0x7F
                }
            })
    }
}

extension Request {
    /// The request's cookies, parsed from the single `Cookie` header.
    ///
    /// Duplicate names keep the **first**, which is what browsers send
    /// first for the most specific path — the one a server almost always
    /// means. Malformed pairs are skipped rather than failing the request:
    /// a client's stale junk cookie should not take an endpoint down.
    public var cookies: [String: String] {
        guard let header = headers[.cookie] else { return [:] }
        var found: [String: String] = [:]
        for pair in header.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<equals])
            guard !name.isEmpty, found[name] == nil else { continue }
            found[name] = String(trimmed[trimmed.index(after: equals)...])
        }
        return found
    }

    /// One cookie's value.
    ///
    /// Scans the header for the name rather than going through ``cookies``,
    /// which builds a whole dictionary for one lookup — a handler reading
    /// three cookies parsed the header three times and threw away three
    /// dictionaries. Same first-wins rule.
    public func cookie(_ name: String) -> String? {
        guard let header = headers[.cookie] else { return nil }
        for pair in header.split(separator: ";") {
            var trimmed = pair
            while let first = trimmed.first, first.isWhitespace { trimmed.removeFirst() }
            while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
            guard let separator = trimmed.firstIndex(of: "="), trimmed[..<separator] == name
            else { continue }
            return String(trimmed[trimmed.index(after: separator)...])
        }
        return nil
    }
}

extension Response {
    /// Adds a `Set-Cookie` header, keeping any already present — several
    /// cookies means several headers, never one joined value.
    public func settingCookie(_ cookie: Cookie) -> Response {
        appendingHeader(.setCookie, cookie.headerValue)
    }

    /// Deletes a cookie by name (see ``Cookie/expiring(_:path:domain:)``).
    public func expiringCookie(
        _ name: String, path: String? = "/", domain: String? = nil
    ) -> Response {
        settingCookie(.expiring(name, path: path, domain: domain))
    }

    /// Appends a header rather than replacing it. `settingHeader` replaces,
    /// which is right for `Content-Type` and wrong for `Set-Cookie`.
    public func appendingHeader(_ name: HTTPField.Name, _ value: String) -> Response {
        switch self {
        case .fixed(let status, var headers, let body):
            headers.append(HTTPField(name: name, value: value))
            return .fixed(status: status, headers: headers, body: body)
        case .streaming(let status, var headers, let body):
            headers.append(HTTPField(name: name, value: value))
            return .streaming(status: status, headers: headers, body: body)
        case .file(let file):
            var headers = file.headers
            headers.append(HTTPField(name: name, value: value))
            return .file(
                FileResponse(
                    status: file.status, headers: headers, source: file.source,
                    range: file.range, chunkSize: file.chunkSize))
        case .upgrade:
            return self
        }
    }

    /// A `303 See Other` — the redirect that turns a form POST into a GET,
    /// so a reload does not re-submit. The one a login form wants.
    public static func seeOther(_ location: String) -> Response {
        var headers: HTTPFields = [:]
        headers[.location] = location
        return .fixed(status: .seeOther, headers: headers, body: Data())
    }
}
