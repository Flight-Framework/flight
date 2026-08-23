import FlightChannelsProtocol
import struct Foundation.URL
import struct Foundation.UUID
import Logging

/// One message pushed to the client on a channel — the client-side view of
/// a broadcast or a direct socket push.
public struct ChannelMessage: Sendable, Equatable {
    public let event: String
    public let payload: JSONValue

    public init(event: String, payload: JSONValue) {
        self.event = event
        self.payload = payload
    }

    /// Synthesized by the client itself (never received on the wire) when a
    /// dropped connection's channel is re-established: `event` is
    /// `"flight:join"` and `payload` the rejoin's initial state. Application
    /// events can never collide with it — the server refuses `flight:`-
    /// namespaced application pushes.
    public var isRejoin: Bool { event == ReservedEvent.join.rawValue }
}

/// The Swift reference client: the envelope protocol, ref/reply
/// correlation as `async` calls, incoming pushes as `AsyncStream`s, the
/// heartbeat, and automatic reconnect-with-backoff-and-rejoin. Protocol
/// plumbing, not a framework — transport injected, no dependencies.
///
///     let client = ChannelClient(url: url, transport: transport)
///     try await client.connect()
///     let room = client.channel("room:42")
///     let state = try await room.join()
///     let reply = try await room.push("new_msg", payload: ["body": "hi"])
///     for await message in await room.messages() { … }
public actor ChannelClient {
    private let url: URL
    private let transport: any ChannelClientTransport
    private let configuration: ChannelClientConfiguration
    private let logger: Logger

    private var state: ConnectionState = .closed
    private var connection: ClientTransportConnection?
    private var readTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var refCounter: UInt64 = 0
    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var pendingDeadlines: [String: Task<Void, Never>] = [:]

    private struct ChannelRecord {
        /// The app wants membership (join called, leave not) — what rejoin
        /// re-establishes after a drop.
        var desired = false
        /// Membership currently live on the server.
        var joined = false
        var subscribers: [UUID: AsyncStream<ChannelMessage>.Continuation] = [:]
    }

    private var channels: [String: ChannelRecord] = [:]
    private var stateSubscribers: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

    public init(
        url: URL,
        transport: any ChannelClientTransport,
        configuration: ChannelClientConfiguration = ChannelClientConfiguration(),
        logger: Logger = Logger(label: "flight.channels.client")
    ) {
        self.url = url
        self.transport = transport
        self.configuration = configuration
        self.logger = logger
    }

    // MARK: - Connection lifecycle

    /// Dials the server. Throws if the first connection cannot be
    /// established — the caller decides what an unreachable server means at
    /// startup. Once connected, later drops are handled automatically per
    /// the reconnect policy. No-op when already connected or connecting.
    public func connect() async throws {
        guard state == .closed || state == .disconnected else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        setState(.connecting)
        do {
            let connection = try await transport.connect(to: url)
            beginSession(connection)
        } catch {
            setState(.closed)
            throw error
        }
    }

    /// Graceful teardown: best-effort `flight:close`, transport
    /// close, terminal `.closed` state. Channel membership intent survives
    /// — a later `connect()` rejoins everything that was joined.
    public func disconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        let connection = self.connection
        self.connection = nil
        setState(.closed)
        failAllPending(with: .disconnected)
        markAllUnjoined()
        if let connection {
            if let text = try? Envelope(
                ref: nil,
                topic: ChannelProtocol.controlTopic,
                event: ReservedEvent.close.rawValue
            ).encodedText() {
                try? await connection.send(text)
            }
            await connection.close()
        }
        readTask?.cancel()
        readTask = nil
    }

    /// Connection state, current and ongoing: the returned stream yields the
    /// state as of the call, then every transition.
    public func states() -> AsyncStream<ConnectionState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ConnectionState>.makeStream()
        continuation.yield(state)
        stateSubscribers[id] = continuation
        continuation.onTermination = { _ in
            Task { await self.removeStateSubscriber(id) }
        }
        return stream
    }

    public var connectionState: ConnectionState { state }

    // MARK: - Channels

    /// A handle for one topic. Cheap; does not join.
    public nonisolated func channel(_ topic: String) -> ChannelHandle {
        ChannelHandle(topic: topic, client: self)
    }

    internal func join(topic: String, timeout: Duration?) async throws -> JSONValue {
        channels[topic, default: ChannelRecord()].desired = true
        do {
            let reply = try await request(
                topic: topic,
                event: ReservedEvent.join.rawValue,
                payload: .object([:]),
                timeout: timeout ?? configuration.pushTimeout
            )
            channels[topic]?.joined = true
            return reply
        } catch let error as ChannelClientError {
            if case .channelError = error {
                // The server said no. Retrying on reconnect would spin
                // on a closed gate.
                channels[topic]?.desired = false
            }
            throw error
        }
    }

    internal func leave(topic: String, timeout: Duration?) async throws {
        channels[topic]?.desired = false
        channels[topic]?.joined = false
        _ = try await request(
            topic: topic,
            event: ReservedEvent.leave.rawValue,
            payload: .object([:]),
            timeout: timeout ?? configuration.pushTimeout
        )
    }

    internal func push(
        topic: String,
        event: String,
        payload: JSONValue,
        timeout: Duration?
    ) async throws -> JSONValue {
        try await request(
            topic: topic,
            event: event,
            payload: payload,
            timeout: timeout ?? configuration.pushTimeout
        )
    }

    /// Fire-and-forget: no ref, so no reply and no deadline.
    internal func send(topic: String, event: String, payload: JSONValue) async throws {
        guard state == .connected, let connection else {
            throw ChannelClientError.notConnected
        }
        let text = try Envelope(ref: nil, topic: topic, event: event, payload: payload).encodedText()
        try await connection.send(text)
    }

    internal func messages(topic: String) -> AsyncStream<ChannelMessage> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ChannelMessage>.makeStream()
        channels[topic, default: ChannelRecord()].subscribers[id] = continuation
        continuation.onTermination = { _ in
            Task { await self.removeSubscriber(id, topic: topic) }
        }
        return stream
    }

    // MARK: - Request/reply

    private func request(
        topic: String,
        event: String,
        payload: JSONValue,
        timeout: Duration
    ) async throws -> JSONValue {
        guard state == .connected, let connection else {
            throw ChannelClientError.notConnected
        }
        refCounter += 1
        let ref = String(refCounter)
        let text = try Envelope(ref: ref, topic: topic, event: event, payload: payload).encodedText()

        return try await withCheckedThrowingContinuation { continuation in
            pending[ref] = continuation
            // These Tasks inherit the actor's isolation: expire/fail run
            // serialized with every other mutation, no await needed.
            pendingDeadlines[ref] = Task {
                try? await Task.sleep(for: timeout)
                self.expire(ref: ref)
            }
            Task {
                do {
                    try await connection.send(text)
                } catch {
                    self.fail(ref: ref, with: .disconnected)
                }
            }
        }
    }

    private func expire(ref: String) {
        guard !Task.isCancelled else { return }
        fail(ref: ref, with: .timedOut)
    }

    private func fail(ref: String, with error: ChannelClientError) {
        guard let continuation = pending.removeValue(forKey: ref) else { return }
        pendingDeadlines.removeValue(forKey: ref)?.cancel()
        continuation.resume(throwing: error)
    }

    private func resolve(ref: String, payload: JSONValue) {
        guard let continuation = pending.removeValue(forKey: ref) else { return }
        pendingDeadlines.removeValue(forKey: ref)?.cancel()
        continuation.resume(returning: payload)
    }

    private func failAllPending(with error: ChannelClientError) {
        let waiting = pending
        pending = [:]
        for task in pendingDeadlines.values { task.cancel() }
        pendingDeadlines = [:]
        for continuation in waiting.values {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Session

    private func beginSession(_ connection: ClientTransportConnection) {
        self.connection = connection
        setState(.connected)

        readTask = Task {
            var failure: (any Error)?
            do {
                for try await text in connection.incoming {
                    self.receive(text)
                }
            } catch {
                failure = error
            }
            self.connectionEnded(error: failure)
        }

        heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: configuration.heartbeatInterval)
                if Task.isCancelled { return }
                let alive = await self.sendHeartbeat()
                if !alive {
                    await self.heartbeatFailed()
                    return
                }
            }
        }
    }

    private func sendHeartbeat() async -> Bool {
        guard state == .connected else { return false }
        do {
            // Deadline = interval: a heartbeat that hasn't answered by the
            // time the next would go out means the connection is dead in
            // the way heartbeats exist to detect.
            _ = try await request(
                topic: ChannelProtocol.controlTopic,
                event: ReservedEvent.heartbeat.rawValue,
                payload: .object([:]),
                timeout: configuration.heartbeatInterval
            )
            return true
        } catch {
            return state == .connected ? false : true // drop already handled elsewhere
        }
    }

    private func heartbeatFailed() async {
        guard state == .connected, let connection else { return }
        logger.debug("heartbeat unanswered; closing connection to re-dial")
        await connection.close()
        // The read loop observes the close and drives reconnection.
    }

    private func receive(_ text: String) {
        guard let envelope = try? Envelope(text: text) else {
            // Flight owns both ends: an undecodable server frame is a
            // version-skew bug. Log loudly, drop the frame.
            logger.error("undecodable frame from server", metadata: ["frame": "\(text)"])
            return
        }
        switch ReservedEvent(rawValue: envelope.event) {
        case .reply:
            if let ref = envelope.ref {
                resolve(ref: ref, payload: envelope.payload)
            }
        case .error:
            if let ref = envelope.ref, pending[ref] != nil {
                let reason = envelope.payload[ChannelProtocol.errorReasonKey]?.stringValue ?? "unknown"
                fail(ref: ref, with: .channelError(reason: reason))
            } else {
                // Uncorrelated channel error — surface it on the channel's
                // message stream so the application can react.
                deliver(envelope, topic: envelope.topic)
            }
        case .close:
            // Server-initiated graceful teardown: terminal, no
            // reconnect.
            Task { await self.disconnect() }
        case .join, .leave, .heartbeat:
            break // server never initiates these; tolerate and ignore
        case nil:
            deliver(envelope, topic: envelope.topic)
        }
    }

    private func deliver(_ envelope: Envelope, topic: String) {
        guard let record = channels[topic] else { return }
        let message = ChannelMessage(event: envelope.event, payload: envelope.payload)
        for continuation in record.subscribers.values {
            continuation.yield(message)
        }
    }

    // MARK: - Drop and reconnect (reconnect + rejoin, never resume)

    private func connectionEnded(error: (any Error)?) {
        guard state == .connected else { return } // intentional close already handled
        if let error {
            logger.debug("connection dropped", metadata: ["error": "\(error)"])
        }
        connection = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        failAllPending(with: .disconnected)
        markAllUnjoined()
        setState(.disconnected)
        reconnectTask = Task { await self.reconnectLoop() }
    }

    private func reconnectLoop() async {
        var attempt = 1
        while state == .disconnected, !Task.isCancelled {
            guard let delay = configuration.reconnect.delay(attempt) else {
                logger.info("reconnect policy exhausted; closing")
                setState(.closed)
                return
            }
            try? await Task.sleep(for: delay)
            guard state == .disconnected, !Task.isCancelled else { return }
            setState(.connecting)
            do {
                let connection = try await transport.connect(to: url)
                beginSession(connection)
                await rejoinAll()
                return
            } catch {
                logger.debug("reconnect attempt \(attempt) failed", metadata: ["error": "\(error)"])
                setState(.disconnected)
                attempt += 1
            }
        }
    }

    /// Re-establishes membership for every desired topic ("the client
    /// reconnects and re-joins its topics"). Success surfaces on the
    /// channel's message stream as a `flight:join` message carrying the
    /// fresh initial state; a rejected rejoin surfaces as `flight:error`
    /// and drops the topic's desired flag.
    private func rejoinAll() async {
        for topic in channels.keys.sorted() where channels[topic]?.desired == true {
            do {
                let initialState = try await request(
                    topic: topic,
                    event: ReservedEvent.join.rawValue,
                    payload: .object([:]),
                    timeout: configuration.pushTimeout
                )
                guard state == .connected else { return }
                channels[topic]?.joined = true
                deliver(
                    Envelope(ref: nil, topic: topic, event: ReservedEvent.join.rawValue, payload: initialState),
                    topic: topic
                )
            } catch let error as ChannelClientError {
                if case .channelError(let reason) = error {
                    channels[topic]?.desired = false
                    deliver(
                        Envelope(
                            ref: nil,
                            topic: topic,
                            event: ReservedEvent.error.rawValue,
                            payload: .object([ChannelProtocol.errorReasonKey: .string(reason)])
                        ),
                        topic: topic
                    )
                }
                // .disconnected/.timedOut: the drop machinery is already
                // re-driving; this loop's successor will retry.
            } catch {
                return
            }
        }
    }

    // MARK: - Housekeeping

    private func markAllUnjoined() {
        for topic in channels.keys {
            channels[topic]?.joined = false
        }
    }

    private func setState(_ newState: ConnectionState) {
        guard newState != state else { return }
        state = newState
        for continuation in stateSubscribers.values {
            continuation.yield(newState)
        }
    }

    private func removeSubscriber(_ id: UUID, topic: String) {
        channels[topic]?.subscribers[id] = nil
    }

    private func removeStateSubscriber(_ id: UUID) {
        stateSubscribers[id] = nil
    }

    // MARK: - Introspection (tests, diagnostics)

    public func isJoined(_ topic: String) -> Bool {
        channels[topic]?.joined == true
    }
}
