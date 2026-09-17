//
//  DrainScope.swift
//  DrainScope
//

import Foundation

// MARK: - Step

/// One registered unit of teardown.
struct DrainStep: Sendable {
    let name: String
    let criticality: DrainCriticality
    let body: @Sendable () async throws -> Void
}

// MARK: - DrainScope

/// An ordered, budgeted, exactly-once teardown registry that survives the
/// cancellation of the task that owns it.
///
/// ## The bug this exists to prevent
///
/// Swift's cancellation is cooperative *and contagious*. Once a task is
/// cancelled, every cancellation-aware `await` **in that task** starts failing
/// immediately — including the awaits in the cleanup path. Cleanup written where
/// cleanup naturally goes therefore runs inside the very task that has just been
/// cancelled:
///
/// ```swift
/// let tx = try await database.begin()
/// do {
///     try await payments.authorize()   // ← cancelled here
///     try await tx.commit()
/// } catch {
///     try? await tx.rollback()         // ← this await throws too. Immediately.
/// }
/// ```
///
/// The `catch` block runs in the cancelled task, so `rollback()`'s first `await`
/// throws `CancellationError` before it does anything, `try?` swallows it, and
/// the transaction is left open. The failure is silent, it only happens under
/// cancellation, and `try?` is what hides it. A structured child — `async let`,
/// or a task group — inherits cancellation too, so moving the cleanup into one
/// does not help.
///
/// (An unstructured `Task { }` is a different trap rather than this one: it does
/// **not** inherit cancellation, so the rollback does start — but nobody awaits
/// it, so the scene can deactivate or the process exit mid-rollback, and the
/// ordering between several of them is undefined.)
///
/// ## What this guarantees
///
/// 1. **Shielded.** Steps run inside a detached task, so the caller's
///    cancellation does not propagate into them. ``drain()`` still awaits that
///    task, so the work is not fire-and-forget either.
/// 2. **LIFO.** Steps run in reverse registration order — `defer` semantics,
///    which is what resource ownership actually needs.
/// 3. **Exactly once.** Concurrent and repeated ``drain()`` calls share one
///    execution and one transcript.
/// 4. **Bounded.** No step gets more than its cap; the whole drain is bounded by
///    `totalBudget + (requiredStepCount * requiredStepGrace)`.
/// 5. **Isolated.** A throwing step does not abort the drain; it is recorded.
/// 6. **Evidenced.** Every step produces a ``DrainRecord``.
///
/// ## What this does not guarantee
///
/// The budget bounds the time a step is **granted**, not the time an
/// uncooperative step can **take**. Cancellation is cooperative all the way
/// down; nothing in-process can preempt a step that never checks
/// `Task.isCancelled` and never hits a cancellation-aware suspension point.
/// Such a step will overrun its cap and the drain will wait for it.
///
/// This is a real limit, not an implementation gap — and it is why the
/// transcript matters. A hard wall-clock bound on process exit can only come
/// from outside the process; what this library gives you is the evidence
/// naming *which* step to fix.
public actor DrainScope {

    private enum State {
        case open
        case draining(Task<DrainTranscript, Never>)
        case drained(DrainTranscript)
    }

    private var state: State = .open
    private var steps: [DrainStep] = []
    private var names: Set<String> = []

    public let policy: DrainPolicy
    private let clock: any DrainClock

    public init(policy: DrainPolicy = .default, clock: any DrainClock = ContinuousDrainClock()) {
        self.policy = policy
        self.clock = clock
    }

    // MARK: Introspection

    public var registeredCount: Int { steps.count }

    /// `nil` until the drain has finished. The distinction between `nil` and
    /// ``DrainTranscript/empty(budget:)`` is load-bearing: "we never drained"
    /// and "we drained and there was nothing to do" are different incidents.
    public var transcript: DrainTranscript? {
        if case .drained(let transcript) = state { return transcript }
        return nil
    }

    public var hasDrained: Bool {
        if case .drained = state { return true }
        return false
    }

    // MARK: Registration

    /// Registers a teardown step. Steps run in reverse registration order.
    ///
    /// - Throws: ``DrainScopeError/alreadyDraining`` if the drain has started,
    ///   ``DrainScopeError/duplicateName(_:)`` if `name` is taken, or
    ///   ``DrainScopeError/capacityExceeded(capacity:)`` at the ceiling.
    ///   All three are programmer errors that would otherwise be silent.
    public func register(
        _ name: String,
        criticality: DrainCriticality = .bestEffort,
        _ body: @escaping @Sendable () async throws -> Void
    ) throws {
        guard case .open = state else { throw DrainScopeError.alreadyDraining }
        guard !names.contains(name) else { throw DrainScopeError.duplicateName(name) }
        guard steps.count < policy.capacity else {
            throw DrainScopeError.capacityExceeded(capacity: policy.capacity)
        }
        names.insert(name)
        steps.append(DrainStep(name: name, criticality: criticality, body: body))
    }

    // MARK: Draining

    /// Runs every registered step under the policy and returns the transcript.
    ///
    /// Safe to call from an already-cancelled task — that is the point. Safe to
    /// call repeatedly and concurrently: the first call performs the work, every
    /// other call awaits and returns the same transcript.
    public func drain() async -> DrainTranscript {

        // Draining *this* scope from inside its own teardown step would await
        // the very task that step is running on: a permanent hang that
        // `cancel()` cannot break, because the shield is uncancellable by
        // design. It is a programmer error, and `drain()` cannot throw, so trap
        // it in debug and degrade to a no-op in release rather than deadlocking
        // a shutdown path.
        //
        // Keyed on scope identity, not on "is any drain running": a teardown
        // step that owns a sub-component with its own `DrainScope` is legitimate
        // composition, awaits a *different* detached task, and cannot deadlock.
        // Rejecting it would silently drop that component's required work, which
        // is the exact failure this library exists to prevent.
        let identity = ObjectIdentifier(self)
        if DrainExecutor.drainingScopes.contains(identity) {
            assertionFailure(
                "DrainScope.drain() was called re-entrantly on the same scope from inside one "
                + "of its own teardown steps. This would deadlock. Remove the nested drain() call."
            )
            return DrainTranscript.empty(budget: policy.totalBudget)
        }

        switch state {
        case .drained(let transcript):
            return transcript

        case .draining(let task):
            // Another caller already owns the execution. Await the same one
            // rather than starting a second drain.
            let transcript = await task.value

            // Advance the state here too. Only the owning call used to do it, so
            // a joining caller could return a complete transcript while the
            // actor still reported `hasDrained == false` and `transcript == nil`
            // — and that nil is documented to mean "we never drained", which
            // would file a successful teardown as a missing one.
            if case .draining = state {
                state = .drained(transcript)
                steps.removeAll()
                names.removeAll()
            }
            return transcript

        case .open:
            let ordered = Array(steps.reversed())
            let policy = self.policy
            let clock = self.clock

            // The shield. `Task.detached` does not inherit the caller's task —
            // and therefore does not inherit its cancellation. Awaiting `.value`
            // below keeps this structured from the caller's point of view: the
            // work is shielded, not abandoned.
            // Read in the caller's task so an outer drain's identity is carried
            // across the detach; `Task.detached` inherits no task-locals of its
            // own, but the values do propagate from inside the closure into the
            // structured children that run each step body.
            let enclosing = DrainExecutor.drainingScopes

            let task = Task.detached(priority: .high) {
                await DrainExecutor.$drainingScopes.withValue(enclosing.union([identity])) {
                    await DrainExecutor.run(steps: ordered, policy: policy, clock: clock)
                }
            }

            // Published before the first suspension point, so a reentrant
            // caller arriving during the `await` below observes `.draining`
            // and joins this execution instead of starting another.
            state = .draining(task)

            let transcript = await task.value
            state = .drained(transcript)

            // The registry is append-only for the life of the scope, and every
            // closure in it captures the thing it tears down — a transaction, a
            // file handle, a lease. Holding them after the teardown that
            // released them keeps dead resources alive for as long as the scope
            // lives, which for an app-lifecycle scope is the whole session.
            steps.removeAll()
            names.removeAll()

            return transcript
        }
    }
}

