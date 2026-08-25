import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Scheduler` — the type-level half, mirroring `@Controller`.
///
/// A `@Scheduler` type is an ordinary singleton component: it may inject
/// dependencies with `@Autowired` exactly as any other component does. What
/// this macro adds is one `ScheduledJobRegistration` per `@Scheduled` method,
/// registered into the same container as everything else. Scheduling is not a
/// separate system from dependency injection.
///
/// A separate attribute rather than teaching `@Component` about `@Scheduled`,
/// because that would make FlightCore's macros depend on the scheduler's
/// vocabulary — the same reason `@Controller` exists rather than `@Component`
/// growing route awareness.
public struct SchedulerMacro: MemberMacro, ExtensionMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(ClassDeclSyntax.self) || declaration.is(StructDeclSyntax.self) else {
            context.diagnoseError(
                "scheduler.notatype",
                "@Scheduler can only be attached to a class or struct.",
                at: node)
            return []
        }

        let jobs = JobScanning.scanJobs(of: declaration.memberBlock.members, in: context)
        guard !jobs.isEmpty else {
            context.diagnoseError(
                "scheduler.nojobs",
                """
                @Scheduler type has no @Scheduled methods, so it schedules nothing. Add \
                one, or drop @Scheduler and use @Component if this is an ordinary \
                component.
                """,
                at: node)
            return []
        }

        // Duplicate method names cannot happen, but duplicate *job* names can
        // if someone hand-registers the same qualifier. The qualifier embeds
        // the fully-qualified type so two schedulers may share a method name.
        var lines: [String] = []
        for job in jobs {
            lines.append(contentsOf: registrationLines(for: job))
        }

        let access = declaration.modifiers.contains {
            $0.name.tokenKind == .keyword(.public) || $0.name.tokenKind == .keyword(.open)
        } ? "public " : ""

        let thunk: DeclSyntax = """
            \(raw: access)static func _flightRegister(_ container: FlightCore.Container) throws {
            \(raw: lines.map { "    " + $0 }.joined(separator: "\n"))
            }
            """
        return [thunk]
    }

    private static func registrationLines(for job: ScannedJob) -> [String] {
        var call = "component.\(job.methodName)()"
        if job.isAsync { call = "await \(call)" }
        if job.isThrows { call = "try \(call)" }

        let trigger: String
        switch job.schedule {
        case .cron(let text, let timeZone):
            // Force-try is safe here and nowhere else: the expression was
            // parsed by this same parser at compile time, so a throw is
            // impossible unless the macro and the runtime disagree — which
            // sharing one parser rules out.
            trigger =
                "FlightScheduler.JobTrigger.cron("
                + "try! FlightScheduler.CronExpression(\"\(text)\"), "
                + "timeZone: Foundation.TimeZone(identifier: \(timeZone)) ?? .gmt)"
        case .interval(let every, let initialDelay):
            let delay = initialDelay ?? ".seconds(0)"
            trigger =
                "FlightScheduler.JobTrigger.interval(\(every), initialDelay: \(delay))"
        }

        var lines: [String] = []
        lines.append(
            "container.register(FlightScheduler.ScheduledJobRegistration.self, "
                + "qualifier: String(reflecting: Self.self) + \".\(job.methodName)\", "
                + "scope: .singleton) { c in")
        lines.append("    let component = try c.resolve(Self.self)")
        lines.append("    return FlightScheduler.ScheduledJobRegistration(")
        lines.append(
            "        name: String(reflecting: Self.self) + \".\(job.methodName)\",")
        lines.append("        trigger: \(trigger),")
        lines.append("        scope: \(job.scopeText),")
        lines.append("        overlap: \(job.overlapText)")
        lines.append("    ) {")
        lines.append("        \(call)")
        lines.append("    }")
        lines.append("}")
        return lines
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard !protocols.isEmpty else { return [] }
        let ext: DeclSyntax = """
            extension \(type.trimmed): FlightCore._FlightRegistrable {}
            """
        return ext.as(ExtensionDeclSyntax.self).map { [$0] } ?? []
    }
}
