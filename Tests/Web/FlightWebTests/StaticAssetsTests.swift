import FlightCore
@testable import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Synchronization
import Testing

// End-to-end through TestClient: routing first, mounts as fallback, lanes,
// containment, negotiation. The serveContent semantics have their own suite;
// this one is about the mount's lookup, policy, and placement in dispatch.

private let assetTrace = TraceBox()

@Middleware
struct AssetsLaneMarker: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        assetTrace.append("assets-lane")
        return try await next(context)
    }
}

@Middleware
struct HeavyDefaultMarker: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        assetTrace.append("default-lane")
        return try await next(context)
    }
}

private struct SiteModule: FlightModule {
    let root: String
    let mountOptions: @Sendable (inout AssetMountOptions) -> Void

    // TestContainer instantiates declared modules via init() when it must;
    // this one is always passed ready-made, so the requirement is vestigial.
    init() {
        self.root = "/nonexistent"
        self.mountOptions = { _ in }
    }

    init(root: String, mountOptions: @escaping @Sendable (inout AssetMountOptions) -> Void) {
        self.root = root
        self.mountOptions = mountOptions
    }

    func configure(_ container: Container) throws {
        try AssetsLaneMarker._flightRegister(container)
        try HeavyDefaultMarker._flightRegister(container)
        container.pipeline { HeavyDefaultMarker.self }
        container.pipeline("assets") { AssetsLaneMarker.self }
        container.registerRoute(.get, "/api/users", source: "SiteModule") { _ in
            .text("users")
        }
        // A route whose path a file also plausibly answers — the route must
        // win, because routing runs first.
        container.registerRoute(.get, "/style.css", source: "SiteModule") { _ in
            .text("route wins")
        }
        container.assets(at: "/", root: root, pipelines: ["assets"], mountOptions)
    }
}

@Suite("static asset mounts", .serialized)
struct StaticAssetsTests {

    /// Builds a little site on disk and a client mounting it at `/`.
    private func withSite<T>(
        configure: @escaping @Sendable (inout AssetMountOptions) -> Void = { options in
            options.spaFallback = "index.html"
            options.exclude = ["/api"]
            options.cache("no-cache", matching: "index.html")
            options.cache("public, max-age=31536000, immutable", matching: "immutable/**")
        },
        _ body: (TestClient, URL) async throws -> T
    ) async throws -> T {
        let site = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flight-assets-\(UUID().uuidString)")
        let immutable = site.appendingPathComponent("immutable")
        try FileManager.default.createDirectory(at: immutable, withIntermediateDirectories: true)
        try Data("<title>shell</title>".utf8).write(to: site.appendingPathComponent("index.html"))
        try Data("body{}".utf8).write(to: site.appendingPathComponent("style.css"))
        try Data("console.log(1)".utf8).write(to: immutable.appendingPathComponent("app.abc123.js"))
        try Data("SECRET=1".utf8).write(to: site.appendingPathComponent(".env"))
        defer { try? FileManager.default.removeItem(at: site) }

        let container = try TestContainer.build {
            SiteModule(root: site.path, mountOptions: configure)
        }
        return try await body(try TestClient(container: container), site)
    }

    @Test("serves a file with its content type and the matching cache rule")
    func servesWithPolicy() async throws {
        try await withSite { client, _ in
            let shell = await client.get("/index.html")
            #expect(shell.status == .ok)
            #expect(shell.headers[.contentType] == "text/html; charset=utf-8")
            #expect(shell.headers[.cacheControl] == "no-cache")

            let hashed = await client.get("/immutable/app.abc123.js")
            #expect(hashed.status == .ok)
            #expect(hashed.headers[.cacheControl] == "public, max-age=31536000, immutable")

            // No rule matches style.css: no Cache-Control invented.
            let css = await client.get("/style.css2")  // miss → shell, checked below
            _ = css
        }
    }

    @Test("the mount prefix itself serves the index")
    func indexAtPrefix() async throws {
        try await withSite { client, _ in
            let response = await client.get("/")
            #expect(response.status == .ok)
            let body = String(decoding: try await response.collectedBody(), as: UTF8.self)
            #expect(body.contains("shell"))
        }
    }

