/// The presence data model. One subtlety, load-bearing: **one
/// identity can have many simultaneous connections.** A user with three
/// browser tabs open is one person, present three times — one key, three
/// metas. Closing one tab removes one meta; only when the *last* meta goes
/// is the key genuinely gone, and only then do clients see a leave.
public struct PresenceEntry: Sendable, Equatable {
    /// The identity. Typically `Principal.subject` (Security Core), but
    /// the application chooses — it could be a device id, a session id,
    /// anything.
    public let key: String

    /// One meta per live connection for this key. Three tabs ⇒ three metas.
    public let metas: [PresenceMeta]

    public init(key: String, metas: [PresenceMeta]) {
        self.key = key
        self.metas = metas
    }
}

public struct PresenceMeta: Sendable, Equatable, Hashable {
    /// Unique per connection. Assigned when tracked; the unit of add/remove.
    /// Stable across `update` — a meta-only change keeps its ref.
    public let ref: String

    /// Application-supplied, connection-specific: `{"status": "typing"}`,
    /// device info, joined-at timestamp, etc. Opaque to Presence.
    public let payload: [String: String]

    public init(ref: String, payload: [String: String]) {
        self.ref = ref
        self.payload = payload
    }
}
