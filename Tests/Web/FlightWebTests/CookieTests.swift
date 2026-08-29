import Foundation
import FlightWeb
import HTTPTypes
import Testing

@Suite("cookies")
struct CookieTests {

    @Test("the defaults are the safe ones")
    func safeDefaults() {
        let cookie = Cookie(name: "session", value: "abc")
        let header = cookie.headerValue
        #expect(header.contains("session=abc"))
        #expect(header.contains("HttpOnly"), "a session cookie JavaScript can read is an XSS away from theft")
        #expect(header.contains("SameSite=Lax"))
        #expect(header.contains("Path=/"))
        // Not assumed: a dev server on loopback has no TLS.
        #expect(!header.contains("Secure"))
    }

    @Test("attributes render in the Set-Cookie grammar")
    func attributes() {
        let cookie = Cookie(
            name: "fd", value: "v", path: "/app", domain: "example.com",
            maxAge: .seconds(3600), isSecure: true, isHTTPOnly: false, sameSite: .strict)
        let header = cookie.headerValue
        #expect(header.hasPrefix("fd=v"))
        #expect(header.contains("Path=/app"))
        #expect(header.contains("Domain=example.com"))
        #expect(header.contains("Max-Age=3600"))
        #expect(header.contains("Secure"))
        #expect(!header.contains("HttpOnly"))
        #expect(header.contains("SameSite=Strict"))
    }

    @Test("an expiring cookie is empty, zero-aged, and dated to the epoch")
    func expiringCookie() {
        let header = Cookie.expiring("session").headerValue
        #expect(header.hasPrefix("session="))
        #expect(header.contains("Max-Age=0"))
        #expect(header.contains("Expires=Thu, 01 Jan 1970"))
    }

    @Test("request cookies parse from the single Cookie header")
    func parsing() {
        let request = Request(
            method: .get, path: "/",
            headers: [.cookie: "session=abc123; theme=dark; consent=yes"])
        #expect(request.cookies.count == 3)
        #expect(request.cookie("session") == "abc123")
        #expect(request.cookie("theme") == "dark")
        #expect(request.cookie("absent") == nil)
    }

    @Test("parsing tolerates whitespace, junk, and values containing '='")
    func parsingEdges() {
        let request = Request(
            method: .get, path: "/",
            headers: [.cookie: "  a=1 ;novalue;  b=x=y=z ; =noname; c=  "])
        #expect(request.cookie("a") == "1")
        // A JWT or base64 value contains '=' — only the FIRST one splits.
        #expect(request.cookie("b") == "x=y=z")
        #expect(request.cookie("c") == "")
        #expect(request.cookies["novalue"] == nil, "a pair with no '=' is skipped, not fatal")
        #expect(request.cookies[""] == nil, "an empty name is skipped")
    }

    @Test("duplicate names keep the first — the browser's most specific path")
    func duplicates() {
        let request = Request(
            method: .get, path: "/", headers: [.cookie: "session=specific; session=general"])
        #expect(request.cookie("session") == "specific")
    }

    @Test("no Cookie header is an empty dictionary, not a crash")
    func absentHeader() {
        #expect(Request(method: .get, path: "/").cookies.isEmpty)
    }

    @Test("several cookies are several headers, never one joined value")
    func multipleSetCookieHeaders() {
        // The bug this prevents: joining Set-Cookie values with a comma
        // produces one header browsers parse as a single malformed cookie,
        // so only one of them (or none) survives.
        let response = Response.noContent
            .settingCookie(Cookie(name: "a", value: "1"))
            .settingCookie(Cookie(name: "b", value: "2"))
        let values = response.headers[values: .setCookie]
        #expect(values.count == 2, "expected two Set-Cookie headers, got \(values)")
        #expect(values.contains { $0.hasPrefix("a=1") })
        #expect(values.contains { $0.hasPrefix("b=2") })
    }

    @Test("cookies survive every response shape that has headers")
    func acrossResponseShapes() async throws {
        let fixed = Response.text("hi").settingCookie(Cookie(name: "s", value: "1"))
        #expect(fixed.headers[values: .setCookie].count == 1)

        let file = serveContent(
            for: Request(method: .get, path: "/f"),
            ContentDescriptor(source: DataByteSource(Data("bytes".utf8))))
            .settingCookie(Cookie(name: "s", value: "1"))
        #expect(file.headers[values: .setCookie].count == 1)
        // And the body still works after the header edit.
        #expect(try await file.collectedBody() == Data("bytes".utf8))
    }

    @Test("seeOther is a 303 carrying Location — a form POST that survives reload")
    func seeOther() {
        let response = Response.seeOther("/projects")
        #expect(response.status == .seeOther)
        #expect(response.headers[.location] == "/projects")
    }

    @Test("a value cannot forge cookie attributes")
    func valueCannotInjectAttributes() {
        // `Set-Cookie` has no escaping, so a `;` in a value does not corrupt
        // the value — it ends it and starts an attribute list. A session
        // token echoed from user input carrying "; SameSite=None; Secure"
        // reached the wire as exactly that, silently, on a type whose whole
        // framing is safe defaults.
        let cookie = Cookie(name: "session", value: "abc; SameSite=None; Secure")
        let rendered = cookie.headerValue
        // The forged text survives *inside the value* — harmless, since
        // nothing separates it from the value any more — but no `;` reaches
        // the wire from it, so it forges no attribute.
        let attributes = rendered.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        #expect(attributes.first == "session=abcSameSite=NoneSecure")
        #expect(attributes.dropFirst().sorted() == ["HttpOnly", "Path=/", "SameSite=Lax"])
    }

    @Test("control characters and quoting characters are dropped from a value")
    func valueIsRFC6265Clean() {
        let cookie = Cookie(name: "t", value: "a\u{0007}b\"c\\d e,f")
        #expect(cookie.headerValue.hasPrefix("t=abcdef;"))
    }

    @Test("an ordinary value is untouched")
    func ordinaryValuesSurvive() {
        // Base64 and JWTs are the values that actually go in cookies; none of
        // their alphabet is structural.
        let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc-_="
        #expect(Cookie(name: "jwt", value: token).headerValue.hasPrefix("jwt=\(token);"))
    }
}
