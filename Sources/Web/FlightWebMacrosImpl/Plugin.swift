import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

@main
struct FlightWebMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ControllerMacro.self,
        RouteMappingMacro.self,
        MiddlewareMacro.self,
    ]
}

/// Same diagnostic discipline as FlightCoreMacrosImpl: every diagnostic
/// names the fix, not just the problem — these fire at build time and are
/// the compile-time-first pitch's first impression (§4).
struct FlightMacroDiagnostic: DiagnosticMessage {
    let message: String
    let id: String
    let severity: DiagnosticSeverity

    var diagnosticID: MessageID { MessageID(domain: "FlightWebMacros", id: id) }

    static func error(_ id: String, _ message: String) -> FlightMacroDiagnostic {
        FlightMacroDiagnostic(message: message, id: id, severity: .error)
    }
}

extension MacroExpansionContext {
    func diagnoseError(_ id: String, _ message: String, at node: some SyntaxProtocol) {
        diagnose(Diagnostic(node: Syntax(node), message: FlightMacroDiagnostic.error(id, message)))
    }
}