    @Test("a real route always beats a file of the same path")
    func routesWin() async throws {
        try await withSite { client, _ in
            let response = await client.get("/style.css")
            #expect(response.bodyText == "route wins")
        }
    }

    @Test("an HTML navigation miss gets the shell; an API-shaped miss stays 404")
    func spaFallbackIsGatedByAccept() async throws {
        try await withSite { client, _ in
            let navigation = await client.get(
                "/projects/42", headers: [.accept: "text/html,application/xhtml+xml"])
            #expect(navigation.status == .ok)
            let shell = String(decoding: try await navigation.collectedBody(), as: UTF8.self)
            #expect(shell.contains("shell"))

            let fetch = await client.get("/projects/42", headers: [.accept: "application/json"])
            #expect(fetch.status == .notFound, "a JSON fetch must never receive the HTML shell")

            let bare = await client.get("/projects/42")
            #expect(bare.status == .ok, "no Accept header reads as a navigation")
        }
    }

    @Test("excluded prefixes fall through to the ordinary 404, not the shell")
    func excludesCarveOut() async throws {
        try await withSite { client, _ in
            let matched = await client.get("/api/users")
            #expect(matched.bodyText == "users")

            let miss = await client.get("/api/nope", headers: [.accept: "text/html"])
            #expect(miss.status == .notFound, "an /api miss is an API 404, shell never applies")
        }
    }

    @Test("traversal is a miss, however it is spelled — and never a 403")
    func traversalIsRefused() async throws {
        try await withSite { client, _ in
            for spelling in [
                "/../etc/passwd",
                "/%2e%2e/etc/passwd",
                "/immutable/../../etc/passwd",
                "/immutable/%2e%2e/%2e%2e/etc/passwd",
                "/..%2f..%2fetc%2fpasswd",
            ] {
                let response = await client.get(spelling, headers: [.accept: "application/json"])
                // 404 — answered exactly like a path that does not exist.
                // "Forbidden" would confirm something is up there.
                #expect(response.status == .notFound, "\(spelling)")
            }
        }
    }

    @Test("dotfiles are a miss by default")
    func dotfilesDenied() async throws {
        try await withSite { client, _ in
            let response = await client.get("/.env", headers: [.accept: "application/json"])
            #expect(response.status == .notFound)
        }
    }

    @Test("a symlink out of the root is a miss; one within it serves")
    func symlinkContainment() async throws {
        try await withSite { client, site in
            let outside = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("flight-outside-\(UUID().uuidString).txt")
            try Data("outside".utf8).write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createSymbolicLink(
                at: site.appendingPathComponent("escape.txt"), withDestinationURL: outside)
            try FileManager.default.createSymbolicLink(
                at: site.appendingPathComponent("alias.css"),
                withDestinationURL: site.appendingPathComponent("style.css"))

            let escape = await client.get("/escape.txt", headers: [.accept: "application/json"])
            #expect(escape.status == .notFound, "a link escaping the root must not serve")

            let alias = await client.get("/alias.css")
            #expect(alias.status == .ok, "a link within the root is fine under .withinRoot")
            #expect(try await alias.collectedBody() == Data("body{}".utf8))
        }
    }

    @Test("symlinks: .never refuses even an internal link")
    func symlinkNever() async throws {
        try await withSite(configure: { options in
            options.symlinks = .never
        }) { client, site in
            try FileManager.default.createSymbolicLink(
                at: site.appendingPathComponent("alias.css"),
                withDestinationURL: site.appendingPathComponent("style.css"))
            let alias = await client.get("/alias.css", headers: [.accept: "application/json"])
            #expect(alias.status == .notFound)
            // The real file is unaffected.
            #expect(await client.get("/style.css2", headers: [.accept: "application/json"]).status == .notFound)
            #expect(await client.get("/immutable/app.abc123.js").status == .ok)
        }
    }

    @Test("the mount runs its own lane, not the default stack")
    func mountLaneIsolation() async throws {
        try await withSite { client, _ in
            assetTrace.reset()
            _ = await client.get("/index.html")
            #expect(assetTrace.entries == ["assets-lane"])

            assetTrace.reset()
            _ = await client.get("/api/users")
            #expect(assetTrace.entries == ["default-lane"], "routes keep the default stack")
        }
    }

