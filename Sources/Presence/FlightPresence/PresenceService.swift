import FlightCore
import Synchronization
import FlightPubSub
import Logging
import ServiceLifecycle

/// Presence's long-running half: consumes the gossip topic,
/// runs the periodic re-announce (heartbeats in degraded mode, anti-entropy
/// in membership mode), the liveness sweep, and — in membership mode — the
/// monitor's event stream. Added to the app `ServiceGroup` by
/// `FlightPresenceModule`.
///
/// Startup logs which failure-detection mode is active, loudly.
public struct PresenceService: Service, Sendable {

    private let tracker: PresenceTracker
    private let pubsub: any PubSub
    private let monitor: (any PresenceMembershipMonitor)?
    private let configuration: PresenceConfiguration
    private let logger: Logger

    /// Built from what `FlightPresenceModule` holds.
    ///
    /// There used to be a second initializer taking a `Container`, and a
    /// `Source` enum to hold either — because the module registered factories
    /// and its service was constructed *pre-freeze*, so the components did not
    /// exist yet and `run()` had to resolve them. A module that owns its
    /// components has them before any container exists, so the seam that
    /// existed only for tests is now the whole thing.
    public init(
        tracker: PresenceTracker,
        pubsub: any PubSub,
        monitor: (any PresenceMembershipMonitor)?,
        configuration: PresenceConfiguration,
        logger: Logger = Logger(label: "flight.presence")
    ) {
        self.tracker = tracker
        self.pubsub = pubsub
        self.monitor = monitor
        self.configuration = configuration
        self.logger = logger
    }

    public func run() async throws {
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

        // Set when gossip intake or the monitor stream ends unexpectedly, so
        // the group can be torn down rather than left half-working. A class
        // because `Atomic` is non-copyable and two child tasks need it.
        let upstreamEnded = UpstreamFailureFlag()

        await cancelWhenGracefulShutdown {
            await withTaskGroup(of: Void.self) { group in
                // Subscribe before announcing (PubSub "effective when
                // subscribe returns"): the sync responses our startup
                // request provokes must find us listening.
                let gossip = pubsub.subscribe(PresenceGossip.topic)
                group.addTask { [logger, upstreamEnded] in
                    for await message in gossip {
                        await tracker.receiveGossip(message)
                    }
                    // The stream ended. Under cancellation that is shutdown;
                    // otherwise this node has stopped receiving remote
                    // presence entirely and will not notice — the heartbeat
                    // and sweep tasks loop forever, so `waitForAll` kept
                    // waiting and `run()` never returned. The service looked
                    // healthy while presence was, quietly, one node's view.
                    guard Task.isCancelled else {
                        logger.error(
                            """
                            presence gossip subscription ended while the service was running; \
                            this node can no longer see remote presence and is failing the service \
                            rather than serving a stale local-only view
                            """
                        )
                        upstreamEnded.raise()
                        return
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
                    group.addTask { [logger, upstreamEnded] in
                        for await event in monitor.events() {
                            await tracker.membershipEvent(event)
                        }
                        guard Task.isCancelled else {
                            logger.error(
                                """
                                presence membership monitor stream ended while the service was \
                                running; failure detection has stopped and dead nodes would stay \
                                visible until the fallback expiry, so the service is failing rather \
                                than pretending to detect anything
                                """
                            )
                            upstreamEnded.raise()
                            return
                        }
                    }
                }
                // An upstream that ends is a failure, not a quiet
                // degradation: cancel the rest so `run()` returns and the
                // ServiceGroup's policy — `.failsApp` for a clustered
                // deployment — actually gets to apply.
                while await group.next() != nil {
                    if upstreamEnded.isRaised {
                        group.cancelAll()
                    }
                }
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
                "presence running with membership-aware failure detection — prompt leave on node death",
                metadata: ["replica": "\(replica)", "anti-entropy-interval": "\(configuration.heartbeatInterval)"]
            )
        case .heartbeatExpiry:
            // Warning level, deliberately: this is the degraded mode the
            // design insists nobody discovers from a bug report.
            logger.warning(
                """
                presence running in DEGRADED heartbeat-expiry mode: the PubSub adapter provides no \
                membership signal, so a crashed node's users stay visible for up to down-after, and a \
                slow node may flap. Acceptable for deployments tolerating delayed leaves; use the \
                membership-aware adapter for prompt, correct presence
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
}

/// One-way flag: an upstream presence stream ended when it should not have.
final class UpstreamFailureFlag: Sendable {
    private let raised = Mutex(false)
    func raise() { raised.withLock { $0 = true } }
    var isRaised: Bool { raised.withLock { $0 } }
}
