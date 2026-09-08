import FlightMacroSupport
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Scheduler` — the type-level half, mirroring `@Controller`.
///
/// A `@Scheduler` type is an ordinary singleton component: it may inject
/// dependencies with `@Inject` exactly as any other component does. What
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
        var jobValueLines: [String] = []
        for job in jobs {
            jobValueLines.append(contentsOf: valueLines(for: job))
        }

        let access = declaration.modifiers.contains {
            $0.name.tokenKind == .keyword(.public) || $0.name.tokenKind == .keyword(.open)
        } ? "public " : ""

        // A @Scheduler type is an ordinary component: it injects what its
        // jobs need, exactly as @Controller and @Component do. Without the
        // resolving initializer, @Inject in a scheduler would not compile
        // — which the compiled doc snippet caught.
        let properties = Injection.scan(declaration.memberBlock.members)
        let initLines = Injection.initializerLines(for: properties)
        let initBody =
            initLines.isEmpty ? "" : "\n    " + initLines.joined(separator: "\n    ") + "\n"
        let resolvingInit: DeclSyntax = """
            internal init(_flight container: FlightCore.Container) throws {\(raw: initBody)}
            """

        // The component first, then its jobs: a job's factory resolves the
        // component, so the registration order has to allow that mid-freeze.
        let thunkLines =
            [
                "container.register(Self.self, scope: .singleton) { c in",
                "    try Self(_flight: c)",
                "}",
            ] + lines
        let thunk: DeclSyntax = """
            \(raw: access)static func _flightRegister(_ container: FlightCore.Container) throws {
            \(raw: thunkLines.map { "    " + $0 }.joined(separator: "\n"))
            }
            """
        // The same jobs as values, built from a component the caller supplies.
        //
        // The registration form above resolves the component from a container
        // when the job fires; this one closes over whatever `make` returns —
        // which the generated composition root fills with the component the
        // graph already built. The two are the same shape the route factories
        // and `_flightRegister` are: one wiring mechanism each.
        let jobValues: DeclSyntax = """
            \(raw: access)static func _flightScheduledJobs(
                _ make: @escaping @Sendable () -> Self
            ) -> [FlightScheduler.ScheduledJobRegistration] {
                [
            \(raw: jobValueLines.map { "        " + $0 }.joined(separator: "\n"))
                ]
            }
            """
        // Constructor injection, through the same generator @Component,
        // @Controller and @Middleware use — the shared macro-support target
        // this file's Injection helper anticipated and declined to build.
        let parameterInit = parameterizedInitializer(
            properties: properties.map {
                InjectedProperty(
                    name: $0.name, typeText: $0.typeText,
                    kind: {
                        switch $0.kind {
                        case .inject(let qualifier): return .inject(qualifier: qualifier)
                        case .configValue(let key, let defaultValue):
                            return .configValue(key: key, defaultValue: defaultValue)
                        }
                    }($0),
                    node: $0.node)
            },
            access: access, declaration: declaration)
        return [resolvingInit, parameterInit, thunk, jobValues].compactMap { $0 }
    }

    /// One `ScheduledJobRegistration` literal, closing over `make()`.
    private static func valueLines(for job: ScannedJob) -> [String] {
        var call = "component.\(job.methodName)()"
        if job.isAsync { call = "await \(call)" }
        if job.isThrows { call = "try \(call)" }

        var lines: [String] = []
        lines.append("FlightScheduler.ScheduledJobRegistration(")
        lines.append("    name: String(reflecting: Self.self) + \".\(job.methodName)\",")
        lines.append("    trigger: \(trigger(for: job)),")
        lines.append("    scope: \(job.scopeText),")
        lines.append("    overlap: \(job.overlapText)")
        lines.append(") {")
        lines.append("    let component = make()")
        lines.append("    \(call)")
        lines.append("},")
        return lines
    }

    /// Shared by both forms, so the schedule cannot drift between them.
    private static func trigger(for job: ScannedJob) -> String {
        switch job.schedule {
        case .cron(let text, let timeZone):
            // Force-try is safe here and nowhere else: the expression was
            // parsed by this same parser at compile time, so a throw is
            // impossible unless the macro and the runtime disagree — which
            // sharing one parser rules out.
            return
                "FlightScheduler.JobTrigger.cron("
                + "try! FlightScheduler.CronExpression(\"\(text)\"), "
                + "timeZone: try! FlightScheduler._flightTimeZone("
                + "\(timeZone), job: String(reflecting: Self.self) + \".\(job.methodName)\"))"
        case .interval(let every, let initialDelay):
            let delay = initialDelay ?? ".seconds(0)"
            return "FlightScheduler.JobTrigger.interval(\(every), initialDelay: \(delay))"
        }
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
                + "timeZone: try FlightScheduler._flightTimeZone("
                + "\(timeZone), job: String(reflecting: Self.self) + \".\(job.methodName)\"))"
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
