import FlightChannelsProtocol

/// The two reserved events Presence puts on a channel topic (design §6).
/// `flight:`-namespaced like the Channels lifecycle events (Channels §4.2),
/// so they can never collide with application events.
public enum PresenceEvent {
    /// The full current presence list, sent once to a socket when its
    /// membership of the topic is established. Payload: `entries` shape.
    public static let state = "flight:presence_state"
    /// A change: `{"joins": <entries>, "leaves": <entries>}`. Everything
    /// after the initial state is diffs — re-sending the whole list on
    /// every change is the obvious scaling failure (§6).
    public static let diff = "flight:presence_diff"
}

/// The wire shape of presence payloads (§6):
///
///     entries := { "<key>": { "metas": [ { "ref": "a1", ...payload } ] } }
///     diff    := { "joins": entries, "leaves": entries }
///
/// A meta object is the application payload flattened alongside `ref` —
/// which is why `"ref"` is a reserved payload key (the server refuses it).
public enum PresenceWire {
    public static let metasKey = "metas"
    public static let refKey = "ref"
    public static let joinsKey = "joins"
    public static let leavesKey = "leaves"

    // MARK: - Encoding

    public static func json(meta: PresenceMeta) -> JSONValue {
        var object: [String: JSONValue] = [refKey: .string(meta.ref)]
        for (key, value) in meta.payload where key != refKey {
            object[key] = .string(value)
        }
        return .object(object)
    }

    public static func json(metas: [PresenceMeta]) -> JSONValue {
        .object([metasKey: .array(metas.map { json(meta: $0) })])
    }

    /// The `entries` shape, from any (key → metas) map. Empty maps encode
    /// as `{}`, deliberately — an empty topic's state is a real message.
    public static func json(entries: [String: [PresenceMeta]]) -> JSONValue {
        .object(entries.mapValues { json(metas: $0) })
    }

    public static func json(entries: [PresenceEntry]) -> JSONValue {
        json(entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.metas) }))
    }

    public static func diffJSON(joins: [String: [PresenceMeta]], leaves: [String: [PresenceMeta]]) -> JSONValue {
        .object([joinsKey: json(entries: joins), leavesKey: json(entries: leaves)])
    }

    // MARK: - Decoding

    /// A meta from its wire object; nil when `ref` is missing — a meta
    /// without its identity is not applicable. Non-string payload values
    /// are dropped (the server only ever emits strings, §2).
    public static func meta(from value: JSONValue) -> PresenceMeta? {
        guard let object = value.objectValue, let ref = object[refKey]?.stringValue else { return nil }
        var payload: [String: String] = [:]
        for (key, member) in object where key != refKey {
            if let string = member.stringValue { payload[key] = string }
        }
        return PresenceMeta(ref: ref, payload: payload)
    }

    /// The `entries` shape back into a (key → metas) map. Malformed
    /// members are dropped rather than failing the whole payload — the
    /// client keeps the best consistent view it can.
    public static func entries(from value: JSONValue) -> [String: [PresenceMeta]] {
        guard let object = value.objectValue else { return [:] }
        var result: [String: [PresenceMeta]] = [:]
        for (key, member) in object {
            guard let metaValues = member[metasKey]?.arrayValue else { continue }
            let metas = metaValues.compactMap { meta(from: $0) }
            if !metas.isEmpty { result[key] = metas }
        }
        return result
    }
}
