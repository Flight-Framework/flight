// The API shapes Docs/testing.md shows, compiled by the build.
//
// A page that shows an API is a claim about that API. Compiling the shapes
// makes a signature change break the build rather than only mislead a reader —
// this file already caught `InMemoryCluster(nodes:)`, which never existed.
//
// Only the helpers this package ships. flight-data's cache and data testing
// libraries are compiled by its own snippet.
import FlightChannelsTesting
import FlightCore
import FlightPubSub
import FlightPubSubTesting
import FlightWeb
import FlightWebTesting
import Foundation

// snippet.hide
struct FakeRepo: Sendable { func all() -> [String] { [] } }
struct GreetController {
    let repo: FakeRepo
    func index(_ context: RequestContext) -> [String] { repo.all() }
}
// snippet.show

func testingShapes() async throws {
    // A controller is a struct and a route is a method: construct it with
    // fakes and call the method directly — no container, no dispatch.
    let controller = GreetController(repo: FakeRepo())
    _ = controller.index(.mock())

    // A TestClient when the pipeline itself is under test — built from route
    // values, the way a composition root hands them to FlightWebModule.
    _ = try TestClient(routes: [])

    // PubSub: a cluster with no network, one adapter per node.
    let cluster = InMemoryCluster()
    _ = cluster.makeAdapter()
    _ = cluster.makeAdapter()

    // And the simpler recorder.
    let recorder = RecordingAdapter()
    _ = recorder.broadcasts

    // The cache helpers live in flight-data, so they are compiled by that
    // package's snippet rather than this one.
}
