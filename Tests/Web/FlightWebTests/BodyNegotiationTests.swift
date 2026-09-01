import FlightCore
import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Testing

// Content negotiation end to end: real macro-generated routes, driven
// through TestClient, asserting what a client on the wire actually sees —
// including the 0.6.0 breaking change (mislabeled bodies are 415, absent
// labels keep working).

struct SignupForm: Codable, Equatable, ResponseEncodable {
    let email: String
    let newsletter: Bool
}

@Controller
struct NegotiationFixtureController {
    /// One Decodable route serves both JSON and form clients — that is the
    /// entire point of negotiating in the framework.
    @PostRoute("/signup")
    func signup(_ context: RequestContext, body: SignupForm) -> SignupForm {
        body
    }

    /// Raw bytes: any Content-Type, no negotiation, returned verbatim.
    @PostRoute("/bytes")
    func bytes(_ context: RequestContext, body: Data) -> Response {
        .fixed(status: .ok, headers: [:], body: body)
    }

    /// Plain text: strict UTF-8 in, echoed back.
    @PostRoute("/note")
    func note(_ context: RequestContext, body: String) -> String {
        "note:\(body)"
    }
}

private struct NegotiationModule: FlightModule {
    func configure(_ container: Container) throws {
        try NegotiationFixtureController._flightRegister(container)
    }
}

@Suite("body negotiation — end to end")
struct BodyNegotiationTests {

    private func client() throws -> TestClient {
        try TestClient(container: TestContainer.build { NegotiationModule() })
    }

    private func post(
        _ path: String, body: String, contentType: String?
    ) async throws -> Response {
        var headers: HTTPFields = [:]
        if let contentType { headers[.contentType] = contentType }
        return await try client().execute(
            Request(method: .post, path: path, headers: headers, body: Data(body.utf8)))
    }

    @Test("a form post decodes into the same type a JSON post does")
    func formAndJSONConverge() async throws {
        let form = try await post(
            "/signup", body: "email=ada%40example.com&newsletter=on",
            contentType: "application/x-www-form-urlencoded")
        #expect(form.status == .ok)
        #expect(
            try form.decodeJSON(SignupForm.self)
                == SignupForm(email: "ada@example.com", newsletter: true))

        let json = try await post(
            "/signup", body: #"{"email":"ada@example.com","newsletter":true}"#,
            contentType: "application/json")
        #expect(try json.decodeJSON(SignupForm.self) == (try form.decodeJSON(SignupForm.self)))
    }

    @Test("an absent Content-Type still decodes as JSON — the documented leniency")
    func absentHeaderStaysLenient() async throws {
        let response = try await post(
            "/signup", body: #"{"email":"a@b.c","newsletter":false}"#, contentType: nil)
        #expect(response.status == .ok)
    }

    @Test("+json structured suffixes take the JSON path")
    func structuredSuffix() async throws {
        let response = try await post(
            "/signup", body: #"{"email":"a@b.c","newsletter":false}"#,
            contentType: "application/vnd.api+json")
        #expect(response.status == .ok)
    }

    @Test("a mislabeled body is 415, and the message names both sides")
    func mislabeledBodyIs415() async throws {
        // Worked before 0.6.0; the label is a client bug the framework
        // stopped papering over. THE breaking change, pinned.
        let response = try await post(
            "/signup", body: #"{"email":"a@b.c","newsletter":false}"#,
            contentType: "text/plain")
        #expect(response.status == .unsupportedMediaType)
        // Decoded, not substring-matched: the problem encoder escapes
        // slashes in the raw body ("text\/plain").
        struct Problem: Decodable { let detail: String }
        let detail = try response.decodeJSON(Problem.self).detail
        #expect(detail.contains("text/plain"))
        #expect(detail.contains("application/json"))
        #expect(detail.contains("application/x-www-form-urlencoded"))
    }

    @Test("an unparseable Content-Type is 415, not a decode 400")
    func unparseableContentType() async throws {
        let response = try await post(
            "/signup", body: "email=a%40b.c", contentType: "complete garbage")
        #expect(response.status == .unsupportedMediaType)
    }

    @Test("a form charset other than UTF-8 is 415 — silently misreading is worse")
    func foreignCharset() async throws {
        let response = try await post(
            "/signup", body: "email=a%40b.c&newsletter=on",
            contentType: "application/x-www-form-urlencoded; charset=iso-8859-1")
        #expect(response.status == .unsupportedMediaType)

        let utf8 = try await post(
            "/signup", body: "email=a%40b.c&newsletter=on",
            contentType: "application/x-www-form-urlencoded; charset=UTF-8")
        #expect(utf8.status == .ok)
    }

    @Test("a form decode failure is a 400 naming the field, same quality as JSON")
    func formErrorsMatchJSONQuality() async throws {
        let response = try await post(
            "/signup", body: "newsletter=on",
            contentType: "application/x-www-form-urlencoded")
        #expect(response.status == .badRequest)
        #expect(response.bodyText.contains("email"))
    }

    @Test("an empty body on a Decodable route is a 400")
    func emptyBody() async throws {
        let response = try await post("/signup", body: "", contentType: "application/json")
        #expect(response.status == .badRequest)
    }

    @Test("body: Data receives any content type verbatim — octet-stream stops being a trap")
    func rawBytes() async throws {
        // Before 0.6.0 this hit the JSON path and demanded base64 in
        // quotes. Now: bytes in, bytes out, label ignored.
        var headers: HTTPFields = [:]
        headers[.contentType] = "application/octet-stream"
        let response = await try client().execute(
            Request(
                method: .post, path: "/bytes", headers: headers,
                body: Data([0x00, 0x01, 0xFF, 0x7F])))
        #expect(response.status == .ok)
        #expect(response.bodyData == Data([0x00, 0x01, 0xFF, 0x7F]))
    }

    @Test("body: String takes any label but validates the bytes")
    func plainText() async throws {
        let ok = try await post("/note", body: "hello", contentType: "text/plain")
        #expect(ok.bodyText.contains("note:hello"))

        let unlabeled = try await post("/note", body: "still fine", contentType: nil)
        #expect(unlabeled.status == .ok)

        var headers: HTTPFields = [:]
        headers[.contentType] = "text/plain"
        let invalid = await try client().execute(
            Request(method: .post, path: "/note", headers: headers, body: Data([0xFF, 0xFE])))
        #expect(invalid.status == .badRequest, "invalid UTF-8 is the client's 400")

        let declared = try await post(
            "/note", body: "olé", contentType: "text/plain; charset=iso-8859-1")
        #expect(
            declared.status == .unsupportedMediaType,
            "a declared non-UTF-8 charset would be silently misread — refuse it")
    }
}
