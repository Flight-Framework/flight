import FlightWeb
import HTTPTypes
import Testing

@testable import FlightSecurityCore

@Suite("Bearer token extraction (§4, RFC 6750)")
struct BearerTokenTests {
    private func request(authorization: String?) -> Request {
        var headers: HTTPFields = [:]
        if let authorization {
            headers[.authorization] = authorization
        }
        return Request(method: .get, path: "/", headers: headers)
    }

    @Test("extracts the token from a well-formed Bearer header")
    func wellFormed() {
        #expect(request(authorization: "Bearer abc.def.ghi").bearerToken == "abc.def.ghi")
    }

    @Test("scheme comparison is case-insensitive")
    func caseInsensitiveScheme() {
        #expect(request(authorization: "bearer tok").bearerToken == "tok")
        #expect(request(authorization: "BEARER tok").bearerToken == "tok")
        #expect(request(authorization: "BeArEr tok").bearerToken == "tok")
    }

    @Test("tolerates surrounding and repeated separator spaces")
    func extraSpaces() {
        #expect(request(authorization: "  Bearer tok  ").bearerToken == "tok")
        #expect(request(authorization: "Bearer    tok").bearerToken == "tok")
    }

    @Test("missing header yields nil")
    func missingHeader() {
        #expect(request(authorization: nil).bearerToken == nil)
    }

    @Test("other schemes yield nil")
    func otherSchemes() {
        #expect(request(authorization: "Basic dXNlcjpwYXNz").bearerToken == nil)
        #expect(request(authorization: "Digest abc").bearerToken == nil)
        #expect(request(authorization: "Bearerx tok").bearerToken == nil)
    }

    @Test("malformed Bearer values yield nil rather than a garbage token")
    func malformed() {
        #expect(request(authorization: "Bearer").bearerToken == nil)
        #expect(request(authorization: "Bearer ").bearerToken == nil)
        #expect(request(authorization: "Bearer a b").bearerToken == nil)
        #expect(request(authorization: "").bearerToken == nil)
    }
}
