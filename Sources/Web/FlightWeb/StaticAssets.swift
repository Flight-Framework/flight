import FlightCore
import Foundation
import HTTPTypes

// Static assets as a *fallback*, not a route: a mount claims a path prefix
// and answers GET/HEAD requests the router did not — nginx's location/
// try_files model rather than a middleware or a catch-all route. Real routes
// win structurally (they matched first), matched routes pay nothing for the
// mount's existence, and a miss under the mount is the mount's to answer.
// Each mount runs its own pipeline lanes, which is the whole reason lanes
// exist: an asset request should not lease a database connection because the
// application's default stack binds transactions.

/// Configuration for one asset mount. Mutate inside the closure
/// `container.assets(at:root:pipelines:_:)` hands you.
public struct AssetMountOptions: Sendable {
    /// Serve this file (relative to the root) for GET/HEAD misses whose
    /// `Accept` prefers HTML — the single-page-app shell. The gate is what
    /// keeps an API-shaped miss an API-shaped 404: a `fetch` sending
    /// `Accept: application/json` never receives the shell.
    public var spaFallback: String?

    /// The file served when the request path is the mount prefix itself or
    /// ends in `/`.
    public var index: String = "index.html"

    /// Path prefixes (relative to the mount, `/`-prefixed) carved out of the
    /// mount entirely — requests under them fall through to the ordinary
    /// 404 path, shell fallback included. The escape hatch for `/api` under
    /// a `/` mount.
    public var exclude: [String] = []

    public enum SymlinkPolicy: Sendable {
        /// Symlinks resolve, but the resolved file must still live under the
        /// root — a link *within* the built site works, a link escaping it
        /// is a miss. The default: safe, and tolerant of bundlers that
        /// symlink.
        case withinRoot
        /// No symlink anywhere in the served path. The strictest posture.
        case never
        /// Follow anywhere, containment unchecked. For roots that
        /// deliberately link elsewhere; the name is a warning.
        case anywhere
    }
    public var symlinks: SymlinkPolicy = .withinRoot

    public enum ETagPolicy: Sendable {
        /// Device/inode/size/mtime-ns — free (one fstat, already paid) and
        /// weak: correct for ordinary caching, but `If-Range` refuses weak
        /// validators, so careful download managers re-fetch in full, and
        /// tags churn on redeploys that rewrite mtimes without changing
        /// bytes.
        case fileIdentity
        /// SHA-256 of the content, cached by file identity
        /// (``ContentHashCache``): strong — `If-Range` resumption works —
        /// and restart-stable. Costs one full read per file per identity
        /// change.
        case contentHash
    }
    /// How this mount's validators are built.
    public var etag: ETagPolicy = .fileIdentity

    public enum DotfilePolicy: Sendable {
        /// Any `.`-prefixed path component is a miss. The default —
        /// `.env`, `.git`, `.htpasswd` in a served directory is a breach
        /// dressed as a convenience.
        case deny
        case allow
    }
    public var dotfiles: DotfilePolicy = .deny

    public enum PrecompressedEncoding: String, Sendable, CaseIterable {
        case brotli = "br"
        case gzip = "gzip"
        var suffix: String {
            switch self {
            case .brotli: return ".br"
            case .gzip: return ".gz"
            }
        }
    }
    /// Sidecar encodings to negotiate, in preference order: `app.js.br`
    /// beside `app.js` is served as `Content-Encoding: br` to clients that
    /// accept it, with `Vary: Accept-Encoding` on every response either way.
    /// Compression happens at build time, where effort is free — never here.
    public var precompressed: [PrecompressedEncoding] = []

    /// Extension (lowercased, no dot) → Content-Type overrides, consulted
    /// before the built-in table.
    public var contentTypes: [String: String] = [:]

    var cacheRules: [(pattern: String, value: String)] = []

    /// Adds a Cache-Control rule: the first pattern to match the
    /// mount-relative path wins, so list the specific before the general. A
    /// pattern without `/` matches the file's name wherever it sits
    /// (`"sw.js"`, `"index.html"`); one with `/` matches the whole relative
    /// path, where `*`/`?` stay within a segment and `**` crosses them
    /// (`"_app/immutable/**"`).
    ///
    /// Path-predicated deliberately: keying cache policy on media type
    /// cannot express the one split every SPA needs — content-hashed
    /// `app.a1b2c3.js` immutable forever, `sw.js` revalidated always —
    /// because both are JavaScript.
    public mutating func cache(_ value: String, matching patterns: String...) {
        for pattern in patterns {
            cacheRules.append((pattern, value))
        }
    }

