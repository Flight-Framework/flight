import Foundation
import Testing

@testable import FlightSecurityCore

@Suite("OIDC token validation — the one security-critical component")
struct OIDCValidatorTests {
    let clock = TestClock()
    let identity = TestIdentity(kid: "key-1")

    private func makeValidator(
        source: InMemoryJWKSSource? = nil,
        issuer: String = testIssuer,
        audience: String = testAudience,
        jwksCacheTTL: TimeInterval = 3600,
        clockSkewLeeway: TimeInterval = 60,
        jwksRefreshCooldown: TimeInterval = 30,
        jwksMaxStaleAge: TimeInterval = 6 * 60 * 60,
        rolesClaims: [String] = ["roles", "groups", "realm_access.roles"],
        scopesClaims: [String] = ["scope", "scp"]
    ) throws -> (OIDCTokenValidator, InMemoryJWKSSource) {
        let source = try source ?? InMemoryJWKSSource(json: jwksJSON([identity]))
        let configuration = try OIDCSecurityConfiguration(
            issuer: issuer,
            audience: audience,
            jwksCacheTTL: jwksCacheTTL,
            clockSkewLeeway: clockSkewLeeway,
            jwksRefreshCooldown: jwksRefreshCooldown,
            jwksMaxStaleAge: jwksMaxStaleAge,
            rolesClaims: rolesClaims,
            scopesClaims: scopesClaims
        )
        let validator = OIDCTokenValidator(
            configuration: configuration, jwksSource: source, now: clock.nowProvider
        )
        return (validator, source)
    }

    private func expectValidationError(
        _ kind: TokenValidationError.Kind,
        _ body: () async throws -> Principal
    ) async {
        do {
            _ = try await body()
            Issue.record("expected \(kind.rawValue) but validation succeeded")
        } catch let error as TokenValidationError {
            #expect(error.kind == kind)
        } catch {
            Issue.record("expected TokenValidationError, got \(error)")
        }
    }

    // MARK: Happy path

    @Test("a valid token produces a fully populated Principal")
    func validToken() async throws {
        let (validator, _) = try makeValidator()
        let token = try await identity.sign(
            standardClaims(
                now: clock.now,
                extra: [
                    "realm_access": .object(["roles": .array([.string("admin")])]),
                    "groups": .array([.string("staff")]),
                    "scope": .string("read write"),
                    "email": .string("user@example.com"),
                ]
            )
        )

        let principal = try await validator.validate(token)
        #expect(principal.subject == "user-123")
        #expect(principal.issuer == testIssuer)
        #expect(principal.roles == ["admin", "staff"])
        #expect(principal.scopes == ["read", "write"])
        #expect(principal.claim("email", as: String.self) == "user@example.com")
    }

    @Test("claims consumed by validation do not reappear in Principal.claims")
    func consumedClaims() async throws {
        let (validator, _) = try makeValidator()
        let token = try await identity.sign(standardClaims(now: clock.now))
        let principal = try await validator.validate(token)
        for consumed in ["iss", "sub", "aud", "exp", "nbf"] {
            #expect(principal.claims[consumed] == nil, "\(consumed) should be consumed")
        }
        // `iat` is not consumed: nothing validates it, so stripping it only
        // took issued-at away from applications that wanted to age a session
        // by it. It stays where an app can read it.
        #expect(principal.claims["iat"] != nil, "iat is surfaced, not consumed")
    }

    @Test("audience may be an array that includes this application (RFC 7519)")
    func audienceArray() async throws {
        let (validator, _) = try makeValidator()
        let token = try await identity.sign(
            standardClaims(
                now: clock.now,
                audience: .array([.string("other-app"), .string(testAudience)])
            )
        )
        _ = try await validator.validate(token)
    }

