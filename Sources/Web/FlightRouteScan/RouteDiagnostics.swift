import SwiftSyntax

/// Where a route-scanning diagnostic goes.
///
/// The scan itself is the same work in both places that need it — the
/// `@Controller` macro expanding one file, and `flight-registration-gen`
/// building the static route manifest across a whole target — but the two
/// report differently. A macro calls `context.diagnose`, which Xcode and
/// SourceKit render inline at the attribute. A build-tool plugin has no such
/// channel and writes `file:line:col: error:` to stderr for the compiler to
/// pick up.
///
/// That difference is the *only* reason `RouteScanning` used to require a
/// `MacroExpansionContext`, and it was enough to keep the route table
/// invisible to the generator: an attached macro sees one file, so nothing
/// could answer "what are all the routes in this target" at build time.
/// Naming the sink separates the reporting from the scanning, and both
/// callers get the same paths, the same validation, and the same messages.
///
/// Deliberately generic over the node rather than taking an existential:
/// conformers hold a `MacroExpansionContext` or a source location converter,
/// and neither wants the node erased.
public protocol RouteDiagnostics {
    func error(_ id: String, _ message: String, at node: some SyntaxProtocol)
    func warning(_ id: String, _ message: String, at node: some SyntaxProtocol)
}
