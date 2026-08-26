/// A parsed media type — `type/subtype` plus parameters — per RFC 9110 §8.3.
///
/// Small on purpose: this exists so that the places that must ask "what is
/// this body?" (request-body negotiation, multipart part headers) share one
/// parser instead of each doing `contains("json")` string poking. It parses
/// what clients actually send; it does not model `Accept` ranges or
/// wildcards, which are a different problem for a different day.
///
/// `type`, `subtype`, and parameter names are lowercased at parse time —
/// they are case-insensitive on the wire — while parameter *values* keep
/// their case (compare case-insensitively where the parameter calls for it,
/// as `charset` does).
public struct MediaType: Sendable, Equatable, CustomStringConvertible {
    public struct Parameter: Sendable, Equatable {
        public let name: String
        public let value: String
    }

    public let type: String
    public let subtype: String
    /// In wire order. Duplicate names are kept as sent; `parameter(_:)`
    /// answers with the first.
    public let parameters: [Parameter]

    /// Parses a `Content-Type`-shaped value. `nil` means the header is not
    /// a media type — and the caller should treat that as "unsupported",
    /// never as a lenient match.
    public init?(parsing headerValue: String) {
        var rest = Substring(headerValue).trimmed()

        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let type = rest[..<slash]
        rest = rest[rest.index(after: slash)...]
        let subtypeEnd = rest.firstIndex(of: ";") ?? rest.endIndex
        let subtype = rest[..<subtypeEnd].trimmed()
        guard Self.isToken(type), Self.isToken(subtype) else { return nil }

        var parameters: [Parameter] = []
        rest = rest[subtypeEnd...]
        while let semicolon = rest.firstIndex(of: ";") {
            rest = rest[rest.index(after: semicolon)...]
            // Find this parameter's extent: up to the next `;` that is not
            // inside a quoted string.
            var inQuotes = false
            var escaped = false
            var end = rest.endIndex
            var index = rest.startIndex
            while index < rest.endIndex {
                let character = rest[index]
                if escaped {
                    escaped = false
                } else if character == "\\", inQuotes {
                    escaped = true
                } else if character == "\"" {
                    inQuotes.toggle()
                } else if character == ";", !inQuotes {
                    end = index
                    break
                }
                index = rest.index(after: index)
            }
            let segment = rest[..<end].trimmed()
            rest = rest[end...]

            if segment.isEmpty { continue }  // tolerate `;;` and a trailing `;`
            guard let equals = segment.firstIndex(of: "=") else { return nil }
            let name = segment[..<equals].trimmed()
            guard Self.isToken(name) else { return nil }
            guard let value = Self.parameterValue(segment[segment.index(after: equals)...].trimmed())
            else { return nil }
            parameters.append(Parameter(name: name.lowercased(), value: value))
        }

        self.type = type.trimmed().lowercased()
        self.subtype = subtype.lowercased()
        self.parameters = parameters
    }

    /// `type/subtype`, parameters dropped — what negotiation compares.
    public var essence: String { "\(type)/\(subtype)" }

    /// First parameter with this name (case-insensitive).
    public func parameter(_ name: String) -> String? {
        let lowered = name.lowercased()
        return parameters.first { $0.name == lowered }?.value
    }

    /// `application/json` and any `+json` structured-syntax suffix
    /// (`application/problem+json`, `application/vnd.api+json`, …).
    public var isJSON: Bool {
        essence == "application/json" || subtype.hasSuffix("+json")
    }

    public var isText: Bool { type == "text" }

    public var description: String {
        parameters.reduce(essence) { "\($0); \($1.name)=\($1.value)" }
    }

    // MARK: - Grammar

    private static func isToken(_ text: Substring) -> Bool {
        !text.isEmpty
            && text.allSatisfy { character in
                character.isASCII
                    && (character.isLetter || character.isNumber
                        || "!#$%&'*+-.^_`|~".contains(character))
            }
    }

    /// A parameter value: a bare token, or a quoted-string with `\`-escapes
    /// unescaped.
    private static func parameterValue(_ text: Substring) -> String? {
        guard text.first == "\"" else {
            return isToken(text) ? String(text) : nil
        }
        guard text.count >= 2, text.last == "\"" else { return nil }
        var value = ""
        var escaped = false
        for character in text.dropFirst().dropLast() {
            if escaped {
                value.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return nil  // an unescaped quote can only end the string
            } else {
                value.append(character)
            }
        }
        return escaped ? nil : value
    }
}

extension Substring {
    fileprivate func trimmed() -> Substring {
        var trimmed = self
        while let first = trimmed.first, first == " " || first == "\t" {
            trimmed = trimmed.dropFirst()
        }
        while let last = trimmed.last, last == " " || last == "\t" {
            trimmed = trimmed.dropLast()
        }
        return trimmed
    }
}
