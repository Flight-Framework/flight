import Foundation
import JWTKit
import Logging

/// The generic OIDC token validator.
///
/// JWTKit owns the cryptographic core — signature verification, JWS
/// structure, JWK parsing. This type owns the orchestration:
/// JWKS fetching and rotation via its internal `JWKSCache`, and the claim policy —
/// issuer must match, audience must include this application, `exp`/`nbf`
/// enforced with configurable clock-skew leeway, `sub` required.
///
/// One instance serves all OIDC-compliant providers; Descope, Keycloak,
/// Auth0, Okta, and Entra are configuration, not code.
public final class OIDCTokenValidator: TokenValidator {
    private let configuration: OIDCSecurityConfiguration
    private let cache: JWKSCache
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - configuration: Issuer/audience/claim policy.
    ///   - jwksSource: Where keys come from. Defaults to HTTPS fetching with
    ///     OIDC discovery; injectable for tests and non-standard setups.
    ///   - now: Clock, injectable for tests.
    public init(
        configuration: OIDCSecurityConfiguration,
        jwksSource: (any JWKSSource)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        let source =
            jwksSource
            ?? HTTPJWKSSource(
                issuer: configuration.issuer,
                jwksURL: configuration.jwksURL,
                transportPolicy: configuration.jwksTransport)
        self.cache = JWKSCache(
            source: source,
            ttl: configuration.jwksCacheTTL,
            refreshCooldown: configuration.jwksRefreshCooldown,
            maxStaleAge: configuration.jwksMaxStaleAge,
            now: now
        )
        self.now = now
    }

    public func validate(_ token: String) async throws -> Principal {
        // 1. Structural header parse (no cryptography): the `kid` decides
        //    whether this token warrants a JWKS refresh.
        let header = try TokenHeader.parse(token)

        // Defense in depth: JWTKit also rejects these, but screen the
        // obviously hostile before touching the key set.
        if let algorithm = header.algorithm, algorithm.lowercased() == "none" {
            throw TokenValidationError(
                kind: .unsupportedAlgorithm, reason: "alg \"none\" is not acceptable"
            )
        }

        // 2. Current keys; an unrecognized `kid` triggers one (cooldown-
        //    gated) refresh — the key-rotation path.
        var keys = try await cache.snapshot()
        if let kid = header.keyID, !keys.keyIDs.contains(kid) {
            keys = try await cache.snapshot(.unknownKeyID)
            guard keys.keyIDs.contains(kid) else {
                throw TokenValidationError(
                    kind: .unknownKeyID,
                    reason: """
                        token kid "\(kid)" is not in the issuer's JWKS (a refresh was \
                        attempted unless one had been within the cooldown window)
                        """
                )
            }
        }

        // 3. Signature verification and payload decoding — JWTKit.
        //    Tokens without a `kid` are tried against every key rather than
        //    trusting JWTKit's silent default-key fallback.
        let claims: RawClaims
        do {
            claims = try await keys.collection.verify(
                token, as: RawClaims.self, iteratingKeys: header.keyID == nil
            )
        } catch let error as JWTError {
            throw Self.mapJWTError(error)
        }

        // 4. Claim policy.
        try enforcePolicy(on: claims)

        // 5. The policy passed; surface what the token already carries.
        return makePrincipal(from: claims)
    }

    /// Forces a JWKS fetch. Used by the maintenance service to pre-warm at
    /// startup and keep keys fresh.
    ///
    /// Throws only when there is nothing left to serve. A fetch that fails
    /// while cached keys are still inside their stale window is *not* an
    /// error here — the cache logs it and keeps serving — so a successful
    /// return means "keys are usable", not "the IdP answered".
    public func refreshKeys() async throws {
        _ = try await cache.snapshot(.force)
    }

    /// The configured cache TTL, in seconds — the maintenance service's
    /// natural refresh cadence.
    public var keyRefreshInterval: TimeInterval {
        configuration.jwksCacheTTL
    }

    // MARK: - Claim policy

