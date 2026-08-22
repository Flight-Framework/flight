// The token the probe scans for across target boundaries. This file being
// readable from App's plugin invocation is spike question (a) in miniature:
// if a probe launched by App's build command can read this text, source
// scanning works cross-target and Flight's revised registration mechanism
// is validated.

// @Component  ← scan marker (comment on purpose; this spike has no FlightCore dependency)
public struct AlphaService {
    public init() {}
    public var name: String { "alpha" }
}