    public var chunkSize: Int = FileByteSource.defaultChunkSize

    public init() {}
}

/// One configured mount, registered as an ordinary component so it appears
/// in introspection like everything else. Collected by `DispatchBuilder`.
public struct AssetMountRegistration: Sendable {
    public let prefix: String
    public let root: String
    public let pipelines: [String]
    public let options: AssetMountOptions
    /// Present exactly when `options.etag == .contentHash` — constructed
    /// with the mount, so "declared but never initialized" cannot happen.
    let hashCache: ContentHashCache?
}

extension Container {
    /// Mounts a directory of static files at `prefix`, served with full
    /// conditional-request and range semantics, as a fallback after routing:
    /// a real route always wins, and requests under the prefix that match
    /// no route and no file are the mount's misses (shell fallback, then
    /// 404). Mounts are consulted in registration order.
    ///
    /// `pipelines` defaults to the default lane, same as every route —
    /// consistent, not clever. The intended production shape is a dedicated
    /// lean lane, declared where the mount is:
    ///
    /// ```swift
    /// container.pipeline("assets") { RequestLogging.self }
    /// container.assets(at: "/", root: "web/build", pipelines: ["assets"]) { options in
    ///     options.spaFallback = "index.html"
    ///     options.exclude = ["/api", "/actuator"]
    ///     options.cache("no-cache", matching: "index.html")
    ///     options.cache("public, max-age=31536000, immutable", matching: "_app/immutable/**")
    /// }
    /// ```
    public func assets(
        at prefix: String = "/",
        root: String,
        pipelines: [String] = [MiddlewareRegistration.defaultLane],
        _ configure: (inout AssetMountOptions) -> Void = { _ in }
    ) {
        var options = AssetMountOptions()
        configure(&options)
        let hashCache: ContentHashCache?
        if case .contentHash = options.etag {
            hashCache = ContentHashCache()
        } else {
            hashCache = nil
        }
        let registration = AssetMountRegistration(
            prefix: prefix.hasSuffix("/") && prefix != "/" ? String(prefix.dropLast()) : prefix,
            root: root, pipelines: pipelines, options: options, hashCache: hashCache)
        register(
            AssetMountRegistration.self, qualifier: "assets.\(registration.prefix)",
            scope: .singleton
        ) { _ in registration }
    }

    /// All mounts, in registration order (post-freeze).
    public func collectAssetMounts() throws -> [AssetMountRegistration] {
        let typeName = String(reflecting: AssetMountRegistration.self)
        return try allRegistrations()
            .filter { $0.typeName == typeName }
            .map { try resolve(AssetMountRegistration.self, qualifier: $0.qualifier) }
    }
}

// MARK: - Serving

extension AssetMountRegistration {

    /// Whether this mount is willing to answer a routing miss for `request`.
    /// Method, prefix, and excludes only — existence comes later, inside the
    /// mount's own lane.
    func claims(_ request: Request) -> Bool {
        guard request.method == .get || request.method == .head else { return false }
        guard let relative = relativePath(of: request.path) else { return false }
        // Decoded first, as `serveExisting` does. Comparing the raw
        // percent-encoded path meant `/%61pi/users` did not match an `/api`
        // exclusion — so an encoded spelling of an excluded prefix was
        // claimed by the mount and (with an HTML-ish Accept) answered with
        // the SPA shell instead of the API-shaped 404. No containment breach,
        // but the documented invariant failed for exactly the spelling
        // someone probing would use.
        let candidate = "/" + (relative.removingPercentEncoding ?? relative)
        for excluded in options.exclude {
            let normalized = excluded.hasPrefix("/") ? excluded : "/" + excluded
            if candidate == normalized || candidate.hasPrefix(normalized + "/") {
                return false
            }
        }
        return true
    }

    private func relativePath(of requestPath: String) -> String? {
        if prefix == "/" {
            return String(requestPath.dropFirst())
        }
        guard requestPath == prefix || requestPath.hasPrefix(prefix + "/") else { return nil }
        return String(requestPath.dropFirst(prefix.count).drop(while: { $0 == "/" }))
    }

