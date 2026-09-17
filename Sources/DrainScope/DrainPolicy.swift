//
//  DrainPolicy.swift
//  DrainScope
//

import Foundation

/// The written-down version of "how long is cleanup allowed to take, and what
/// do we drop when it takes longer."
///
/// Most codebases have this policy — it is just implicit, scattered across
/// `Task { try? await ... }` calls, and different on every screen. Making it a
/// value means it can be reviewed, diffed and tested.
public struct DrainPolicy: Sendable, Equatable, Codable {

    /// Total time granted to the whole drain.
    ///
    /// Once elapsed, remaining ``DrainCriticality/bestEffort`` steps are
    /// skipped outright and remaining ``DrainCriticality/required`` steps fall
    /// back to ``requiredStepGrace`` each.
    public let totalBudget: Duration

    /// Per-step cap for a `required` step reached after the total budget is
    /// gone.
    ///
    /// This is the number that stops "required" from meaning "unbounded". A
    /// scope with N required steps can therefore overrun the total budget by at
    /// most `N * requiredStepGrace` — bounded, and written down, rather than
    /// open-ended.
    public let requiredStepGrace: Duration

    /// Maximum number of steps a single scope will accept.
    ///
    /// A drain registry is append-only for the life of the scope, so an
    /// unbounded one is a leak with a slow fuse: a screen that registers a step
    /// per retry grows until teardown itself is the outage. Registering past
    /// this ceiling throws rather than silently growing.
    public let capacity: Int

    /// The largest duration a policy will accept, in either field.
    ///
    /// Not defensive padding. `Duration` is a 128-bit quantity, but
    /// `ContinuousClock.sleep(until:)` narrows it, so handing it a duration near
    /// `Int64.max` seconds is a **fatal error inside the shielded drain task** —
    /// a teardown library crashing the process during teardown, which defeats
    /// the entire point. One day is far past any defensible teardown budget, so
    /// clamping here costs nothing real.
    public static let maximumDuration: Duration = .seconds(86_400)

    /// Values outside the usable range are clamped, not rejected: negatives and
    /// zero-or-less capacities come up to the floor, absurd durations come down
    /// to ``maximumDuration``.
    ///
    /// Clamping rather than throwing because callers build policies in property
    /// initialisers, where a throwing init is the wrong trade for a config
    /// value — but clamping only works if it is total, which is why the upper
    /// bound exists and why ``init(from:)`` routes back through here.
    public init(
        totalBudget: Duration,
        requiredStepGrace: Duration,
        capacity: Int
    ) {
        self.totalBudget = Self.clamp(totalBudget)
        self.requiredStepGrace = Self.clamp(requiredStepGrace)
        self.capacity = capacity > 0 ? capacity : 1
    }

    private static func clamp(_ duration: Duration) -> Duration {
        if duration < .zero { return .zero }
        if duration > maximumDuration { return maximumDuration }
        return duration
    }

    /// 2 seconds total, 250 ms of grace per required step, 512 steps.
    ///
    /// The 2 s figure is chosen against the platform constraint that actually
    /// bites: `UIApplication`'s background-task style grace after the scene
    /// resigns active is short and not contractual, and a watchdog termination
    /// during teardown produces exactly the missing-rollback bug this library
    /// exists to prevent. Budget for less than you think you have.
    public static let `default` = DrainPolicy(
        totalBudget: .seconds(2),
        requiredStepGrace: .milliseconds(250),
        capacity: 512
    )

    /// Everything `bestEffort` is dropped immediately; only `required` steps run.
    ///
    /// The posture for "the OS is about to kill us": app termination, or a
    /// memory-pressure teardown where the next allocation may not return.
    public static let hostile = DrainPolicy(
        totalBudget: .zero,
        requiredStepGrace: .milliseconds(100),
        capacity: 512
    )

    /// 30 seconds total. For batch and CLI contexts where there is no watchdog
    /// and finishing is worth more than exiting.
    public static let patient = DrainPolicy(
        totalBudget: .seconds(30),
        requiredStepGrace: .seconds(5),
        capacity: 4096
    )
}

// MARK: - Codable

extension DrainPolicy {

    private enum CodingKeys: String, CodingKey {
        case totalBudget, requiredStepGrace, capacity
    }

    /// Routes decoded values back through the clamping initializer.
    ///
    /// Synthesized `Codable` would assign the stored properties directly and
    /// silently bypass every invariant the memberwise init promises. That is not
    /// hypothetical for this type: a policy is meant to be reviewable config, so
    /// it will be decoded from JSON, and a decoded `capacity: 0` makes
    /// ``DrainScope/register(_:criticality:_:)`` reject *every* step — turning
    /// the scope into a silent no-op that drops the rollback it exists to run.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            totalBudget: try container.decode(Duration.self, forKey: .totalBudget),
            requiredStepGrace: try container.decode(Duration.self, forKey: .requiredStepGrace),
            capacity: try container.decode(Int.self, forKey: .capacity)
        )
    }
}