    @Test("a token without a kid verifies against the key set (single-key IdP)")
    func tokenWithoutKid() async throws {
        let (validator, _) = try makeValidator()
        let token = try await identity.signWithoutKid(standardClaims(now: clock.now))
        let principal = try await validator.validate(token)
        #expect(principal.subject == "user-123")
    }

    @Test("a token without a kid signed by an untrusted key is rejected")
    func tokenWithoutKidUntrustedKey() async throws {
        let (validator, _) = try makeValidator()
        let stranger = TestIdentity(kid: "irrelevant")
        let token = try await stranger.signWithoutKid(standardClaims(now: clock.now))
        await expectValidationError(.signatureInvalid) { try await validator.validate(token) }
    }

    @Test("custom roles/scopes claim configuration is honored")
    func customClaimNames() async throws {
        let (validator, _) = try makeValidator(
            rolesClaims: ["https://example.com/roles"], scopesClaims: ["permissions"]
        )
        let token = try await identity.sign(
            standardClaims(
                now: clock.now,
                extra: [
                    "https://example.com/roles": .array([.string("admin")]),
                    "permissions": .array([.string("read:all")]),
                    "roles": .array([.string("ignored")]),
                ]
            )
        )
        let principal = try await validator.validate(token)
        #expect(principal.roles == ["admin"])
        #expect(principal.scopes == ["read:all"])
    }

    // MARK: Claim policy

    @Test("wrong issuer is rejected")
    func issuerMismatch() async throws {
        let (validator, _) = try makeValidator()
        let token = try await identity.sign(
            standardClaims(now: clock.now, issuer: "https://evil.example.com")
        )
        await expectValidationError(.issuerMismatch) { try await validator.validate(token) }
    }

    @Test("missing issuer is rejected")
    func missingIssuer() async throws {
        let (validator, _) = try makeValidator()
        let token = try await identity.sign(standardClaims(now: clock.now, issuer: nil))
        await expectValidationError(.missingRequiredClaim) { try await validator.validate(token) }
    }

    @Test("wrong audience is rejected — string and array forms")
    func audienceMismatch() async throws {
        let (validator, _) = try makeValidator()
        let stringToken = try await identity.sign(
            standardClaims(now: clock.now, audience: .string("someone-else"))
        )
        await expectValidationError(.audienceMismatch) { try await validator.validate(stringToken) }

        let arrayToken = try await identity.sign(
            standardClaims(now: clock.now, audience: .array([.string("a"), .string("b")]))
        )
        await expectValidationError(.audienceMismatch) { try await validator.validate(arrayToken) }
    }

    @Test("missing audience is rejected — accepting any audience is a vulnerability")
    func missingAudience() async throws {
        let (validator, _) = try makeValidator()
        let token = try await identity.sign(standardClaims(now: clock.now, audience: nil))
        await expectValidationError(.audienceMismatch) { try await validator.validate(token) }
    }

    @Test("an expired token is rejected; within leeway it is accepted")
    func expiry() async throws {
        let (validator, _) = try makeValidator(clockSkewLeeway: 60)

        let longExpired = try await identity.sign(standardClaims(now: clock.now, expiresIn: -120))
        await expectValidationError(.expired) { try await validator.validate(longExpired) }

        let justExpired = try await identity.sign(standardClaims(now: clock.now, expiresIn: -30))
        _ = try await validator.validate(justExpired)
    }

    @Test("a token with no exp is rejected — tokens must expire")
    func missingExpiry() async throws {
        let (validator, _) = try makeValidator()
        var claims = standardClaims(now: clock.now)
        claims["exp"] = nil
        let token = try await identity.sign(claims)
        await expectValidationError(.missingRequiredClaim) { try await validator.validate(token) }
    }

