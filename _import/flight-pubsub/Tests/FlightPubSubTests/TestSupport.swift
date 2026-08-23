import Foundation
import FlightPubSub

func msg(_ topic: String, _ text: String, metadata: [String: String] = [:]) -> Message {
    Message(topic: topic, payload: Data(text.utf8), metadata: metadata)
}

func text(_ message: Message) -> String {
    String(decoding: message.payload, as: UTF8.self)
}

/// Poll until `condition` holds or `timeout` elapses. Only for assertions
/// that depend on ARC releasing a dropped stream (deinit-triggered
/// termination), which is prompt but not specified to complete before the
/// caller resumes. Everything else in these suites is deterministic awaits.
func eventually(
    timeout: Duration = .seconds(5),
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