// MARK: - Errors

public enum DrainScopeError: Error, Equatable, CustomStringConvertible {

    /// A step was registered after ``DrainScope/drain()`` had already snapshotted
    /// the registry.
    ///
    /// This is a real bug class, not a defensive check: a resource acquired
    /// *during* teardown that registers its own cleanup would be accepted into a
    /// list nobody will read again, and would silently never run. Failing loudly
    /// is the only honest option.
    case alreadyDraining

    /// ``DrainPolicy/capacity`` reached.
    case capacityExceeded(capacity: Int)

    /// Step names are the transcript's primary key, so they must be unique.
    case duplicateName(String)

    public var description: String {
        switch self {
        case .alreadyDraining:
            return "DrainScope: cannot register after the drain has started; this step would never run."
        case .capacityExceeded(let capacity):
            return "DrainScope: registry is full (capacity \(capacity))."
        case .duplicateName(let name):
            return "DrainScope: a step named '\(name)' is already registered."
        }
    }
}

// MARK: - Clock

/// The time source a drain measures itself against.
///
/// Injected rather than hardcoded for two reasons. The obvious one is tests.
/// The load-bearing one is that picking the clock is a real decision: a teardown
/// budget measured on the *wall* clock is wrong, because an NTP step or a user
/// changing the date silently lengthens or collapses the budget.
public protocol DrainClock: Sendable {

    /// Monotonically non-decreasing time since an arbitrary fixed origin.
    var uptime: Duration { get }

    /// Cancellable sleep. Must throw on cancellation for budget enforcement to work.
    func sleep(for duration: Duration) async throws
}

/// Production clock, backed by `ContinuousClock`.
///
/// `ContinuousClock` over `SuspendingClock` is deliberate: `SuspendingClock`
/// stops while the device is suspended, but the OS watchdog that will kill the
/// process does not. Budgeting against a clock that pauses would hand out time
/// the process does not actually have.
public struct ContinuousDrainClock: DrainClock {

    private let origin: ContinuousClock.Instant
    private let clock = ContinuousClock()

    public init() {
        self.origin = ContinuousClock.now
    }

    public var uptime: Duration { ContinuousClock.now - origin }

    public func sleep(for duration: Duration) async throws {
        guard duration > .zero else {
            try Task.checkCancellation()
            return
        }
        try await clock.sleep(for: duration)
    }
}

// MARK: - Duration helpers

extension Duration {

    fileprivate static let largestRepresentableComponents =
        Duration(secondsComponent: .max, attosecondsComponent: 0)

    fileprivate static let smallestRepresentableComponents =
        Duration(secondsComponent: .min, attosecondsComponent: 0)

    /// Whole milliseconds, saturating instead of trapping.
    ///
    /// `Duration` is a 128-bit quantity and `Int` is 32-bit on watchOS, so the
    /// narrowing is a real overflow site rather than a theoretical one. The
    /// bounds are derived from `Int.max`/`Int.min` rather than written as 64-bit
    /// literals so the clamp is correct on both word sizes.
    public var drainMilliseconds: Int {
        // `Duration.components` traps on its own when the seconds component does
        // not fit in `Int64` — `Duration` is 128-bit internally, so a value built
        // by subtracting two extreme durations is representable but its
        // components are not. The bound therefore has to be checked BEFORE
        // reading `components`, not after: guarding only the multiply and the add
        // leaves the trap one line earlier, where the guards cannot see it.
        if self >= Self.largestRepresentableComponents { return .max }
        if self <= Self.smallestRepresentableComponents { return .min }

        let parts = components

        let scaled = parts.seconds.multipliedReportingOverflow(by: 1_000)
        let secondsInMilliseconds: Int64 = scaled.overflow
            ? (parts.seconds > 0 ? Int64.max : Int64.min)
            : scaled.partialValue

        // 1 ms == 1e15 attoseconds. Divisor is a non-zero literal, so this
        // division cannot trap, and `attoseconds` is bounded well inside Int64.
        let attosecondsInMilliseconds = parts.attoseconds / 1_000_000_000_000_000

        let summed = secondsInMilliseconds.addingReportingOverflow(attosecondsInMilliseconds)
        let total: Int64 = summed.overflow
            ? (secondsInMilliseconds > 0 ? Int64.max : Int64.min)
            : summed.partialValue

        if total >= Int64(Int.max) { return Int.max }
        if total <= Int64(Int.min) { return Int.min }
        return Int(total)
    }
}