    @Test("nbf in the future is rejected; within leeway it is accepted")
    func notBefore() async throws {
        let (validator, _) = try makeValidator(clockSkewLeeway: 60)

        let farFuture = try await identity.sign(
            standardClaims(
                now: clock.now,
                extra: ["nbf": .double(clock.now.timeIntervalSince1970 + 300)]
            )
        )
        await expectValidationError(.notYetValid) { try await validator.validate(farFuture) }

        let nearFuture = try await identity.sign(
            standardClaims(
                now: clock.now,
                extra: ["nbf": .double(clock.now.timeIntervalSince1970 + 30)]
            )
        )
        _ = try await validator.validate(nearFuture)
    }

    @Test("a token without a subject cannot become a Principal")
    func missingSubject() async throws {
        let (validator, _) = try makeValidator()
        let token = try await identity.sign(standardClaims(now: clock.now, subject: nil))
        await expectValidationError(.missingRequiredClaim) { try await validator.validate(token) }
    }

    // MARK: Signature and structure (delegated to JWTKit)

    @Test("a token signed by the wrong key under a known kid is rejected")
    func wrongKey() async throws {
        let (validator, _) = try makeValidator()
        let imposter = TestIdentity(kid: "imposter")
        let token = try await imposter.sign(
            standardClaims(now: clock.now), forgingKid: identity.kid
        )
        await expectValidationError(.signatureInvalid) { try await validator.validate(token) }
    }

    @Test("a tampered payload is rejected")
    func tamperedPayload() async throws {
        let (validator, _) = try makeValidator()
        let token = try await identity.sign(standardClaims(now: clock.now))
        // Splice in a legitimately-encoded payload carrying an escalated
        // role; the original signature no longer covers it.
        let escalated = try await identity.sign(
            standardClaims(now: clock.now, extra: ["roles": .array([.string("admin")])])
        )
        let tokenSegments = token.split(separator: ".")
        let escalatedSegments = escalated.split(separator: ".")
        let tampered = [tokenSegments[0], escalatedSegments[1], tokenSegments[2]]
            .joined(separator: ".")
        await expectValidationError(.signatureInvalid) { try await validator.validate(tampered) }
    }

    @Test("structurally malformed tokens are rejected as malformed")
    func malformedTokens() async throws {
        let (validator, _) = try makeValidator()
        for garbage in ["", "garbage", "a.b", "a.b.c.d", "!!!.###.$$$"] {
            await expectValidationError(.malformedToken) { try await validator.validate(garbage) }
        }
        // Valid base64url header that is not JSON.
        let notJSON = "bm90LWpzb24.e30.c2ln"
        await expectValidationError(.malformedToken) { try await validator.validate(notJSON) }
    }

    @Test("alg \"none\" is rejected before any key work")
    func algNone() async throws {
        let (validator, source) = try makeValidator()
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let payload = Data(#"{"sub":"u1"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        await expectValidationError(.unsupportedAlgorithm) {
            try await validator.validate("\(header).\(payload).")
        }
        #expect(source.fetchCount == 0, "rejected before touching the key source")
    }

    // MARK: JWKS orchestration

    @Test("keys are fetched once and cached across validations")
    func cachesKeys() async throws {
        let (validator, source) = try makeValidator()
        let token = try await identity.sign(standardClaims(now: clock.now))
        _ = try await validator.validate(token)
        _ = try await validator.validate(token)
        _ = try await validator.validate(token)
        #expect(source.fetchCount == 1)
    }

    @Test("cache TTL expiry triggers a refetch")
    func ttlRefetch() async throws {
        let (validator, source) = try makeValidator(jwksCacheTTL: 300)
        let token = try await identity.sign(standardClaims(now: clock.now))
        _ = try await validator.validate(token)
        #expect(source.fetchCount == 1)

        clock.advance(by: 200)
        _ = try await validator.validate(token)
        #expect(source.fetchCount == 1, "within TTL: no refetch")

        clock.advance(by: 200)
        _ = try await validator.validate(token)
        #expect(source.fetchCount == 2, "past TTL: revalidating refetch")
    }

