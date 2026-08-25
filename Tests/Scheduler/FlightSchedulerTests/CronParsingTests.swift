import Foundation
import Testing

@testable import FlightScheduler

@Suite("Cron — parsing")
struct CronParsingTests {

    @Test("six fields, seconds first")
    func sixFields() throws {
        let cron = try CronExpression("0 0 3 * * *")
        #expect(cron.description == "0 0 3 * * *")
    }

    @Test("five fields mean the same schedule at second zero")
    func fiveFieldsEqualSixWithZeroSeconds() throws {
        let five = try CronExpression("0 3 * * *")
        let six = try CronExpression("0 0 3 * * *")
        let zone = TimeZone(identifier: "UTC")!
        let from = Date(timeIntervalSince1970: 0)
        #expect(five.nextFireDate(after: from, in: zone) == six.nextFireDate(after: from, in: zone))
    }

    @Test("wrong field count names the count it found")
    func wrongFieldCount() {
        #expect(throws: CronParseError.self) { try CronExpression("0 0") }
        do {
            _ = try CronExpression("0 0")
        } catch let error as CronParseError {
            #expect(error.description.contains("found 2"))
        } catch { Issue.record("wrong error type") }
    }

    @Test("an out-of-range value names the field and the range")
    func outOfRange() {
        do {
            _ = try CronExpression("0 0 25 * * *")
            Issue.record("expected a parse error")
        } catch let error as CronParseError {
            #expect(error.description.contains("hour"))
            #expect(error.description.contains("0–23"))
        } catch { Issue.record("wrong error type") }
    }

    @Test("month and day names parse case-insensitively")
    func names() throws {
        let byName = try CronExpression("0 0 0 1 JAN MON")
        let byNumber = try CronExpression("0 0 0 1 1 1")
        let zone = TimeZone(identifier: "UTC")!
        let from = Date(timeIntervalSince1970: 0)
        #expect(byName.nextFireDate(after: from, in: zone)
                == byNumber.nextFireDate(after: from, in: zone))
        #expect(throws: Never.self) { try CronExpression("0 0 0 * jan-mar *") }
    }

    @Test("both 0 and 7 mean Sunday")
    func sundayIsZeroOrSeven() throws {
        let zone = TimeZone(identifier: "UTC")!
        let from = Date(timeIntervalSince1970: 0)
        let zero = try CronExpression("0 0 0 * * 0")
        let seven = try CronExpression("0 0 0 * * 7")
        #expect(zero.nextFireDate(after: from, in: zone)
                == seven.nextFireDate(after: from, in: zone))
    }

    @Test("a backwards range is refused rather than silently wrapping")
    func backwardsRange() {
        do {
            _ = try CronExpression("0 0 22-3 * * *")
            Issue.record("expected a parse error")
        } catch let error as CronParseError {
            #expect(error.description.contains("backwards"))
        } catch { Issue.record("wrong error type") }
    }

    @Test("the syntaxes cron implementations disagree about are refused")
    func unsupportedSyntaxRefused() {
        // Refusing beats guessing: `L`, `W`, `#` and `?` mean different things
        // in different implementations, and a schedule that quietly means
        // something other than the reader intends is the worst outcome.
        for expression in ["0 0 0 L * *", "0 0 0 15W * *", "0 0 0 * * 6#3", "0 0 0 ? * *", "@daily"] {
            #expect(throws: CronParseError.self, "\(expression) should not parse") {
                try CronExpression(expression)
            }
        }
    }

    @Test("a step with no matching values is refused")
    func emptyField() {
        #expect(throws: CronParseError.self) { try CronExpression("0 0 0 * * ,") }
        #expect(throws: CronParseError.self) { try CronExpression("0 0 0 * * */0") }
    }
}
