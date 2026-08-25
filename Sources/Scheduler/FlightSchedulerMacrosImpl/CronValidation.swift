import FlightCronCore

/// Compile-time cron validation, performed by the *runtime parser itself*.
///
/// The macro plugin depends on `FlightCronCore` rather than reimplementing
/// the grammar, so "what the build accepts" and "what the scheduler runs"
/// cannot drift apart. Keeping two parsers in lockstep by discipline works
/// until the day it doesn't, and the failure mode — a schedule that compiles
/// and then means something else at runtime — is the worst one available.
enum CronValidation {
    static func validate(_ text: String) throws -> CronExpression {
        do {
            return try CronExpression(text)
        } catch let error as CronParseError {
            throw CronValidationError(
                message: """
                    \(error.reason). In "\(text)". \
                    Fields are: second minute hour day-of-month month day-of-week \
                    (a five-field expression is also accepted and means second zero).
                    """)
        }
    }
}

struct CronValidationError: Error {
    let message: String
}