// MARK: - Executor

/// The drain loop. Deliberately not isolated to ``DrainScope`` — it runs inside
/// the detached shield task, and taking actor isolation there would serialise
/// teardown against any other caller touching the scope.
enum DrainExecutor {

    /// Identities of the scopes currently draining, for any task descended from
    /// a shield. A set rather than a flag so nested scopes compose.
    @TaskLocal static var drainingScopes: Set<ObjectIdentifier> = []

    private enum StepSignal: Sendable {
        case finished(DrainFailure?)
        case expired
    }

    static func run(
        steps: [DrainStep],
        policy: DrainPolicy,
        clock: any DrainClock
    ) async -> DrainTranscript {

        guard !steps.isEmpty else {
            return DrainTranscript.empty(budget: policy.totalBudget)
        }

        let started = clock.uptime
        var records: [DrainRecord] = []
        records.reserveCapacity(steps.count)
        var budgetExhausted = false

        for (index, step) in steps.enumerated() {

            // Remaining budget computed by subtraction from a monotonic origin,
            // never by adding a deadline: `totalBudget` is caller-supplied and
            // adding it to a clock reading is an overflow site for no benefit.
            let elapsed = clock.uptime - started
            let remaining: Duration = policy.totalBudget > elapsed
                ? policy.totalBudget - elapsed
                : .zero

            let cap: Duration
            if remaining > .zero {
                // A `required` step is entitled to its grace even when the
                // clock is nearly out, so that "required" cannot degrade into
                // "whatever milliseconds happened to be left".
                cap = step.criticality == .required
                    ? max(remaining, policy.requiredStepGrace)
                    : remaining
            } else {
                budgetExhausted = true
                guard step.criticality == .required else {
                    records.append(
                        DrainRecord(
                            name: step.name,
                            criticality: step.criticality,
                            outcome: .skippedBudgetExhausted,
                            duration: .zero,
                            order: index
                        )
                    )
                    continue
                }
                cap = policy.requiredStepGrace
            }

            guard cap > .zero else {
                // A zero cap cannot grant the step any time at all, so the body
                // is never invoked. Recording that as `.timedOut` would claim the
                // step started and was cancelled — a transcript that lies about
                // what ran is worse than no transcript.
                records.append(
                    DrainRecord(
                        name: step.name,
                        criticality: step.criticality,
                        outcome: .notAttempted,
                        duration: .zero,
                        order: index
                    )
                )
                continue
            }

            let stepStarted = clock.uptime
            let outcome = await execute(step: step, cap: cap, clock: clock)
            let stepElapsed = clock.uptime - stepStarted

            records.append(
                DrainRecord(
                    name: step.name,
                    criticality: step.criticality,
                    outcome: outcome,
                    duration: stepElapsed,
                    order: index
                )
            )
        }

        let totalElapsed = clock.uptime - started

        return DrainTranscript(
            records: records,
            elapsed: totalElapsed,
            budget: policy.totalBudget,
            // Also true when the last step consumed exactly the remainder: the
            // loop only observes exhaustion at a step boundary, and this is an
            // audit field, so it has to agree with its own documentation.
            budgetExhausted: budgetExhausted || totalElapsed >= policy.totalBudget
        )
    }

    /// Races the step body against its cap. Whichever finishes first decides the
    /// outcome; the loser is cancelled.
    private static func execute(
        step: DrainStep,
        cap: Duration,
        clock: any DrainClock
    ) async -> DrainOutcome {

        await withTaskGroup(of: StepSignal.self, returning: DrainOutcome.self) { group in

            group.addTask {
                do {
                    try await step.body()
                    return .finished(nil)
                } catch {
                    return .finished(DrainFailure(error))
                }
            }

            group.addTask {
                // A cancelled sleep means the body won the race; either way the
                // only thing this child reports is "the cap elapsed".
                try? await clock.sleep(for: cap)
                return .expired
            }

            var outcome: DrainOutcome = .timedOut
            if let first = await group.next() {
                switch first {
                case .finished(nil):
                    outcome = .completed
                case .finished(.some(let failure)):
                    outcome = .failed(failure)
                case .expired:
                    outcome = .timedOut
                }
            }

            // Stops the loser. For `.expired` this is the budget being enforced
            // against the overrunning body; for a finished body it just wakes
            // the sleeper early.
            group.cancelAll()
            return outcome
        }
    }
}
