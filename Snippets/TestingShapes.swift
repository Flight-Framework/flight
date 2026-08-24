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
struct SnippetModule: FlightModule {
    init() {}
    func configure(_ container: Container) throws {}
}
// snippet.show

func testingShapes() throws {
    // Components registers named components; TestClient dispatches in process.
    let container = try TestContainer.build {
        SnippetModule()
    }
    _ = try TestClient(container: container)

    // A context for calling a handler directly.
    _ = RequestContext.mock(container: container)

    // Overriding one seam in a booted graph.
    _ = try TestContainer.build {
        SnippetModule()
    } overriding: { container in
        container.override(String.self, scope: .singleton) { _ in "fake" }
    }

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
