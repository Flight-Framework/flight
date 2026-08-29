import FlightWeb

extension Request {
    /// The bearer token from the `Authorization` header, per RFC 6750,
    /// or `nil` when the header is absent, uses another scheme, or is
    /// malformed.
    ///
    /// The scheme comparison is case-insensitive (`Bearer`, `bearer`, …);
    /// the credential itself is returned verbatim. A malformed value (empty
    /// token, embedded whitespace) yields `nil` — i.e. the request is
    /// treated as unauthenticated rather than rejected here; enforcement is
    /// a separate concern.
    public var bearerToken: String? {
        guard let header = headers[.authorization] else { return nil }
        return Self.parseBearer(header)
    }

    /// RFC 7235 credentials syntax: `Bearer 1*SP token68`.
    static func parseBearer(_ headerValue: String) -> String? {
        // `trimmingCharacters(in: .whitespaces)` is the only thing this file
        // wanted Foundation for, on the path every authenticated request
        // takes. Two `drop`s off the stdlib do the same job.
        var trimmed = Substring(headerValue)
        while let first = trimmed.first, first.isWhitespace { trimmed.removeFirst() }
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        guard trimmed.count > 7 else { return nil }
        let schemeEnd = trimmed.index(trimmed.startIndex, offsetBy: 6)
        guard trimmed[..<schemeEnd].lowercased() == "bearer" else { return nil }
        let afterScheme = trimmed[schemeEnd...]
        // At least one space must separate scheme and credentials.
        guard afterScheme.first == " " else { return nil }
        let token = afterScheme.drop(while: { $0 == " " })
        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else { return nil }
        return String(token)
    }
}
