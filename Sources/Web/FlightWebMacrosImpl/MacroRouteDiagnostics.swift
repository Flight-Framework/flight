import FlightRouteScan
import SwiftSyntax
import SwiftSyntaxMacros

/// Routes `RouteScanning`'s diagnostics back into the macro expansion that
/// asked for the scan, so they render inline at the attribute exactly as
/// they did when the scanner held the context itself.
struct MacroRouteDiagnostics<Context: MacroExpansionContext>: RouteDiagnostics {
    let context: Context

    func error(_ id: String, _ message: String, at node: some SyntaxProtocol) {
        context.diagnoseError(id, message, at: node)
    }

    func warning(_ id: String, _ message: String, at node: some SyntaxProtocol) {
        context.diagnoseWarning(id, message, at: node)
    }
}