    /// The terminal of the mount's lane chain: look the file up under the
    /// containment rules, serve it through `serveContent`, or answer the
    /// miss (shell, then 404).
    func respond(to context: RequestContext) async -> Response {
        guard var relative = relativePath(of: context.request.path) else {
            return context.coders.renderError(.notFound, "Not Found")
        }
        if relative.isEmpty || relative.hasSuffix("/") {
            relative += options.index
        }

        if let response = await serveExisting(path: relative, context: context) {
            return response
        }

        // Miss. The shell, for a navigation; the ordinary 404 for anything
        // else — the Accept gate is what keeps API misses API-shaped.
        if let shell = options.spaFallback,
            prefersHTML(context.request.headers[.accept]),
            let response = await serveExisting(path: shell, context: context)
        {
            return response
        }
        return context.coders.renderError(.notFound, "Not Found")
    }

    private func prefersHTML(_ accept: String?) -> Bool {
        // Absent (curl, health checks poking around) counts as a navigation;
        // an explicit Accept that never mentions HTML does not.
        //
        // `*/*` deliberately does *not* count, and that is a change: it did,
        // and `fetch()`'s own default Accept is `*/*`, so the promise that "a
        // fetch never receives the shell" held only for fetches that set
        // Accept explicitly — which is to say, not the common case. A browser
        // navigation always sends `text/html` in its Accept; a bare `*/*` is
        // a programmatic client.
        guard let accept else { return true }
        return accept.contains("text/html")
    }

    /// The codings a client actually accepts, `q=0` excluded.
    ///
    /// A `contains` over the raw header treated `gzip;q=0` — which is RFC
    /// 9110's way of saying "not gzip" — as acceptance, and sent gzip to a
    /// client that had explicitly refused it.
    static func acceptedEncodings(_ header: String) -> Set<String> {
        var accepted: Set<String> = []
        for entry in header.split(separator: ",") {
            let parts = entry.split(separator: ";")
            guard let name = parts.first?.trimmingCharacters(in: .whitespaces).lowercased(),
                !name.isEmpty
            else { continue }
            let refused = parts.dropFirst().contains { parameter in
                let text = parameter.trimmingCharacters(in: .whitespaces).lowercased()
                guard text.hasPrefix("q=") else { return false }
                return Double(text.dropFirst(2)).map { $0 <= 0 } ?? false
            }
            if !refused { accepted.insert(name) }
        }
        return accepted
    }

    /// nil = not servable (missing, escaped, denied) — distinct from an
    /// error response, so the caller can fall back.
    private func serveExisting(path relative: String, context: RequestContext) async -> Response? {
        // Decode before any inspection, and refuse what cannot decode — a
        // traversal spelled %2e%2e must be seen as the dots it is.
        guard let decoded = relative.removingPercentEncoding, !decoded.contains("\0") else {
            return nil
        }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: true)
        // `..` as a *component*, post-decoding — the lexical gate. (A
        // substring check would also reject `v1..2.json`, a legal name.)
        guard !components.contains("..") else { return nil }
        if case .deny = options.dotfiles {
            guard !components.contains(where: { $0.hasPrefix(".") }) else { return nil }
        }

        let candidate = root + "/" + components.joined(separator: "/")

        // Resolve-then-contain: ask the filesystem where the path actually
        // lands, then require that to be under the resolved root. This is
        // the check percent-encoding and symlinks cannot lie to — rejecting
        // spellings is a guess; comparing resolutions is an answer.
        guard let resolvedRoot = await FileByteSource.realPath(root),
            let resolved = await FileByteSource.realPath(candidate),
            resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/")
        else { return nil }
        if case .never = options.symlinks {
            // No link anywhere: the resolution must be exactly the lexical
            // path — any difference means something linked.
            guard resolved == resolvedRoot + "/" + components.joined(separator: "/") else {
                return nil
            }
        }
        if case .anywhere = options.symlinks {
            // Containment deliberately waived — but the lexical gates above
            // (.., dotfiles, NUL) still applied.
        }

        let servePath = options.symlinks.isAnywhere ? candidate : resolved
        guard let source = try? await FileByteSource.open(atPath: servePath) else {
            return nil
        }

        var extraHeaders: HTTPFields = [:]
        var chosen: any ByteSource = source
        var etag = await validator(for: source)
        if !options.precompressed.isEmpty {
            extraHeaders[.vary] = "Accept-Encoding"
            let accepted = Self.acceptedEncodings(context.request.headers[.acceptEncoding] ?? "")
            for encoding in options.precompressed where accepted.contains(encoding.rawValue) {
                if let sidecar = try? await FileByteSource.open(atPath: servePath + encoding.suffix) {
                    chosen = sidecar
                    // The variant is its own representation: its own bytes,
                    // its own validator — a 304 for the brotli variant must
                    // never validate the identity bytes. Under contentHash
                    // the sidecar's own digest is already distinct; under
                    // identity the encoding suffix keeps it so.
                    let sidecarTag = await validator(for: sidecar)
                    etag = sidecarTag.isWeak
                        ? EntityTag(sidecarTag.value + "-" + encoding.rawValue, weak: true)
                        : sidecarTag
                    extraHeaders[.contentEncoding] = encoding.rawValue
                    break
                }
            }
        }

