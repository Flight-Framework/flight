import SwiftSyntax
import SwiftSyntaxMacros

/// `@Scheduled` — a pure marker, mirroring `@GetRoute`.
///
/// All generated code lives in `@Scheduler`'s expansion, which reads these
/// attributes off the methods. This macro's own expansion is empty; its job
/// is to validate the attachment site and the schedule so misuse fails *at
/// the method*, rather than somewhere inside the enclosing type's expansion
/// where the message would point at the wrong line.
public struct ScheduledMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let function = declaration.as(FunctionDeclSyntax.self) else {
            context.diagnoseError(
                "scheduled.notfunction",
                "@Scheduled can only be attached to a method.",
                at: node)
            return []
        }
        // Validates the signature and the cron expression, emitting its own
        // diagnostics; the result is discarded because `@Scheduler` rescans.
        _ = JobScanning.scanJob(function: function, attribute: node, in: context)
        return []
    }
}