    @Test("an unrecognized kid triggers a refresh — the key-rotation path")
    func rotationRefresh() async throws {
        let (validator, source) = try makeValidator()
        let oldToken = try await identity.sign(standardClaims(now: clock.now))
        _ = try await validator.validate(oldToken)
        #expect(source.fetchCount == 1)

        // The IdP rotates (later — past the anti-hammer cooldown): publishes
        // key-2, starts signing with it.
        clock.advance(by: 60)
        let rotated = TestIdentity(kid: "key-2")
        try source.setKeys(json: jwksJSON([identity, rotated]))
        let newToken = try await rotated.sign(standardClaims(now: clock.now))

        let principal = try await validator.validate(newToken)
        #expect(principal.subject == "user-123")
        #expect(source.fetchCount == 2, "unknown kid forced exactly one refresh")
    }

    @Test("a kid that stays unknown after refresh is rejected")
    func unknownKidAfterRefresh() async throws {
        let (validator, source) = try makeValidator()
        let valid = try await identity.sign(standardClaims(now: clock.now))
        _ = try await validator.validate(valid)  // initial fetch
        clock.advance(by: 60)  // past the anti-hammer cooldown

        let stranger = TestIdentity(kid: "not-published")
        let token = try await stranger.sign(standardClaims(now: clock.now))
        await expectValidationError(.unknownKeyID) { try await validator.validate(token) }
        #expect(source.fetchCount == 2, "initial fetch + one rotation-triggered refresh")
    }

    @Test("unknown-kid refreshes are cooldown-limited — garbage tokens cannot hammer the IdP")
    func refreshCooldown() async throws {
        let (validator, source) = try makeValidator(jwksRefreshCooldown: 30)
        let valid = try await identity.sign(standardClaims(now: clock.now))
        _ = try await validator.validate(valid)

        let stranger = TestIdentity(kid: "not-published")
        let strange = try await stranger.sign(standardClaims(now: clock.now))

        clock.advance(by: 31)  // first unknown-kid refresh is allowed
        await expectValidationError(.unknownKeyID) { try await validator.validate(strange) }
        let fetchesAfterFirst = source.fetchCount

        for _ in 0..<5 {
            await expectValidationError(.unknownKeyID) { try await validator.validate(strange) }
        }
        #expect(source.fetchCount == fetchesAfterFirst, "cooldown suppressed further fetches")

        clock.advance(by: 31)
        await expectValidationError(.unknownKeyID) { try await validator.validate(strange) }
        #expect(source.fetchCount == fetchesAfterFirst + 1, "cooldown elapsed: one more attempt")
    }

    @Test("a JWKS outage after a successful fetch serves cached keys (stale-serving)")
    func staleServing() async throws {
        let (validator, source) = try makeValidator(jwksCacheTTL: 300)
        let token = try await identity.sign(standardClaims(now: clock.now))
        _ = try await validator.validate(token)

        source.setError(JWKSSourceError(reason: "IdP down"))
        clock.advance(by: 400)  // TTL elapsed; refresh will fail
        let principal = try await validator.validate(token)
        #expect(principal.subject == "user-123", "stale keys still validate")
    }

    @Test("stale-serving is bounded — a long outage stops honoring old keys")
    func staleServingIsBounded() async throws {
        // Serving cached keys through an outage was unbounded: an IdP that
        // stayed down kept its last key set authoritative forever, so a
        // revoked key went on verifying tokens for the whole outage — exactly
        // the window revocation exists to close.
        let (validator, source) = try makeValidator(jwksCacheTTL: 300, jwksMaxStaleAge: 3600)
        let token = try await identity.sign(standardClaims(now: clock.now))
        _ = try await validator.validate(token)

        source.setError(JWKSSourceError(reason: "IdP down"))

        // Within the stale window, availability wins.
        clock.advance(by: 400)
        #expect(try await validator.validate(token).subject == "user-123")

        // Past it, the keys stop being trusted rather than being trusted
        // indefinitely.
        clock.advance(by: 4000)
        let fresh = try await identity.sign(standardClaims(now: clock.now))
        await expectValidationError(.keySourceUnavailable) { try await validator.validate(fresh) }
    }

