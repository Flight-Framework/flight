/// The `camelCase` → `kebab-case` transform `@Settings` uses to derive a
/// configuration key from a property name.
///
/// Lives here — a plain, dependency-free library both a macro-implementation
/// target and a build-time source scanner can import — rather than as two
/// hand-copied functions kept in sync by a cross-check test. One
/// implementation cannot drift from itself; that is a stronger guarantee
/// than a test verifying two copies still agree, for the same cost.
public enum ConfigKeyNaming {
    /// `signingKey` -> `signing-key`. A pure function of the property name:
    /// callers use it both to embed a literal key in macro-generated source
    /// (at macro-expansion time) and to independently re-derive the same key
    /// for a build-time existence check against `flight.yaml` — neither call
    /// site runs this at request time.
    public static func kebabCase(_ camel: String) -> String {
        var result = ""
        var previousWasLowerOrDigit = false
        for character in camel {
            if character.isUppercase {
                if previousWasLowerOrDigit { result.append("-") }
                result.append(contentsOf: character.lowercased())
                previousWasLowerOrDigit = false
            } else {
                result.append(character)
                previousWasLowerOrDigit = character.isLowercase || character.isNumber
            }
        }
        return result
    }
}