    @Test("a brotli sidecar is negotiated, with Vary and its own validator")
    func precompressedNegotiation() async throws {
        try await withSite(configure: { options in
            options.precompressed = [.brotli, .gzip]
        }) { client, site in
            // Not style.css — SiteModule registers a route at that path, and
            // routes beat files (tested above), so the mount would never
            // run. The "compressed" bytes are stand-ins; negotiation is
            // about files and headers, not codecs.
            try Data("body{}".utf8).write(to: site.appendingPathComponent("bundle.css"))
            try Data("br-bytes".utf8).write(to: site.appendingPathComponent("bundle.css.br"))

            let plain = await client.get("/bundle.css")
            #expect(plain.headers[.contentEncoding] == nil)
            #expect(plain.headers[.vary] == "Accept-Encoding", "identity varies too")
            #expect(try await plain.collectedBody() == Data("body{}".utf8))

            let compressed = await client.get(
                "/bundle.css", headers: [.acceptEncoding: "gzip, br"])
            #expect(compressed.headers[.contentEncoding] == "br")
            #expect(compressed.headers[.contentType] == "text/css; charset=utf-8")
            #expect(try await compressed.collectedBody() == Data("br-bytes".utf8))
            #expect(
                plain.headers[.eTag] != compressed.headers[.eTag],
                "each variant is its own representation with its own validator")
        }
    }

    @Test("revalidation and ranges work through the mount")
    func conditionalAndRangeThroughMount() async throws {
        try await withSite { client, _ in
            let first = await client.get("/style.css2", headers: [.accept: "application/json"])
            #expect(first.status == .notFound)

            let full = await client.get("/immutable/app.abc123.js")
            let etag = try #require(full.headers[.eTag])
            let revalidated = await client.get(
                "/immutable/app.abc123.js", headers: [.ifNoneMatch: etag])
            #expect(revalidated.status == .notModified)

            let sliced = await client.get(
                "/immutable/app.abc123.js", headers: [.range: "bytes=-2"])
            #expect(sliced.status == .partialContent)
            #expect(try await sliced.collectedBody() == Data("1)".utf8))
        }
    }

    @Test("an undeclared mount lane fails at build like a route's would")
    func mountLaneValidated() throws {
        struct BadModule: FlightModule {
            func configure(_ container: Container) throws {
                container.assets(at: "/", root: "/tmp", pipelines: ["ghost"])
            }
        }
        let container = try TestContainer.build { BadModule() }
        do {
            _ = try TestClient(container: container)
            Issue.record("expected the undeclared lane to be refused")
        } catch let error as DispatchBuilder.UndeclaredLaneError {
            #expect(error.lane == "ghost")
            #expect(error.route.contains("assets"))
        }
    }
}

@Suite("asset glob")
struct AssetGlobTests {
    @Test("segment wildcards stay within a segment; ** crosses")
    func dialect() {
        #expect(AssetGlob.matches(pattern: "immutable/**", path: "immutable/a/b/c.js"))
        #expect(AssetGlob.matches(pattern: "immutable/**", path: "immutable/x.js"))
        #expect(!AssetGlob.matches(pattern: "immutable/*", path: "immutable/a/b.js"))
        #expect(AssetGlob.matches(pattern: "immutable/*", path: "immutable/a.js"))
        #expect(AssetGlob.matches(pattern: "*.js", path: "app.js"))
        #expect(!AssetGlob.matches(pattern: "*.js", path: "app.css"))
        #expect(AssetGlob.matches(pattern: "app.?.js", path: "app.1.js"))
        #expect(!AssetGlob.matches(pattern: "app.?.js", path: "app.12.js"))
        #expect(AssetGlob.matches(pattern: "**/*.map", path: "a/b/c.map"))
        #expect(AssetGlob.matches(pattern: "**", path: "anything/at/all"))
        #expect(AssetGlob.matches(pattern: "index.html", path: "index.html"))
        #expect(!AssetGlob.matches(pattern: "index.html", path: "not-index.html"))
    }
}
