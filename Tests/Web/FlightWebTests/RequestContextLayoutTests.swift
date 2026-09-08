import FlightCore
import Testing

@testable import FlightWeb

/// `RequestContext` is copied on every `next(context)`, so its size is a
/// per-layer, per-request cost rather than a detail.
///
/// A middleware chain folds N layers around a terminal, and each one hands a
/// value copy downstream — that is what makes the layered shape work, and
/// what makes the struct's width worth watching. These are not micro-
/// optimisation for its own sake: they are the two properties that were
/// silently lost once, and a bound is the only way to notice.
@Suite("RequestContext layout")
struct RequestContextLayoutTests {

    @Test("the context fits in two cache lines")
    func fitsTwoCacheLines() {
        // It was 184 bytes — three lines — because it carried a `response`
        // field that nothing read. The field was vestigial from the flat
        // pre-handler chain, where middleware mutated the response in place
        // and the chain returned it; under the onion shape the response *is*
        // the return value. Removing it paid for the 40-byte identity field
        // and 64 bytes besides.
        //
        // 128 is not a magic number to optimise toward. It is the boundary
        // this type currently sits under, and crossing it should be a
        // decision someone makes rather than one that happens.
        #expect(
            MemoryLayout<RequestContext>.stride <= 128,
            "RequestContext grew past two cache lines; it is copied per middleware layer")
    }

    @Test("an anonymous request carries no identity payload")
    func anonymousCarriesNothing() {
        // `.anonymous` has no associated value, so an unauthenticated
        // request pays the enum's bytes and no retain/release traffic when
        // the context is copied. Worth pinning: adding a payload to this
        // case would make every anonymous request pay for authentication it
        // never used.
        let identity = RequestIdentity.anonymous
        #expect(identity.principal == nil)
        #expect(!identity.isAuthenticated)
    }
}
