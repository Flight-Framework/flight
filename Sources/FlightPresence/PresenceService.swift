import FlightCore
import FlightPubSub
import Logging
import ServiceLifecycle

/// Presence's long-running half (design §9): consumes the gossip topic,
/// runs the periodic re-announce (heartbeats in degraded mode, anti-entropy
/// in membership mode), the liveness sweep, and — in membership mode — the
/// monitor's event stream. Registered in the app `ServiceGroup` by
/// `FlightPresenceModule`.
///
/// Startup logs which failure-detection mode is active, loudly (§5.2, §9).
public struct PresenceService: Service, Sendable {

    private enum Source: Sendable {
        /// Module wiring: resolve at `run()` — the service is constructed
        /// pre-freeze (Core §7 collects services during configuration).
        case container(Container)
        case direct(
            tracker: PresenceTracker,
            pubsub: any PubSub,
            monitor: (any PresenceMembershipMonitor)?,
            configuration: PresenceConfiguration
        )
    }

    private let source: Source
    private let logger: Logger

    public init(container: Container, logger: Logger = Logger(label: "flight.presence")) {
        self.source = .container(container)
        self.logger = logger
    }

    /// For direct embedding and tests, bypassing the container.
    public init(
        tracker: PresenceTracker,
        pubsub: any PubSub,
        monitor: (any PresenceMembershipMonitor)?,
        configuration: PresenceConfiguration,
        logger: Logger = Logger(label: "flight.presence")
    ) {
        self.source = .direct(tracker: tracker, pubsub: pubsub, monitor: monitor, configuration: configuration)
        self.logger = logger
    }

    public func run() async throws {
        let tracker: PresenceTracker
        let pubsub: any PubSub
        let monitor: (any PresenceMembershipMonitor)?
        let configuration: PresenceConfiguration
        switch source {
        case .direct(let t, let p, let m, let c):
            (tracker, pubsub, monitor, configuration) = (t, p, m, c)
        case .container(let container):
            tracker = try container.resolve(PresenceTracker.self)
            pubsub = try container.resolve((any PubSub).self)
            monitor = Self.optionalMonitor(container)
            configuration = try container.resolve(PresenceConfiguration.self)
        }

        let mode = tracker.mode
        logStartup(mode: mode, replica: tracker.replica, configuration: configuration)

        guard mode != .singleNode else {
            // Nothing periodic to do and nothing to gossip; park until
            // shutdown so the ServiceGroup's `.failsApp` policy stays
            // meaningful for the clustered modes.
            await cancelWhenGracefulShutdown {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3600))
                }
            }
            return
        }

        await cancelWhenGracefulShutdown {
            await withTaskGroup(of: Void.self) { group in
                // Subscribe before announcing (PubSub §2's "effective when
                // subscribe returns"): the sync responses our startup
                // request provokes must find us listening.
                let gossip = pubsub.subscribe(PresenceGossip.topic)
                group.addTask {
                    for await message in gossip {
                        await tracker.receiveGossip(message)
                    }
                }
                await tracker.announceStartup()

                group.addTask {
                    while !Task.isCancelled {
                        guard (try? await Task.sleep(for: configuration.heartbeatInterval)) != nil else { return }
                        await tracker.announce()
                    }
                }
                group.addTask {
                    while !Task.isCancelled {
                        guard (try? await Task.sleep(for: configuration.sweepInterval)) != nil else { return }
                        await tracker.sweep()
                    }
                }
                if let monitor {
                    group.addTask {
                        for await event in monitor.events() {
                            await tracker.membershipEvent(event)
                        }
                    }
                }
                await group.waitForAll()
            }
        }
        logger.info("presence service stopped")
    }

    private func logStartup(mode: PresenceMode, replica: PresenceReplicaID, configuration: PresenceConfiguration) {
        switch mode {
        case .singleNode:
            logger.info(
                "presence running in single-node mode — no gossip, node failure is not a distributed concern",
                metadata: ["replica": "\(replica)"]
            )
        case .membership:
            logger.info(
                "presence running with membership-aware failure detection — prompt leave on node death (§5.1)",
                metadata: ["replica": "\(replica)", "anti-entropy-interval": "\(configuration.heartbeatInterval)"]
            )
        case .heartbeatExpiry:
            // Warning level, deliberately: this is the degraded mode the
            // design insists nobody discovers from a bug report (§5.2).
            logger.warning(
                """
                presence running in DEGRADED heartbeat-expiry mode: the PubSub adapter provides no \
                membership signal, so a crashed node's users stay visible for up to down-after, and a \
                slow node may flap. Acceptable for deployments tolerating delayed leaves; use the \
                membership-aware adapter for prompt, correct presence (design §5.2)
                """,
                metadata: [
                    "replica": "\(replica)",
                    "heartbeat-interval": "\(configuration.heartbeatInterval)",
                    "down-after": "\(configuration.downAfter)",
                    "permdown-after": "\(configuration.permdownAfter)",
                ]
            )
        }
    }

    /// Absent monitor = degraded or single-node mode; any other resolution
    /// failure is a real wiring bug and surfaces at tracker construction.
    static func optionalMonitor(_ container: Container) -> (any PresenceMembershipMonitor)? {
        try? container.resolve((any PresenceMembershipMonitor).self)
    }
}
