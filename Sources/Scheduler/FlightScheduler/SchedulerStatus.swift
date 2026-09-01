import Foundation
import Synchronization

/// What the scheduler is doing, for anything that wants to show it.
///
/// Registered as a singleton by ``FlightSchedulerModule``, so a controller
/// can resolve it and expose `/jobs`, or a health check can assert that a
/// critical job ran recently:
///
/// ```swift
/// @Controller("/jobs")
/// struct JobsController {
///     @Inject var scheduler: SchedulerStatus
///
///     @GetRoute("/")
///     func index(_ context: RequestContext) -> [JobStatus] {
///         scheduler.snapshot()
///     }
/// }
/// ```
///
/// Deliberately *not* an actuator endpoint. The actuator collects what it
/// shows through `Container.allRegistrations()` — generic introspection with
/// no per-feature coupling — and adding a scheduler endpoint there would
/// make every application that wants `/actuator/health` link the scheduler.
/// Publishing a resolvable component instead keeps the dependency pointing
/// the way it already points, and an application that wants the data on an
/// actuator-shaped URL can put it there in four lines.
///
/// Kept small on purpose: enough to answer "is this running, and did it
/// work", not a metrics system. Anything that needs rates and histograms
/// should emit them from the job.
public final class SchedulerStatus: Sendable {
    private let jobs = Mutex<[String: JobStatus]>([:])
    private let modeBox = Mutex<SchedulerMode>(.singleProcess)

    public init() {}

    /// How coordination is resolved, as reported at startup.
    public var mode: SchedulerMode { modeBox.withLock { $0 } }

    /// Every known job, sorted by name so output is stable between calls —
    /// a status page that reorders itself on refresh is a status page nobody
    /// reads carefully.
    public func snapshot() -> [JobStatus] {
        jobs.withLock { Array($0.values) }.sorted { $0.name < $1.name }
    }

    public func status(of job: String) -> JobStatus? {
        jobs.withLock { $0[job] }
    }

    func record(_ status: JobStatus) {
        jobs.withLock { $0[status.name] = status }
    }

    func setMode(_ mode: SchedulerMode) {
        modeBox.withLock { $0 = mode }
    }
}
