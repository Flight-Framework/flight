import FlightChannelsProtocol

/// The topic pattern a `Channel` registration serves: an exact topic
/// (`"lobby"`), a prefix wildcard (`"room:*"`), or the catch-all (`"*"`).
///
/// Channels applies the `"kind:id"` convention but, like PubSub,
/// treats the string as opaque beyond its own join-routing step — so the
/// pattern language is deliberately this small. `*` is legal only as the
/// final character; anything richer is an application concern.
public struct TopicPattern: Sendable, Equatable, CustomStringConvertible {
    internal enum Kind: Sendable, Equatable {
        case exact(String)
        case prefix(String)
    }

    internal let kind: Kind
    public let description: String

    /// Parses a pattern, throwing `ChannelsError.invalidTopicPattern` for
    /// an empty pattern or a `*` anywhere but the end — surfaced at
    /// bootstrap (`freeze()`), never at join time.
    public init(parsing pattern: String) throws {
        guard !pattern.isEmpty else {
            throw ChannelsError.invalidTopicPattern(pattern, "pattern must not be empty")
        }
        if let starIndex = pattern.firstIndex(of: "*") {
            guard starIndex == pattern.index(before: pattern.endIndex) else {
                throw ChannelsError.invalidTopicPattern(pattern, "'*' is only legal as the final character")
            }
            self.kind = .prefix(String(pattern[..<starIndex]))
        } else {
            self.kind = .exact(pattern)
        }
        self.description = pattern
    }

    public func matches(_ topic: String) -> Bool {
        switch kind {
        case .exact(let exact):
            return topic == exact
        case .prefix(let prefix):
            return topic.hasPrefix(prefix)
        }
    }

    /// Match precedence: exact beats wildcard; longer wildcard prefix beats
    /// shorter ("room:admin:*" over "room:*" over "*"). Deterministic and
    /// independent of registration order.
    internal var specificity: (Int, Int) {
        switch kind {
        case .exact(let exact): return (1, exact.count)
        case .prefix(let prefix): return (0, prefix.count)
        }
    }
}

/// Configuration and wiring failures. All of these surface at bootstrap
/// (module `configure` / container `freeze()`), failing the app before it
/// serves — never mid-connection.
public enum ChannelsError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidTopicPattern(String, String)
    case duplicateTopicPattern(String)

    public var description: String {
        switch self {
        case .invalidTopicPattern(let pattern, let detail):
            return "Invalid channel topic pattern '\(pattern)': \(detail)."
        case .duplicateTopicPattern(let pattern):
            return "Channel topic pattern '\(pattern)' is registered more than once — each pattern must have exactly one Channel."
        }
    }
}