    private func enforcePolicy(on claims: RawClaims) throws(TokenValidationError) {
        let moment = now()
        let leeway = configuration.clockSkewLeeway

        // Issuer: must match the configured IdP exactly.
        guard let issuer = claims.values["iss"]?.stringValue else {
            throw TokenValidationError(kind: .missingRequiredClaim, reason: "iss claim is missing")
        }
        guard issuer == configuration.issuer else {
            throw TokenValidationError(
                kind: .issuerMismatch,
                reason: "token issuer \"\(issuer)\" does not match configured issuer \"\(configuration.issuer)\""
            )
        }

        // Audience: must include this application. RFC 7519 allows a
        // single string or an array of strings.
        switch claims.values["aud"] {
        case .string(let audience):
            guard audience == configuration.audience else {
                throw TokenValidationError(
                    kind: .audienceMismatch,
                    reason: "token audience \"\(audience)\" does not include \"\(configuration.audience)\""
                )
            }
        case .array(let audiences):
            guard audiences.contains(.string(configuration.audience)) else {
                throw TokenValidationError(
                    kind: .audienceMismatch,
                    reason: "token audiences do not include \"\(configuration.audience)\""
                )
            }
        default:
            throw TokenValidationError(
                kind: .audienceMismatch, reason: "aud claim is missing or not a string/array"
            )
        }

        // Expiry: required — a token that cannot expire is not acceptable.
        guard let exp = claims.values["exp"]?.numericDateValue else {
            throw TokenValidationError(
                kind: .missingRequiredClaim, reason: "exp claim is missing or not a NumericDate"
            )
        }
        let expiry = Date(timeIntervalSince1970: exp)
        guard moment < expiry.addingTimeInterval(leeway) else {
            throw TokenValidationError(
                kind: .expired,
                reason: "token expired at \(expiry) (leeway \(Int(leeway))s)"
            )
        }

        // Not-before: enforced when present.
        if let nbf = claims.values["nbf"]?.numericDateValue {
            let notBefore = Date(timeIntervalSince1970: nbf)
            guard moment >= notBefore.addingTimeInterval(-leeway) else {
                throw TokenValidationError(
                    kind: .notYetValid,
                    reason: "token not valid before \(notBefore) (leeway \(Int(leeway))s)"
                )
            }
        }

        // Subject: without a stable subject there is no Principal.
        guard let subject = claims.values["sub"]?.stringValue, !subject.isEmpty else {
            throw TokenValidationError(
                kind: .missingRequiredClaim, reason: "sub claim is missing or empty"
            )
        }
    }

    // MARK: - Principal assembly

    /// Claims consumed by validation and surfaced as dedicated `Principal`
    /// fields; everything else lands in `Principal.claims`.
    ///
    /// `iat` is deliberately absent: nothing here validates it, and stripping
    /// a claim the application can no longer see buys nothing. An app that
    /// wants issued-at — to age a session, say — finds it in
    /// ``Principal/claims``.
    private static let consumedClaims: Set<String> = ["iss", "sub", "aud", "exp", "nbf"]

    private func makePrincipal(from claims: RawClaims) -> Principal {
        var remaining: [String: any Sendable] = [:]
        for (name, value) in claims.values where !Self.consumedClaims.contains(name) {
            if let bridged = value.anySendable {
                remaining[name] = bridged
            }
        }
        return Principal(
            subject: claims.values["sub"]?.stringValue ?? "",
            issuer: configuration.issuer,
            roles: claims.stringSet(atAnyOf: configuration.rolesClaims),
            scopes: claims.stringSet(atAnyOf: configuration.scopesClaims, splittingStringsOn: " "),
            claims: remaining
        )
    }

    // MARK: - Error mapping

    private static func mapJWTError(_ error: JWTError) -> TokenValidationError {
        switch error.errorType {
        case .signatureVerificationFailed:
            TokenValidationError(kind: .signatureInvalid, reason: "signature verification failed")
        case .malformedToken:
            TokenValidationError(kind: .malformedToken, reason: "JWTKit: \(error)")
        case .unknownKID, .missingKIDHeader, .noKeyProvided:
            TokenValidationError(kind: .unknownKeyID, reason: "JWTKit: \(error)")
        case .unsupportedAlgorithm, .signingAlgorithmFailure:
            TokenValidationError(kind: .unsupportedAlgorithm, reason: "JWTKit: \(error)")
        default:
            TokenValidationError(kind: .signatureInvalid, reason: "JWTKit: \(error)")
        }
    }
}
