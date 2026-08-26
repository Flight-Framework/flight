import Foundation
import Testing
@testable import FlightConfig

@Suite("ConfigDecodable — standard conformances")
struct ConfigDecodableTests {

    @Test("String passes through verbatim, including empty and whitespace")
    func string() {
        #expect(String(configValue: "hello") == "hello")
        #expect(String(configValue: "") == "")
        #expect(String(configValue: "  padded  ") == "  padded  ")
    }

    @Test("Int decodes base-10, tolerating surrounding whitespace")
    func int() {
        #expect(Int(configValue: "8080") == 8080)
        #expect(Int(configValue: "-42") == -42)
        #expect(Int(configValue: " 7 ") == 7)
        #expect(Int(configValue: "0") == 0)
        #expect(Int(configValue: "") == nil)
        #expect(Int(configValue: "1.5") == nil)
        #expect(Int(configValue: "0x1F") == nil)
        #expect(Int(configValue: "1_000") == nil)
        #expect(Int(configValue: "eight") == nil)
    }

    @Test("Double decodes decimals and scientific notation")
    func double() {
        #expect(Double(configValue: "1.5") == 1.5)
        #expect(Double(configValue: "1e3") == 1000.0)
        #expect(Double(configValue: "-0.25") == -0.25)
        #expect(Double(configValue: " 2 ") == 2.0)
        #expect(Double(configValue: "abc") == nil)
        #expect(Double(configValue: "") == nil)
    }

    @Test("Bool accepts the documented spellings, case-insensitively")
    func bool() {
        for truthy in ["true", "True", "TRUE", "yes", "YES", "on", "On", "1", " true "] {
            #expect(Bool(configValue: truthy) == true, "\(truthy)")
        }
        for falsy in ["false", "False", "FALSE", "no", "No", "off", "OFF", "0"] {
            #expect(Bool(configValue: falsy) == false, "\(falsy)")
        }
        for invalid in ["", "enabled", "2", "t", "y", "maybe"] {
            #expect(Bool(configValue: invalid) == nil, "\(invalid)")
        }
    }

    @Test("URL decodes anything URL(string:) accepts, rejecting empty")
    func url() {
        #expect(URL(configValue: "postgres://localhost:5432/flight_dev")?.scheme == "postgres")
        #expect(URL(configValue: "https://example.com/a?b=c")?.host == "example.com")
        #expect(URL(configValue: "/var/lib/flight")?.path == "/var/lib/flight")
        #expect(URL(configValue: " https://example.com ") != nil)
        #expect(URL(configValue: "") == nil)
        #expect(URL(configValue: "   ") == nil)
        // Deliberately no "garbage string" nil-assertion: URL validity
        // semantics belong to URL(string:), and modern swift-foundation is
        // RFC 3986-lenient (it percent-encodes rather than rejecting).
        // Stricter validity requirements belong to the consumer of the value.
    }

    @Test("Duration requires a unit and rejects bare numbers")
    func durationRequiresUnit() {
        // A bare "30" reads as thirty of *something*; every framework that
        // guesses (usually seconds) has produced the incident where a
        // timeout meant to be 30s was configured as 30 and silently applied
        // as thirty milliseconds. One keystroke removes the ambiguity.
        #expect(Duration(configValue: "30") == nil)
        #expect(Duration(configValue: "") == nil)
        #expect(Duration(configValue: "abc") == nil)
    }

    @Test("Duration parses every supported unit")
    func durationUnits() {
        #expect(Duration(configValue: "500ns") == .nanoseconds(500))
        #expect(Duration(configValue: "500us") == .microseconds(500))
        #expect(Duration(configValue: "500ms") == .milliseconds(500))
        #expect(Duration(configValue: "30s") == .seconds(30))
        #expect(Duration(configValue: "5m") == .seconds(300))
        #expect(Duration(configValue: "12h") == .seconds(12 * 3_600))
        #expect(Duration(configValue: "2d") == .seconds(2 * 86_400))
    }

    @Test("Duration accepts fractional magnitudes")
    func durationFractional() {
        #expect(Duration(configValue: "1.5s") == .seconds(1.5))
        #expect(Duration(configValue: "0.5d") == .seconds(43_200))
    }

    @Test("Duration is case-insensitive on the unit and tolerates whitespace")
    func durationCaseAndWhitespace() {
        #expect(Duration(configValue: "5S") == .seconds(5))
        #expect(Duration(configValue: "5MS") == .milliseconds(5))
        #expect(Duration(configValue: " 5s ") == .seconds(5))
        #expect(Duration(configValue: "5 s") == .seconds(5))
    }

    @Test("Duration rejects negative magnitudes and unknown units")
    func durationRejectsNonsense() {
        #expect(Duration(configValue: "-5s") == nil)
        #expect(Duration(configValue: "5x") == nil)
        #expect(Duration(configValue: "5") == nil)
        #expect(Duration(configValue: "s5") == nil)
        #expect(Duration(configValue: "5.5.5s") == nil)
    }

    @Test("Duration plugs into Configuration.get like any other ConfigDecodable")
    func durationThroughConfiguration() throws {
        let config = Configuration(values: ["job.timeout": "30s", "job.bad": "thirty seconds"])
        #expect(try config.get("job.timeout", as: Duration.self) == .seconds(30))
        #expect(throws: ConfigError.self) {
            try config.get("job.bad", as: Duration.self)
        }
    }

    @Test("custom conformances plug into Configuration.get")
    func customConformance() throws {
        enum LogLevel: String, ConfigDecodable {
            case debug, info, warn, error
            init?(configValue: String) { self.init(rawValue: configValue) }
        }
        let config = Configuration(values: ["log.level": "warn", "log.bad": "loud"])
        #expect(try config.get("log.level", as: LogLevel.self) == .warn)
        #expect(throws: ConfigError.self) {
            try config.get("log.bad", as: LogLevel.self)
        }
    }
}