        return serveContent(
            for: context.request,
            ContentDescriptor(
                source: chosen,
                contentType: contentType(for: decoded),
                modificationDate: source.modificationDate,
                etag: etag,
                cacheControl: cacheControl(for: decoded),
                extraHeaders: extraHeaders,
                chunkSize: options.chunkSize))
    }

    /// The mount's validator for one open file, per its ETag policy. A
    /// hashing failure (file vanished mid-read) falls back to the identity
    /// tag: a weak validator beats no validator, and the request itself
    /// will surface the real error if the file is truly gone.
    private func validator(for source: FileByteSource) async -> EntityTag {
        guard let hashCache else { return .file(source) }
        return (try? await hashCache.strongTag(for: source)) ?? .file(source)
    }

    private func contentType(for relative: String) -> String? {
        let name = relative.split(separator: "/").last.map(String.init) ?? relative
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = String(name[name.index(after: dot)...]).lowercased()
        if let override = options.contentTypes[ext] { return override }
        return Self.builtinContentTypes[ext]
    }

    private func cacheControl(for relative: String) -> String? {
        let name = relative.split(separator: "/").last.map(String.init) ?? relative
        for rule in options.cacheRules {
            let subject = rule.pattern.contains("/") ? relative : name
            if AssetGlob.matches(pattern: rule.pattern, path: subject) {
                return rule.value
            }
        }
        return nil
    }

    static let builtinContentTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "map": "application/json",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "avif": "image/avif",
        "ico": "image/x-icon",
        "woff2": "font/woff2",
        "woff": "font/woff",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "txt": "text/plain; charset=utf-8",
        "xml": "application/xml; charset=utf-8",
        "pdf": "application/pdf",
        "wasm": "application/wasm",
        "webmanifest": "application/manifest+json",
        "mp4": "video/mp4",
        "webm": "video/webm",
        "mp3": "audio/mpeg",
    ]
}

extension AssetMountOptions.SymlinkPolicy {
    var isAnywhere: Bool {
        if case .anywhere = self { return true }
        return false
    }
}

/// The mount's glob dialect: `*` and `?` within one path segment, `**`
/// across segments. Small on purpose — three metacharacters cover every
/// cache-rule pattern a built site needs, and a dialect small enough to hold
/// in your head does not surprise you at deploy time.
enum AssetGlob {
    static func matches(pattern: String, path: String) -> Bool {
        matchSegments(
            ArraySlice(pattern.split(separator: "/", omittingEmptySubsequences: true)),
            ArraySlice(path.split(separator: "/", omittingEmptySubsequences: true)))
    }

    private static func matchSegments(
        _ pattern: ArraySlice<Substring>, _ path: ArraySlice<Substring>
    ) -> Bool {
        guard let first = pattern.first else { return path.isEmpty }
        if first == "**" {
            // Zero or more whole segments.
            var rest = path
            while true {
                if matchSegments(pattern.dropFirst(), rest) { return true }
                guard rest.first != nil else { return false }
                rest = rest.dropFirst()
            }
        }
        guard let segment = path.first, matchSegment(first, segment) else { return false }
        return matchSegments(pattern.dropFirst(), path.dropFirst())
    }

    private static func matchSegment(_ pattern: Substring, _ segment: Substring) -> Bool {
        // Classic backtracking wildcard match, one segment at a time.
        var p = pattern.startIndex
        var s = segment.startIndex
        var starPattern: Substring.Index?
        var starSegment: Substring.Index?
        while s < segment.endIndex {
            if p < pattern.endIndex, pattern[p] == "*" {
                starPattern = pattern.index(after: p)
                starSegment = s
                p = starPattern!
            } else if p < pattern.endIndex, pattern[p] == "?" || pattern[p] == segment[s] {
                p = pattern.index(after: p)
                s = segment.index(after: s)
            } else if let restart = starPattern {
                starSegment = segment.index(after: starSegment!)
                s = starSegment!
                p = restart
            } else {
                return false
            }
        }
        while p < pattern.endIndex, pattern[p] == "*" { p = pattern.index(after: p) }
        return p == pattern.endIndex
    }
}