    @Test("the stale bound holds for every request, not just the one that retries")
    func staleBoundHoldsInsideTheCooldown() async throws {
        // The bound was enforced only where a refresh was attempted and
        // failed. The refresh is cooldown-gated, so past the limit exactly
        // one request per cooldown window was refused and every other one
        // took the cached-return fast path — which had no age check at all.
        // At any real request rate that is ~all traffic still validating
        // against keys that may have been revoked, for the whole outage:
        // the guarantee inverted, while a test that made one request at a
        // time went on passing.
        let (validator, source) = try makeValidator(
            jwksCacheTTL: 300, jwksRefreshCooldown: 30, jwksMaxStaleAge: 3600)
        let token = try await identity.sign(standardClaims(now: clock.now))
        _ = try await validator.validate(token)

        source.setError(JWKSSourceError(reason: "IdP down"))
        clock.advance(by: 4000)  // past the stale limit

        // The request that attempts the refresh is refused, as it always was.
        let first = try await identity.sign(standardClaims(now: clock.now))
        await expectValidationError(.keySourceUnavailable) { try await validator.validate(first) }
        let fetchesAfterRefusal = source.fetchCount

        // Every request behind it, inside the same cooldown window, must be
        // refused too — without going near the IdP.
        for _ in 0..<5 {
            await expectValidationError(.keySourceUnavailable) {
                try await validator.validate(first)
            }
        }
        #expect(source.fetchCount == fetchesAfterRefusal, "the cooldown still gates fetches")
    }

    @Test("no keys at all — fetch failing from the start — is keySourceUnavailable")
    func keySourceUnavailable() async throws {
        let source = try InMemoryJWKSSource(json: jwksJSON([identity]))
        source.setError(JWKSSourceError(reason: "IdP unreachable"))
        let (validator, _) = try makeValidator(source: source)
        let token = try await identity.sign(standardClaims(now: clock.now))
        await expectValidationError(.keySourceUnavailable) { try await validator.validate(token) }
    }

    @Test("cold cache + unreachable IdP: fetch attempts stay cooldown-bounded")
    func coldStartCooldown() async throws {
        let source = try InMemoryJWKSSource(json: jwksJSON([identity]))
        source.setError(JWKSSourceError(reason: "IdP unreachable"))
        let (validator, _) = try makeValidator(source: source, jwksRefreshCooldown: 30)
        let token = try await identity.sign(standardClaims(now: clock.now))

        await expectValidationError(.keySourceUnavailable) { try await validator.validate(token) }
        #expect(source.fetchCount == 1)

        // A stream of bearer-token requests must not become a stream of
        // outbound fetches — fail fast inside the cooldown window.
        for _ in 0..<5 {
            await expectValidationError(.keySourceUnavailable) { try await validator.validate(token) }
        }
        #expect(source.fetchCount == 1, "cooldown gates the empty-cache path too")

        clock.advance(by: 31)
        await expectValidationError(.keySourceUnavailable) { try await validator.validate(token) }
        #expect(source.fetchCount == 2, "cooldown elapsed: one retry")

        // The IdP recovers: the next allowed attempt succeeds.
        source.setKeys(try decodeJWKS(jwksJSON([identity])))
        clock.advance(by: 31)
        let principal = try await validator.validate(token)
        #expect(principal.subject == "user-123")
    }

