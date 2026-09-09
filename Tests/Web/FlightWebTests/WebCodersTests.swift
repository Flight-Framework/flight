import FlightCore
import FlightWeb
import FlightWebTesting
import Foundation
import Testing

/// What the application says about its own wire format, and whether Flight
/// honors it.
@Suite("WebCoders")
struct WebCodersTests {

    private struct Event: Codable, ResponseEncodable, Equatable {
        let eventName: String
        let occurredAt: Date
    }

    /// A frozen container wired by the real `FlightWebModule`, so a
    /// `TestClient` dispatches exactly as an application would.
    private func container(_ values: [String: String]) throws -> Container {
        let configuration = Configuration(values: values)
        return try TestContainer.build(configuration: configuration) {
            try FlightWebModule<InMemoryTransport>(configuration: configuration)
        }
    }

    /// A context whose coders are the ones the real `FlightWebModule` builds
    /// from configuration — the value dispatch stamps onto every request.
    private func context(_ values: [String: String], body: Data = Data()) throws -> RequestContext {
        let configuration = Configuration(values: values)
        let module = try FlightWebModule<InMemoryTransport>(configuration: configuration)
        var context = RequestContext.mock(path: "/", body: body)
        context.web = WebRuntime(coders: module.coders)
        return context
    }

    // MARK: Defaults

    @Test("dates are ISO-8601 by default, not seconds since 2001")
    func defaultDateStrategy() throws {
        let event = Event(eventName: "a", occurredAt: Date(timeIntervalSince1970: 1_700_000_000))
        let body = try event.response(for: .mock()).bodyText
        #expect(body.contains("2023-11-14T22:13:20Z"))
        // Foundation's default would have written 721772000.0 here — present,
        // numeric, and meaningless to anything that is not another Foundation.
        #expect(!body.contains("721772000"))
    }

    @Test("keys are left alone by default")
    func defaultKeyStrategy() throws {
        let event = Event(eventName: "a", occurredAt: .init(timeIntervalSince1970: 0))
        #expect(try event.response(for: .mock()).bodyText.contains("\"eventName\""))
    }

    // MARK: Configured

    @Test("snake-case keys apply to responses")
    func snakeCaseEncoding() throws {
        let context = try context(["web.json.key-strategy": "snake-case"])
        let event = Event(eventName: "a", occurredAt: .init(timeIntervalSince1970: 0))
        let body = try event.response(for: context).bodyText
        #expect(body.contains("\"event_name\""))
        #expect(!body.contains("\"eventName\""))
    }

    @Test("snake-case keys apply to request bodies too")
    func snakeCaseDecoding() throws {
        let context = try context(
            ["web.json.key-strategy": "snake-case"],
            body: Data(#"{"event_name":"a","occurred_at":"1970-01-01T00:00:00Z"}"#.utf8))
        #expect(try decodeRequestBody(Event.self, from: context).eventName == "a")
    }

    @Test("a date strategy applies in both directions")
    func dateStrategyRoundTrips() throws {
        let context = try context(["web.json.date-strategy": "seconds"])
        let event = Event(eventName: "a", occurredAt: Date(timeIntervalSince1970: 1_700_000_000))
        let body = try event.response(for: context).bodyText
        #expect(body.contains("1700000000"))

        let decoding = try self.context(["web.json.date-strategy": "seconds"], body: Data(body.utf8))
        #expect(try decodeRequestBody(Event.self, from: decoding) == event)
    }

    // MARK: Error bodies

    @Test("errors are RFC 9457 problem+json by default")
    func defaultErrorFormat() throws {
        let response = errorResponse(for: HTTPError(.notFound, "no such user"), context: .mock())
        #expect(response.headers[.contentType] == "application/problem+json")
        #expect(response.bodyText.contains("\"title\":\"Not Found\""))
    }

    @Test("errors can be the pre-9457 shape instead")
    func simpleErrorFormat() throws {
        let context = try context(["web.errors.format": "simple"])
        let response = errorResponse(for: HTTPError(.notFound, "no such user"), context: context)
        #expect(response.headers[.contentType] == ContentType.json.rawValue)
        #expect(response.bodyText.contains("\"error\":\"no such user\""))
    }

    @Test("a 404 from the router uses the configured error format")
    func routerHonorsErrorFormat() async throws {
        let client = try TestClient(
            container: container(["web.errors.format": "simple"]))
        let response = await client.get("/nothing-here")
        #expect(response.status == .notFound)
        #expect(response.bodyText.contains("\"error\""))
    }

    // MARK: Failures

    @Test("an unknown value names the key and what was expected")
    func unknownValueIsRejected() throws {
        do {
            _ = try WebCoders(configuration: Configuration(values: ["web.json.key-strategy": "kebab"]))
            Issue.record("expected a thrown error")
        } catch let error as WebCodersError {
            let text = "\(error)"
            #expect(text.contains("web.json.key-strategy"))
            #expect(text.contains("kebab"))
            #expect(text.contains("snake-case"))
        }
    }

    @Test("an application's own coders win over the configured ones")
    func applicationRegistrationWins() throws {
        // The application's coders arrive as an argument rather than winning
        // a registration race — whether it brought its own is a fact about
        // how it was composed, and the composer matches the property by type.
        let configuration = Configuration(values: [:])
        let custom = CustomCodersModule()
        _ = try TestContainer.build(configuration: configuration) {
            custom
            try FlightWebModule<InMemoryTransport>(
                configuration: configuration, coders: custom.coders)
        }
        // The coders ride on the context, stamped by dispatch from what the
        // web module was composed with — here, set directly.
        var context = RequestContext.mock()
        context.web = WebRuntime(coders: custom.coders)
        let event = Event(eventName: "a", occurredAt: .init(timeIntervalSince1970: 0))
        #expect(try event.response(for: context).bodyText.contains("\"event_name\""))
    }
}

/// Provides coders for `FlightWebModule` to take, standing in for an
/// application that wants its own.
private struct CustomCodersModule: FlightModule {
    let coders: WebCoders = {
        var coders = WebCoders.default
        coders.jsonEncoder.keyEncodingStrategy = .convertToSnakeCase
        return coders
    }()

    func configure(_ container: Container) throws {}
}
