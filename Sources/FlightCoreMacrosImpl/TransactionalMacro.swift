import SwiftSyntax
import SwiftSyntaxMacros

/// `@Transactional`: a flat, inspectable rewrite of the method body —
/// no runtime proxy, no subclassing. Implemented as an SE-0415 function body
/// macro (Swift 6.1+).
///
/// Shape of the expansion (the fixtures in FlightCoreMacroTests pin the exact
/// text). Sync methods call the sync coordinator directly:
///
///     let _flightTx = try FlightCore.FlightTransactions.coordinator.begin()
///     do {
///         let _flightResult: R = try { () throws -> R in
///             <original body>
///         }()
///         try FlightCore.FlightTransactions.coordinator.commit(_flightTx)
///         return _flightResult
///     } catch {
///         FlightCore.FlightTransactions.coordinator.rollback(_flightTx)
///         throw error
///     }
///
/// Async methods route through the preferring-async helpers (delta 14) so an
/// async-native coordinator is awaited when bound, with fallback to the sync
/// coordinator otherwise:
///
///     let _flightTx = try await FlightCore.FlightTransactions.beginPreferringAsync()
///     do {
///         let _flightResult: R = try await { () async throws -> R in
///             <original body>
///         }()
///         try await FlightCore.FlightTransactions.commitPreferringAsync(_flightTx)
///         return _flightResult
///     } catch {
///         await FlightCore.FlightTransactions.rollbackPreferringAsync(_flightTx)
///         throw error
///     }
///
/// Two details are load-bearing:
/// - The original body is wrapped in an *immediately invoked* closure literal
///   so that `return` statements inside it keep their meaning. Immediately
///   invoked literals are non-escaping, so implicit `self` in the body stays
///   legal.
/// - The closure carries an explicit signature (`() async throws -> R`) so
///   the wrapper never depends on inference from the body, and `try` on a
///   body that happens not to throw doesn't warn.
public struct TransactionalMacro: BodyMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in context: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        guard let function = declaration.as(FunctionDeclSyntax.self) else {
            context.diagnoseError(
                "transactional.notfunction",
                "@Transactional can only be attached to a method or function.",
                at: node
            )
            return existingBody(of: declaration)
        }
        guard let body = function.body else {
            context.diagnoseError(
                "transactional.nobody",
                "@Transactional requires a function with a body.",
                at: function
            )
            return []
        }

        let effects = function.signature.effectSpecifiers
        guard effects?.throwsClause != nil else {
            // Rollback semantics are meaningless without an error path, and
            // begin/commit themselves throw. Forcing `throws` keeps failure
            // handling visible in the signature.
            context.diagnoseError(
                "transactional.nonthrowing",
                "@Transactional requires a throwing method — mark it 'throws' (rollback needs an error path).",
                at: function.name
            )
            return existingBody(of: declaration)
        }
        let isAsync = effects?.asyncSpecifier != nil

        let returnType = function.signature.returnClause?.type.trimmedDescription ?? "Void"
        let isVoid = returnType == "Void" || returnType == "()"
        let normalizedReturn = isVoid ? "Void" : returnType

        let effect = isAsync ? "try await" : "try"
        let closureSignature =
            isAsync
            ? "() async throws -> \(normalizedReturn)"
            : "() throws -> \(normalizedReturn)"
        let bodyText = body.statements.trimmedDescription

        // Async methods route through FlightTransactions' preferring-async
        // helpers (delta 14): the async-native coordinator when one is bound,
        // else the sync coordinator — selection at runtime, expansion flat.
        // Sync methods can't await, so they call the sync coordinator
        // directly, exactly as before.
        let begin: DeclSyntax =
            isAsync
            ? "let _flightTx = try await FlightCore.FlightTransactions.beginPreferringAsync()"
            : "let _flightTx = try FlightCore.FlightTransactions.coordinator.begin()"
        let commitCall =
            isAsync
            ? "try await FlightCore.FlightTransactions.commitPreferringAsync(_flightTx)"
            : "try FlightCore.FlightTransactions.coordinator.commit(_flightTx)"
        let rollbackCall =
            isAsync
            ? "await FlightCore.FlightTransactions.rollbackPreferringAsync(_flightTx)"
            : "FlightCore.FlightTransactions.coordinator.rollback(_flightTx)"

        let doCatch: StmtSyntax
        if isVoid {
            doCatch = """
                do {
                    \(raw: effect) { \(raw: closureSignature) in
                        \(raw: bodyText)
                    }()
                    \(raw: commitCall)
                } catch {
                    \(raw: rollbackCall)
                    throw error
                }
                """
        } else {
            doCatch = """
                do {
                    let _flightResult: \(raw: normalizedReturn) = \(raw: effect) { \(raw: closureSignature) in
                        \(raw: bodyText)
                    }()
                    \(raw: commitCall)
                    return _flightResult
                } catch {
                    \(raw: rollbackCall)
                    throw error
                }
                """
        }

        return [
            CodeBlockItemSyntax(item: .decl(begin)),
            CodeBlockItemSyntax(item: .stmt(doCatch)),
        ]
    }

    /// On a diagnosed error, return the original body unchanged so the user
    /// sees exactly one error (the diagnostic), not a cascade from a mangled
    /// expansion.
    private static func existingBody(
        of declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax
    ) -> [CodeBlockItemSyntax] {
        declaration.body.map { Array($0.statements) } ?? []
    }
}
