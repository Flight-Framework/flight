import Foundation

/// The JOSE header fields Flight needs *before* verification: `kid` decides
/// whether a JWKS refresh is warranted (design §3.2), `alg` is screened
/// defensively. This is structural parsing only — no cryptography; signature
/// verification stays with JWTKit (design §3.1).
struct TokenHeader: Sendable, Equatable {
    let algorithm: String?
    let keyID: String?

    private struct Fields: Decodable {
        let alg: String?
        let kid: String?
    }

    static func parse(_ token: String) throws(TokenValidationError) -> TokenHeader {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else {
            throw TokenValidationError(
                kind: .malformedToken,
                reason: "expected 3 JWT segments, got \(segments.count)"
            )
        }
        guard let headerData = Data(base64URLEncoded: segments[0]) else {
            throw TokenValidationError(
                kind: .malformedToken, reason: "JOSE header is not valid base64url"
            )
        }
        guard let fields = try? JSONDecoder().decode(Fields.self, from: headerData) else {
            throw TokenValidationError(
                kind: .malformedToken, reason: "JOSE header is not a valid JSON object"
            )
        }
        return TokenHeader(algorithm: fields.alg, keyID: fields.kid)
    }
}

extension Data {
    init?(base64URLEncoded input: Substring) {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        self.init(base64Encoded: base64)
    }
}
