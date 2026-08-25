import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

@main
struct FlightSchedulerMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        SchedulerMacro.self,
        ScheduledMacro.self,
    ]
}

/// Same diagnostic discipline as the other macro modules: every diagnostic
/// names the fix, not just the problem. These fire at build time and are the
/// compile-time-first pitch's first impression.
struct FlightMacroDiagnostic: DiagnosticMessage {
    let message: String
    let id: String
    let severity: DiagnosticSeverity

    var diagnosticID: MessageID { MessageID(domain: "FlightSchedulerMacros", id: id) }

    static func error(_ id: String, _ message: String) -> FlightMacroDiagnostic {
        FlightMacroDiagnostic(message: message, id: id, severity: .error)
    }
}

extension MacroExpansionContext {
    func diagnoseError(_ id: String, _ message: String, at node: some SyntaxProtocol) {
        diagnose(Diagnostic(node: Syntax(node), message: FlightMacroDiagnostic.error(id, message)))
    }
}
