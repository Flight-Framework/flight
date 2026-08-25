import SwiftSyntax
import SwiftSyntaxMacros

/// One `@Scheduled` method, as scanned from the enclosing type's body.
struct ScannedJob {
    enum Schedule {
        /// A cron expression's literal text, already validated.
        case cron(String, timeZone: String)
        /// `every:` — the expression source, since a `Duration` is not a
        /// literal we can evaluate here.
        case interval(everyText: String, initialDelayText: String?)
    }

    let methodName: String
    let schedule: Schedule
    /// `.once` unless `onEveryNode: true`.
    let scopeText: String
    let overlapText: String
    let isAsync: Bool
    let isThrows: Bool
    let node: FunctionDeclSyntax
}

enum JobScanning {

    /// Reads every `@Scheduled` method out of a type body, validating each.
    static func scanJobs(
        of members: MemberBlockItemListSyntax,
        in context: some MacroExpansionContext
    ) -> [ScannedJob] {
        var jobs: [ScannedJob] = []
        for member in members {
            guard let function = member.decl.as(FunctionDeclSyntax.self) else { continue }
            for attribute in function.attributes {
                guard
                    let attr = attribute.as(AttributeSyntax.self),
                    attr.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "Scheduled"
                else { continue }
                if let job = scanJob(function: function, attribute: attr, in: context) {
                    jobs.append(job)
                }
            }
        }
        return jobs
    }

    static func scanJob(
        function: FunctionDeclSyntax,
        attribute: AttributeSyntax,
        in context: some MacroExpansionContext
    ) -> ScannedJob? {
        let name = function.name.text

        // A job takes no parameters. Anything a job needs comes from the
        // enclosing component's injected properties — there is no request,
        // no caller, and nothing to pass.
        guard function.signature.parameterClause.parameters.isEmpty else {
            context.diagnoseError(
                "scheduled.parameters",
                """
                @Scheduled method '\(name)' must take no parameters. A scheduled job has \
                no caller to supply them — inject what it needs into the enclosing type \
                with @Autowired instead.
                """,
                at: function.signature.parameterClause)
            return nil
        }

        // Returning a value is almost always a mistake: nothing reads it.
        if let returnClause = function.signature.returnClause,
            returnClause.type.trimmedDescription != "Void",
            returnClause.type.trimmedDescription != "()"
        {
            context.diagnoseError(
                "scheduled.returns",
                """
                @Scheduled method '\(name)' returns \
                '\(returnClause.type.trimmedDescription)', which nothing reads. Make it \
                return Void and record the result where it is needed.
                """,
                at: returnClause)
            return nil
        }

        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) else {
            context.diagnoseError(
                "scheduled.noschedule",
                """
                @Scheduled needs a schedule: a cron expression — @Scheduled("0 0 3 * * *") \
                — or an interval — @Scheduled(every: .minutes(5)).
                """,
                at: attribute)
            return nil
        }

        var cronText: String?
        var timeZoneText = "\"UTC\""
        var everyText: String?
        var initialDelayText: String?
        var onEveryNode = false
        var overlapText = ".skip"

        for argument in arguments {
            let label = argument.label?.text
            let value = argument.expression
            switch label {
            case nil:
                guard let literal = value.as(StringLiteralExprSyntax.self)?.representedLiteralValue
                else {
                    context.diagnoseError(
                        "scheduled.notliteral",
                        """
                        A cron expression must be a string literal so it can be checked at \
                        build time. For a schedule only known at runtime, register it with \
                        container.registerScheduledJob(_:cron:) instead.
                        """,
                        at: value)
                    return nil
                }
                cronText = literal
            case "timeZone":
                timeZoneText = value.trimmedDescription
            case "every":
                everyText = value.trimmedDescription
            case "initialDelay":
                initialDelayText = value.trimmedDescription
            case "onEveryNode":
                onEveryNode = value.trimmedDescription == "true"
            case "onOverlap":
                overlapText = value.trimmedDescription
            default:
                break
            }
        }

        // Exactly one schedule.
        switch (cronText, everyText) {
        case (nil, nil):
            context.diagnoseError(
                "scheduled.noschedule",
                """
                @Scheduled needs a schedule: a cron expression — @Scheduled("0 0 3 * * *") \
                — or an interval — @Scheduled(every: .minutes(5)).
                """,
                at: attribute)
            return nil
        case (.some, .some):
            context.diagnoseError(
                "scheduled.twoschedules",
                """
                @Scheduled has both a cron expression and an 'every:' interval. Pick one — \
                they describe the same thing two different ways.
                """,
                at: attribute)
            return nil
        default:
            break
        }

        let schedule: ScannedJob.Schedule
        if let cronText {
            // The point of the whole macro: a malformed schedule is a build
            // error naming the field, not a surprise at three in the morning.
            do {
                _ = try CronValidation.validate(cronText)
            } catch let error as CronValidationError {
                context.diagnoseError("scheduled.cron", error.message, at: attribute)
                return nil
            } catch {
                context.diagnoseError("scheduled.cron", "\(error)", at: attribute)
                return nil
            }
            schedule = .cron(cronText, timeZone: timeZoneText)
        } else {
            schedule = .interval(everyText: everyText!, initialDelayText: initialDelayText)
        }

        return ScannedJob(
            methodName: name,
            schedule: schedule,
            scopeText: onEveryNode ? ".onEveryNode" : ".once",
            overlapText: overlapText,
            isAsync: function.signature.effectSpecifiers?.asyncSpecifier != nil,
            isThrows: function.signature.effectSpecifiers?.throwsClause != nil,
            node: function)
    }
}