    @Test("a cancelled caller does not poison the shared in-flight fetch")
    func cancellationDuringSharedFetch() async throws {
        let source = try InMemoryJWKSSource(
            json: jwksJSON([identity]), fetchDelay: .milliseconds(100)
        )
        let (validator, _) = try makeValidator(source: source)
        let token = try await identity.sign(standardClaims(now: clock.now))

        let doomed = Task { try await validator.validate(token) }
        let survivor = Task { try await validator.validate(token) }
        try await Task.sleep(for: .milliseconds(20))  // both are awaiting the fetch
        doomed.cancel()

        let principal = try await survivor.value
        #expect(principal.subject == "user-123", "other awaiters are unaffected")
        _ = try? await doomed.value

        // The cache is healthy afterwards: no stuck in-flight task, no
        // spurious extra fetch.
        _ = try await validator.validate(token)
        #expect(source.fetchCount == 1)
    }

    @Test("concurrent validations during a fetch share one JWKS request (single-flight)")
    func singleFlight() async throws {
        let source = try InMemoryJWKSSource(
            json: jwksJSON([identity]), fetchDelay: .milliseconds(50)
        )
        let (validator, _) = try makeValidator(source: source)
        let token = try await identity.sign(standardClaims(now: clock.now))

        try await withThrowingTaskGroup(of: Principal.self) { group in
            for _ in 0..<8 {
                group.addTask { try await validator.validate(token) }
            }
            for try await principal in group {
                #expect(principal.subject == "user-123")
            }
        }
        #expect(source.fetchCount == 1)
    }

    @Test("unusable JWKS entries are skipped; usable keys still serve")
    func tolerantJWKSParsing() async throws {
        // A key with no kid (JWTKit rejects) alongside the good key.
        let source = try InMemoryJWKSSource(
            json: jwksJSON(
                [identity],
                extraKeys: [#"{"kty":"EC","crv":"P-256","x":"AA","y":"AA"}"#]
            )
        )
        let (validator, _) = try makeValidator(source: source)
        let token = try await identity.sign(standardClaims(now: clock.now))
        _ = try await validator.validate(token)
    }

    @Test("a JWKS with no usable keys is keySourceUnavailable")
    func emptyJWKS() async throws {
        let source = try InMemoryJWKSSource(json: #"{"keys":[]}"#)
        let (validator, _) = try makeValidator(source: source)
        let token = try await identity.sign(standardClaims(now: clock.now))
        await expectValidationError(.keySourceUnavailable) { try await validator.validate(token) }
    }

    // MARK: Error hygiene

    @Test("attacker-controlled header values cannot forge log lines")
    func logInjectionNeutralized() async throws {
        let (validator, _) = try makeValidator()
        _ = try await validator.validate(try await identity.sign(standardClaims(now: clock.now)))

        // A syntactically valid token whose kid embeds newlines and ANSI
        // escapes; the unknown-kid error carries the kid into logs.
        let hostile = TestIdentity(kid: "x\nFAKE-LOG-LINE session=admin\u{1B}[0m\r")
        clock.advance(by: 60)
        let token = try await hostile.sign(standardClaims(now: clock.now))
        do {
            _ = try await validator.validate(token)
            Issue.record("expected failure")
        } catch let error as TokenValidationError {
            let rendered = String(describing: error)
            #expect(!rendered.contains("\n"))
            #expect(!rendered.contains("\r"))
            #expect(!rendered.contains("\u{1B}"))
        }

        // And reasons are length-capped so a huge header can't bloat logs.
        let long = TokenValidationError(kind: .malformedToken, reason: String(repeating: "A", count: 10_000))
        #expect(long.reason.count <= 257)
    }

    @Test("validation errors never contain the token itself")
    func errorsOmitToken() async throws {
        let (validator, _) = try makeValidator()
        let expired = try await identity.sign(standardClaims(now: clock.now, expiresIn: -7200))
        do {
            _ = try await validator.validate(expired)
            Issue.record("expected failure")
        } catch {
            let rendered = String(describing: error)
            let segments = expired.split(separator: ".")
            #expect(!rendered.contains(String(segments[1])), "payload must not leak into errors")
            #expect(!rendered.contains(String(segments[2])), "signature must not leak into errors")
        }
    }
}
