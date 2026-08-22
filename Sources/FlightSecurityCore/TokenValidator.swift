/// The seam for turning an externally issued token into a ``Principal``
/// (design §3.2, §3.3).
///
/// Flight Security Core ships one generic implementation,
/// ``OIDCTokenValidator`` — OIDC-compliant providers (Descope, Keycloak,
/// Auth0, Okta, Entra, …) are *configuration* of it, not separate
/// implementations. Supply your own conformance only for a genuinely
/// non-standard provider.
public protocol TokenValidator: Sendable {
    /// Verifies the token's signature (via JWTKit) AND enforces issuer,
    /// audience, expiry, and clock-skew policy. Returns a ``Principal`` or
    /// throws a precise error.
    ///
    /// Error hygiene (design §3.2): thrown errors carry detail for the
    /// *internal* log only. The authentication middleware never lets them
    /// reach the wire; if application code rethrows one from a handler, it
    /// renders as an opaque 500, not as token detail.
    func validate(_ token: String) async throws -> Principal
}

/// Why a token failed validation. Internal-log detail; never client-facing.
public struct TokenValidationError: Error, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable, Equatable {
        /// Not a structurally valid JWT (segments, base64url, JSON).
        case malformedToken = "malformed_token"
        /// Signature verification failed.
        case signatureInvalid = "signature_invalid"
        /// `exp` is in the past (beyond the configured leeway).
        case expired
        /// `nbf` is in the future (beyond the configured leeway).
        case notYetValid = "not_yet_valid"
        /// `iss` does not match the configured issuer.
        case issuerMismatch = "issuer_mismatch"
        /// `aud` is missing or does not include the configured audience.
        case audienceMismatch = "audience_mismatch"
        /// A claim the policy requires (`sub`, `exp`, …) is missing or empty.
        case missingRequiredClaim = "missing_required_claim"
        /// The token's `kid` is not in the JWKS, even after a refresh.
        case unknownKeyID = "unknown_key_id"
        /// The token's `alg` is not acceptable (e.g. `none`).
        case unsupportedAlgorithm = "unsupported_algorithm"
        /// The JWKS could not be fetched and no cached keys exist.
        case keySourceUnavailable = "key_source_unavailable"
    }

    public let kind: Kind
    /// Human-readable detail for internal logs. Never contains the token.
    /// Sanitized at construction: reasons can embed values from the
    /// *unverified* token header (e.g. `kid`), so control characters are
    /// replaced and the length is capped — one garbage token must not be
    /// able to forge log lines.
    public let reason: String

    public init(kind: Kind, reason: String) {
        self.kind = kind
        self.reason = Self.sanitizedForLog(reason)
    }

    public var description: String {
        "token validation failed (\(kind.rawValue)): \(reason)"
    }

    private static let maxReasonLength = 256

    static func sanitizedForLog(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars.prefix(maxReasonLength) {
            scalars.append(scalar.properties.generalCategory == .control ? "\u{FFFD}" : scalar)
        }
        var result = String(scalars)
        if raw.unicodeScalars.count > maxReasonLength {
            result += "…"
        }
        return result
    }
}
