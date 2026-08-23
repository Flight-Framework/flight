import Foundation
import Testing

@testable import FlightSecurityCore

@Suite("Claim parsing and extraction")
struct ClaimsTests {
    private func decode(_ json: String) throws -> RawClaims {
        try JSONDecoder().decode(RawClaims.self, from: Data(json.utf8))
    }

    @Test("decodes every JSON shape a JWT payload can carry")
    func decodesAllShapes() throws {
        let claims = try decode(
            """
            {"s":"text","i":7,"d":1.5,"b":true,"n":null,
             "a":["x","y"],"o":{"nested":{"deep":"value"}}}
            """
        )
        #expect(claims.values["s"] == .string("text"))
        #expect(claims.values["i"] == .int(7))
        #expect(claims.values["d"] == .double(1.5))
        #expect(claims.values["b"] == .bool(true))
        #expect(claims.values["n"] == .null)
        #expect(claims.values["a"] == .array([.string("x"), .string("y")]))
        #expect(claims.values["o"] == .object(["nested": .object(["deep": .string("value")])]))
    }

    @Test("dot-path lookup traverses nested objects (Keycloak realm_access.roles)")
    func dotPathLookup() throws {
        let claims = try decode(#"{"realm_access":{"roles":["admin","user"]}}"#)
        #expect(claims.value(at: "realm_access.roles") == .array([.string("admin"), .string("user")]))
        #expect(claims.value(at: "realm_access.missing") == nil)
        #expect(claims.value(at: "missing.roles") == nil)
    }

    @Test("an exact top-level key wins over dot-path traversal (Auth0 namespaced claims)")
    func exactKeyPrecedence() throws {
        let claims = try decode(
            #"{"https://example.com/roles":["admin"],"https://example":{"com/roles":["wrong"]}}"#
        )
        #expect(claims.value(at: "https://example.com/roles") == .array([.string("admin")]))
    }

    @Test("roles union across multiple configured claims")
    func rolesUnion() throws {
        let claims = try decode(
            #"{"roles":["a"],"groups":["b"],"realm_access":{"roles":["c"]}}"#
        )
        let roles = claims.stringSet(atAnyOf: ["roles", "groups", "realm_access.roles"])
        #expect(roles == ["a", "b", "c"])
    }

    @Test("a single-string roles claim is one role")
    func singleStringRole() throws {
        let claims = try decode(#"{"roles":"admin"}"#)
        #expect(claims.stringSet(atAnyOf: ["roles"]) == ["admin"])
    }

    @Test("space-delimited scope string splits; scp array is element-wise (RFC 8693 / Okta)")
    func scopeShapes() throws {
        let claims = try decode(#"{"scope":"read write","scp":["admin:read"]}"#)
        let scopes = claims.stringSet(atAnyOf: ["scope", "scp"], splittingStringsOn: " ")
        #expect(scopes == ["read", "write", "admin:read"])
    }

    @Test("non-string array elements and empty strings are dropped")
    func dirtyValues() throws {
        let claims = try decode(#"{"roles":["ok",42,null,""]}"#)
        #expect(claims.stringSet(atAnyOf: ["roles"]) == ["ok"])
    }

    @Test("missing claims produce an empty set")
    func missingClaims() throws {
        let claims = try decode(#"{"sub":"u1"}"#)
        #expect(claims.stringSet(atAnyOf: ["roles", "groups"]).isEmpty)
    }

    @Test("anySendable bridges to standard types and drops JSON null")
    func sendableBridge() throws {
        let claims = try decode(
            #"{"s":"x","i":3,"b":false,"n":null,"a":[1,null],"o":{"k":null,"v":"y"}}"#
        )
        #expect(claims.values["s"]?.anySendable as? String == "x")
        #expect(claims.values["i"]?.anySendable as? Int == 3)
        #expect(claims.values["b"]?.anySendable as? Bool == false)
        #expect(claims.values["n"]?.anySendable == nil)
        let array = claims.values["a"]?.anySendable as? [any Sendable]
        #expect(array?.count == 1, "null elements are dropped")
        let object = claims.values["o"]?.anySendable as? [String: any Sendable]
        #expect(object?.count == 1)
        #expect(object?["v"] as? String == "y")
    }

    @Test("NumericDate accepts integer and fractional epoch seconds")
    func numericDate() throws {
        let claims = try decode(#"{"exp":1750000000,"nbf":1750000000.5}"#)
        #expect(claims.values["exp"]?.numericDateValue == 1_750_000_000)
        #expect(claims.values["nbf"]?.numericDateValue == 1_750_000_000.5)
        #expect(JSONValue.string("soon").numericDateValue == nil)
    }
}
