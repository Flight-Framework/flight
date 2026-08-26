import Foundation
import FlightWeb
import Testing

// Every rule in FormDecoder's doc comment is pinned here — the format has
// no single spec for its edges, so the tests ARE the spec this framework
// answers to.

private func decode<T: Decodable>(_ body: String, as type: T.Type = T.self) throws -> T {
    try FormDecoder().decode(type, from: Data(body.utf8))
}

@Suite("FormDecoder — wire semantics")
struct FormDecoderWireTests {

    struct Login: Decodable, Equatable {
        let email: String
        let password: String
    }

    @Test("a plain form decodes")
    func plainForm() throws {
        let login: Login = try decode("email=ada%40example.com&password=hunter2")
        #expect(login == Login(email: "ada@example.com", password: "hunter2"))
    }

    @Test("+ is a space; %2B is a literal plus; %20 is also a space")
    func plusAndSpaces() throws {
        struct Q: Decodable {
            let q: String
            let formula: String
        }
        let value: Q = try decode("q=hello+world%20again&formula=1%2B1")
        #expect(value.q == "hello world again")
        #expect(value.formula == "1+1")
    }

    @Test("invalid percent escapes are an error, not passthrough")
    func invalidEscapes() {
        struct S: Decodable { let a: String }
        for body in ["a=%G1", "a=%2", "a=%", "a=ok%ZZno"] {
            #expect(throws: DecodingError.self, "'\(body)'") {
                let _: S = try decode(body)
            }
        }
    }

    @Test("decoded bytes must be valid UTF-8")
    func invalidUTF8() {
        struct S: Decodable { let a: String }
        #expect(throws: DecodingError.self) {
            let _: S = try decode("a=%FF%FE")
        }
    }

    @Test("a=  and a bare key are the empty string — present, not nil")
    func emptyValues() throws {
        struct S: Decodable {
            let a: String
            let b: String
        }
        let value: S = try decode("a=&b")
        #expect(value.a == "")
        #expect(value.b == "")
    }

    @Test("absent key is nil for optionals; present-empty for Int? is a type error")
    func optionalSemantics() throws {
        struct S: Decodable {
            let missing: Int?
            let name: String
        }
        let value: S = try decode("name=x")
        #expect(value.missing == nil)

        struct T: Decodable { let n: Int? }
        // `n=` is PRESENT with value "" — silently reading that as nil
        // would hide client bugs, so it throws instead.
        #expect(throws: DecodingError.self) {
            let _: T = try decode("n=")
        }
    }

    @Test("a repeated key with a scalar target takes the last occurrence")
    func repeatedScalarLastWins() throws {
        struct S: Decodable { let color: String }
        let value: S = try decode("color=red&color=blue")
        #expect(value.color == "blue")
    }

    @Test("a repeated key with an array target takes every occurrence, in order")
    func repeatedArray() throws {
        struct S: Decodable { let tag: [String] }
        let value: S = try decode("tag=a&other=x&tag=b&tag=c")
        #expect(value.tag == ["a", "b", "c"])

        struct One: Decodable { let tag: [String] }
        let single: One = try decode("tag=only")
        #expect(single.tag == ["only"])

        struct Absent: Decodable { let tag: [String]? }
        let absent: Absent = try decode("other=x")
        #expect(absent.tag == nil)
    }

    @Test("array elements parse individually, and one bad element fails the field")
    func typedArrays() throws {
        struct S: Decodable { let n: [Int] }
        let value: S = try decode("n=1&n=2&n=3")
        #expect(value.n == [1, 2, 3])
        #expect(throws: DecodingError.self) {
            let _: S = try decode("n=1&n=two")
        }
    }

    @Test("booleans accept the six spellings, case-insensitively")
    func boolSpellings() throws {
        struct S: Decodable { let v: Bool }
        for (raw, expected) in [
            ("true", true), ("True", true), ("1", true), ("on", true), ("ON", true),
            ("false", false), ("0", false), ("off", false), ("OFF", false),
        ] {
            let value: S = try decode("v=\(raw)")
            #expect(value.v == expected, "\(raw)")
        }
        #expect(throws: DecodingError.self) {
            let _: S = try decode("v=")
        }
        #expect(throws: DecodingError.self) {
            let _: S = try decode("v=yes")
        }
    }

    @Test("the checkbox rule: absent non-optional Bool is false; Bool? stays nil")
    func checkboxRule() throws {
        struct Prefs: Decodable {
            let newsletter: Bool
            let name: String
        }
        // An unchecked checkbox sends nothing at all — the one deliberate
        // deviation from JSONDecoder strictness.
        let unchecked: Prefs = try decode("name=ada")
        #expect(unchecked.newsletter == false)
        let checked: Prefs = try decode("name=ada&newsletter=on")
        #expect(checked.newsletter == true)

        struct Tri: Decodable { let flag: Bool? }
        let absent: Tri = try decode("x=1")
        #expect(absent.flag == nil, "Bool? opts out of the checkbox rule")
    }

    @Test("numeric parsing is strict — overflow and garbage throw with the field named")
    func numerics() throws {
        struct S: Decodable {
            let count: Int
            let ratio: Double
        }
        let value: S = try decode("count=42&ratio=0.5")
        #expect(value.count == 42)
        #expect(value.ratio == 0.5)

        struct Tiny: Decodable { let n: Int8 }
        #expect(throws: DecodingError.self) {
            let _: Tiny = try decode("n=300")
        }
        do {
            let _: S = try decode("count=abc&ratio=1")
            Issue.record("expected a throw")
        } catch let error as DecodingError {
            guard case .typeMismatch(_, let context) = error else {
                Issue.record("expected typeMismatch, got \(error)")
                return
            }
            #expect(context.codingPath.map(\.stringValue) == ["count"])
        }
    }

    @Test("unknown keys are ignored, like JSONDecoder")
    func unknownKeys() throws {
        struct S: Decodable { let a: String }
        let value: S = try decode("a=1&csrf=whatever&utm_source=mail")
        #expect(value.a == "1")
    }

    @Test("string-raw enums decode; an unknown case names itself in the error")
    func enums() throws {
        enum Role: String, Decodable { case admin, member }
        struct S: Decodable { let role: Role }
        let value: S = try decode("role=admin")
        #expect(value.role == .admin)
        #expect(throws: DecodingError.self) {
            let _: S = try decode("role=superuser")
        }
    }

    @Test("nested targets are refused with the flat-bodies message")
    func nestingRefused() {
        struct Inner: Decodable { let x: String }
        struct S: Decodable { let inner: Inner }
        do {
            let _: S = try decode("inner=oops")
            Issue.record("expected a throw")
        } catch let error as DecodingError {
            guard case .dataCorrupted(let context) = error else {
                Issue.record("expected dataCorrupted, got \(error)")
                return
            }
            #expect(context.debugDescription.contains("flat"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("Date and Data targets are refused with the message naming the fix")
    func unrepresentableTypes() {
        struct D: Decodable { let when: Date }
        do {
            let _: D = try decode("when=2026-08-26")
            Issue.record("expected a throw")
        } catch let error as DecodingError {
            guard case .dataCorrupted(let context) = error else {
                Issue.record("expected dataCorrupted, got \(error)")
                return
            }
            #expect(context.debugDescription.contains("String"))
        } catch {
            Issue.record("unexpected \(error)")
        }

        struct B: Decodable { let blob: Data }
        #expect(throws: DecodingError.self) {
            let _: B = try decode("blob=AAAA")
        }
    }

    @Test("URL decodes through its String path")
    func urls() throws {
        struct S: Decodable { let link: URL }
        let value: S = try decode("link=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1")
        #expect(value.link.absoluteString == "https://example.com/a?b=1")
    }

    @Test("empty segments from && and trailing & are skipped; ; is value text")
    func separatorEdges() throws {
        struct S: Decodable {
            let a: String
            let b: String
        }
        let value: S = try decode("a=1&&b=2&")
        #expect(value.a == "1")
        #expect(value.b == "2")

        struct One: Decodable { let a: String }
        let semicolons: One = try decode("a=1;b=2")
        #expect(semicolons.a == "1;b=2", "the W3C spec dropped ; as a separator")
    }

    @Test("an empty body decodes an all-optional type to nils")
    func emptyBody() throws {
        struct S: Decodable {
            let a: String?
            let b: Int?
        }
        let value = try FormDecoder().decode(S.self, from: Data())
        #expect(value.a == nil)
        #expect(value.b == nil)
    }

    @Test("a missing required field names itself, path included")
    func missingRequired() {
        struct S: Decodable { let email: String }
        do {
            let _: S = try decode("other=1")
            Issue.record("expected a throw")
        } catch let error as DecodingError {
            guard case .keyNotFound(let key, _) = error else {
                Issue.record("expected keyNotFound, got \(error)")
                return
            }
            #expect(key.stringValue == "email")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

@Suite("MediaType parsing")
struct MediaTypeTests {

    @Test("essence, parameters, and case rules")
    func basics() throws {
        let parsed = try #require(MediaType(parsing: "Application/JSON"))
        #expect(parsed.essence == "application/json")
        #expect(parsed.isJSON)

        let form = try #require(
            MediaType(parsing: "application/x-www-form-urlencoded; charset=UTF-8"))
        #expect(form.essence == "application/x-www-form-urlencoded")
        #expect(form.parameter("Charset") == "UTF-8", "names case-fold; values keep case")
    }

    @Test("+json structured suffixes are JSON; text/json is deliberately not")
    func jsonSuffix() throws {
        #expect(try #require(MediaType(parsing: "application/problem+json")).isJSON)
        #expect(try #require(MediaType(parsing: "application/vnd.api+json")).isJSON)
        #expect(!(try #require(MediaType(parsing: "text/json")).isJSON))
    }

    @Test("quoted parameter values unescape; a boundary with a semicolon survives")
    func quotedParameters() throws {
        let parsed = try #require(
            MediaType(parsing: #"multipart/form-data; boundary="ab;cd\"ef""#))
        #expect(parsed.parameter("boundary") == #"ab;cd"ef"#)
    }

    @Test("whitespace tolerance around ; and =")
    func whitespace() throws {
        let parsed = try #require(MediaType(parsing: "  text/html ;  charset = utf-8  "))
        #expect(parsed.essence == "text/html")
        #expect(parsed.parameter("charset") == "utf-8")
        #expect(parsed.isText)
    }

    @Test("junk does not parse")
    func junk() {
        for raw in ["", "json", "/json", "text/", "text/ht ml", "a/b; =x", "a/b; c"] {
            #expect(MediaType(parsing: raw) == nil, "'\(raw)'")
        }
    }
}
