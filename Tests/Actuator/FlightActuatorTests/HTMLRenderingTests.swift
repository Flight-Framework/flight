@testable import FlightActuator
import FlightCore
import FlightWeb
import FlightWebTesting
import HTTPTypes
import Testing

@Suite("SSR rendering")
struct HTMLRenderingTests {

    @Test("dashboard serves text/html by default — no config needed")
    func servesHTMLByDefault() async throws {
        let container = try TestContainer.build { ActuatorModule(environment: .dev) }
        let client = try TestClient(container: container)
        let response = await client.get("/actuator")
        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "text/html; charset=utf-8")
        #expect(response.bodyText.contains("<h1>Flight Actuator</h1>"))
    }

    @Test("page lists environment, beans, and layer sections")
    func pageContents() async throws {
        let container = try TestContainer.build {
            ActuatorModule(environment: .staging, exposure: .full)
            SampleAppModule()
        }
        let client = try TestClient(container: container)
        let body = await client.get("/actuator").bodyText

        #expect(body.contains("Environment: <strong>staging</strong>"))
        #expect(body.contains("FlightActuatorTests.SampleService"))
        #expect(body.contains("FlightActuatorTests.SampleRepository"))
        // Layer grouping (Flight Core): non-empty sections render as
        // headed tables, entry points first.
        #expect(body.contains("<h3>Services (1)</h3>"))
        #expect(body.contains("<h3>Repositories (1)</h3>"))
        #expect(body.contains("<h3>Components"))
        // Qualified registrations render distinguishably.
        #expect(body.contains("primary"))
        #expect(body.contains("secondary"))
    }

    @Test("all dynamic strings are HTML-escaped")
    func escapesHostileContent() async throws {
        let container = try TestContainer.build {
            ActuatorModule(environment: .dev)
            HostileQualifierModule()
        }
        let client = try TestClient(container: container)
        let body = await client.get("/actuator").bodyText

        #expect(!body.contains("<script>"))
        #expect(body.contains("&lt;script&gt;alert(&quot;pwned&quot;)&lt;/script&gt;"))
    }

    @Test("a failed module renders its health and error detail")
    func rendersModuleFailure() async throws {
        let app = try Flight.assemble(
            configuration: Configuration(),
            modules: [FailingServiceModule.self]
        )
        let failing = try #require(app.services.first)
        _ = try? await failing.service.run()

        let snapshot = ActuatorSnapshot(container: app.container, environment: .test)
        let html = renderActuatorHTML(snapshot)
        #expect(html.contains("FailingServiceModule"))
        #expect(html.contains(#"<td class="health-failed">failed</td>"#))
        #expect(html.contains("flux capacitor"))
    }

    @Test("empty module list renders a note, not an empty table")
    func emptyModules() throws {
        // TestContainer does no health tracking — exactly the empty case.
        let container = try TestContainer.build { ActuatorModule(environment: .dev) }
        let snapshot = ActuatorSnapshot(container: container, environment: .dev)
        let html = renderActuatorHTML(snapshot)
        #expect(html.contains("<h2>Modules (0)</h2>"))
        #expect(html.contains("No module health recorded."))
    }
}

@Suite("HTML escaping")
struct HTMLEscapingTests {
    @Test("escapes the five significant characters")
    func escapesSignificantCharacters() {
        #expect(htmlEscaped(#"<a href="x">&'"#) == "&lt;a href=&quot;x&quot;&gt;&amp;&#39;")
    }

    @Test("passes ordinary text through untouched")
    func passthrough() {
        #expect(htmlEscaped("FlightCore.Container") == "FlightCore.Container")
        #expect(htmlEscaped("") == "")
        #expect(htmlEscaped("héllo wörld ✈️") == "héllo wörld ✈️")
    }
}
