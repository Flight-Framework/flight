import Testing

@testable import FlightConfigCore

@Suite("ConfigKeyNaming.kebabCase")
struct ConfigKeyNamingTests {

    @Test("simple camelCase words get one hyphen each")
    func simpleCases() {
        #expect(ConfigKeyNaming.kebabCase("signingKey") == "signing-key")
        #expect(ConfigKeyNaming.kebabCase("tokenLifetimeHours") == "token-lifetime-hours")
        #expect(ConfigKeyNaming.kebabCase("maxRequestBodyBytes") == "max-request-body-bytes")
    }

    @Test("a single lowercase word is unchanged")
    func singleWord() {
        #expect(ConfigKeyNaming.kebabCase("issuer") == "issuer")
        #expect(ConfigKeyNaming.kebabCase("port") == "port")
    }

    @Test("a digit does not force a hyphen before the next letter")
    func digitsDoNotSplit() {
        #expect(ConfigKeyNaming.kebabCase("ipv4Address") == "ipv4-address")
    }

    @Test("consecutive uppercase letters (an acronym) do not each get their own hyphen")
    func acronymRun() {
        // A run of uppercase letters is one word, not one hyphen per letter —
        // "urlPath" and the (admittedly rarer, since properties start
        // lowercase) "aURLPath" shape should both read naturally.
        #expect(ConfigKeyNaming.kebabCase("urlPath") == "url-path")
    }
}
