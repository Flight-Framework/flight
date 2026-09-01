// The compile-time half of the scheduler's pitch: a bad schedule is a build
// error naming the problem, not a job that silently never fires.
//
// These pin the *diagnostics* rather than the expansion. A diagnostic that
// gets reworded or silently vanishes is exactly the kind of regression that
// nothing else catches — the code still compiles, it just stops helping.

import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

@testable import FlightSchedulerMacrosImpl

private let testMacros: [String: MacroSpec] = [
    "Scheduler": MacroSpec(type: SchedulerMacro.self, conformances: ["FlightCore._FlightRegistrable"]),
    "Scheduled": MacroSpec(type: ScheduledMacro.self),
]

@Suite("scheduler macro diagnostics")
struct ScheduledDiagnosticTests {

    private func expectDiagnostic(
        _ source: String,
        _ expectedMessageFragment: String,
        sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) {
        var messages: [String] = []
        assertMacroExpansion(
            source, expandedSource: "", macroSpecs: testMacros,
            failureHandler: { failure in messages.append(failure.message) },
            fileID: #fileID, filePath: #filePath, line: UInt(sourceLocation.line), column: 1)
        #expect(
            messages.contains { $0.contains(expectedMessageFragment) },
            "no diagnostic mentioning \"\(expectedMessageFragment)\"; got: \(messages)",
            sourceLocation: sourceLocation)
    }

    @Test("a malformed cron expression fails the build, naming the field")
    func malformedCron() {
        // The whole reason the expression must be a literal.
        expectDiagnostic(
            """
            @Scheduler
            struct Jobs {
                @Scheduled("0 0 25 * * *")
                func run() {}
            }
            """,
            "hour")
    }

    @Test("the wrong number of fields says how many it found")
    func wrongFieldCount() {
        expectDiagnostic(
            """
            @Scheduler
            struct Jobs {
                @Scheduled("0 0")
                func run() {}
            }
            """,
            "found 2")
    }

    @Test("a non-literal expression explains the runtime alternative")
    func nonLiteral() {
        expectDiagnostic(
            """
            @Scheduler
            struct Jobs {
                @Scheduled(schedule)
                func run() {}
            }
            """,
            "registerScheduledJob")
    }

    @Test("a job taking parameters is refused, naming the alternative")
    func parametersRefused() {
        expectDiagnostic(
            """
            @Scheduler
            struct Jobs {
                @Scheduled("0 0 3 * * *")
                func run(now: Date) {}
            }
            """,
            "@Inject")
    }

    @Test("a job returning a value is refused, because nothing reads it")
    func returnValueRefused() {
        expectDiagnostic(
            """
            @Scheduler
            struct Jobs {
                @Scheduled("0 0 3 * * *")
                func run() -> Int { 0 }
            }
            """,
            "nothing reads")
    }

    @Test("both a cron expression and an interval is refused")
    func twoSchedules() {
        expectDiagnostic(
            """
            @Scheduler
            struct Jobs {
                @Scheduled("0 0 3 * * *", every: .minutes(5))
                func run() {}
            }
            """,
            "Pick one")
    }

    @Test("@Scheduler with no jobs says so rather than silently doing nothing")
    func noJobs() {
        expectDiagnostic(
            """
            @Scheduler
            struct Jobs {
                func run() {}
            }
            """,
            "schedules nothing")
    }

    @Test("@Scheduled on something that is not a method is refused")
    func notAMethod() {
        expectDiagnostic(
            """
            @Scheduler
            struct Jobs {
                @Scheduled("0 0 3 * * *")
                var value: Int = 0
            }
            """,
            "can only be attached to a method")
    }
}
