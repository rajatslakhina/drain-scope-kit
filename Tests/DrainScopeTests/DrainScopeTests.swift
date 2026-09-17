//
//  DrainScopeTests.swift
//  DrainScopeTests
//

import XCTest
@testable import DrainScope

final class DrainScopeTests: XCTestCase {

    // MARK: - The headline guarantee: shielded from cancellation

    /// The reason this library exists: teardown registered inside a task that is
    /// later cancelled must still run to completion.
    ///
    /// The step's body uses a cancellation-aware `await`. If the step inherited
    /// the caller's cancelled state, that `await` would throw immediately and the
    /// outcome would be `.failed(CancellationError)` rather than `.completed`.
    func testDrainCompletesAfterTheOwningTaskIsCancelled() async throws {
        let recorder = Recorder()
        let scope = DrainScope(policy: .patient)

        try await scope.register("rollback", criticality: .required) {
            try await Task.sleep(for: .milliseconds(40))
            await recorder.record("rollback")
        }

        let task = Task { () -> DrainTranscript in
            // Stands in for the real work being cancelled mid-flight.
            do { try await Task.sleep(for: .seconds(30)) } catch { }
            XCTAssertTrue(Task.isCancelled, "precondition: this task must actually be cancelled")
            return await scope.drain()
        }

        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        let transcript = await task.value

        XCTAssertEqual(transcript.outcome(for: "rollback"), .completed)
        let rollbackRuns = await recorder.count(of: "rollback")
        XCTAssertEqual(rollbackRuns, 1)
        XCTAssertTrue(transcript.requiredWorkCompleted)
    }

    /// NEGATIVE CONTROL for the test above — and the exact pattern the README's
    /// opening example blames.
    ///
    /// Cleanup written in the `catch` block runs *in the cancelled task*, so its
    /// own first `await` throws before it does anything and `try?` hides that.
    /// A structured child (`async let`, a task group) inherits cancellation too,
    /// so moving the cleanup into one does not help — both arms are asserted here.
    ///
    /// Without this, `testDrainCompletesAfterTheOwningTaskIsCancelled` would pass
    /// against a `DrainScope` that did nothing special, because nothing would
    /// prove the harness actually cancels anything. This is what gives the shield
    /// test its teeth.
    func testCleanupInTheCancelledTaskIsSilentlySkipped() async throws {
        let recorder = Recorder()

        let task = Task {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                // Arm 1 — cleanup inline in the catch block, i.e. in the
                // cancelled task itself. `try?` swallows the CancellationError.
                do {
                    try await Task.sleep(for: .milliseconds(40))
                    await recorder.record("catch-block")
                } catch { }
            }

            XCTAssertTrue(Task.isCancelled, "precondition: this task must actually be cancelled")

            // Arm 2 — cleanup moved into a structured child, which inherits the
            // cancellation and fails the same way.
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        try await Task.sleep(for: .milliseconds(40))
                        await recorder.record("structured-child")
                    } catch { }
                }
            }
        }

        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        await task.value

        let inCatchBlock = await recorder.count(of: "catch-block")
        let inStructuredChild = await recorder.count(of: "structured-child")
        XCTAssertEqual(
            inCatchBlock, 0,
            "Negative control failed: cleanup in the catch block ran, so this scenario is not "
            + "actually exercising cancellation and the shield test proves nothing."
        )
        XCTAssertEqual(
            inStructuredChild, 0,
            "Negative control failed: a structured child escaped cancellation, which it must not."
        )
    }

    /// `withDrainScope` is the packaged form of the same guarantee: the drain
    /// happens after the `catch`, inside an already-cancelled context.
    func testWithDrainScopeDrainsAfterCancellation() async throws {
        let recorder = Recorder()

        let task = Task { () -> DrainRun<Int> in
            await withDrainScope(policy: .patient) { scope in
                try await scope.register("release-lease", criticality: .required) {
                    try await Task.sleep(for: .milliseconds(40))
                    await recorder.record("release-lease")
                }
                try await Task.sleep(for: .seconds(30))
                return 42
            }
        }

        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        let run = await task.value

        XCTAssertEqual(run.outcome.label, "cancelled")
        XCTAssertNil(run.outcome.value)
        XCTAssertEqual(run.transcript.outcome(for: "release-lease"), .completed)
        let leaseReleases = await recorder.count(of: "release-lease")
        XCTAssertEqual(leaseReleases, 1)
        XCTAssertFalse(run.isClean, "the operation did not complete, so the run is not clean")
    }

    func testWithDrainScopeReportsCleanRunOnSuccess() async {
        let run = await withDrainScope(policy: .patient) { scope in
            try await scope.register("close-handle", criticality: .required) { }
            return "ok"
        }

        XCTAssertEqual(run.outcome.value, "ok")
        XCTAssertTrue(run.isClean)
        XCTAssertTrue(run.transcript.requiredWorkCompleted)
    }

    func testWithDrainScopeClassifiesAThrownErrorAsFailureNotCancellation() async {
        struct Boom: Error { }

        let run = await withDrainScope(policy: .patient) { scope in
            try await scope.register("rollback", criticality: .required) { }
            throw Boom()
        }

        XCTAssertEqual(run.outcome.label, "failed")
        // The failure must not suppress the drain.
        XCTAssertEqual(run.transcript.outcome(for: "rollback"), .completed)
    }

    // MARK: - Ordering

    /// Teardown runs LIFO, because that is what resource ownership needs: the
    /// transaction opened last is rolled back first.
    ///
    /// Asserting the exact reversed sequence means a FIFO regression fails here
    /// rather than passing a weaker "all three ran" check.
    func testStepsRunInReverseRegistrationOrder() async throws {
        let recorder = Recorder()
        let scope = DrainScope(policy: .patient)

        for name in ["open-db", "begin-tx", "acquire-lock"] {
            try await scope.register(name) { await recorder.record(name) }
        }

        let transcript = await scope.drain()

        let observed = await recorder.events
        XCTAssertEqual(observed, ["acquire-lock", "begin-tx", "open-db"])
        XCTAssertEqual(transcript.records.map(\.name), ["acquire-lock", "begin-tx", "open-db"])
        XCTAssertEqual(transcript.records.map(\.order), [0, 1, 2])

        // Explicit: registration order must NOT be execution order.
        XCTAssertNotEqual(
            transcript.records.map(\.name),
            ["open-db", "begin-tx", "acquire-lock"],
            "execution order collapsed to registration order — LIFO is broken"
        )
    }

    // MARK: - Exactly once

    /// Concurrent drains must share one execution and one transcript. A naive
    /// implementation that re-snapshots the registry would run the step three
    /// times and return three different transcripts.
    func testConcurrentDrainsRunStepsExactlyOnceAndShareOneTranscript() async throws {
        let recorder = Recorder()
        let scope = DrainScope(policy: .patient)

        try await scope.register("flush-metrics") {
            // Long enough that the three drains below genuinely overlap.
            try await Task.sleep(for: .milliseconds(60))
            await recorder.record("flush-metrics")
        }

        async let first = scope.drain()
        async let second = scope.drain()
        async let third = scope.drain()
        let transcripts = await [first, second, third]

        let flushes = await recorder.count(of: "flush-metrics")
        XCTAssertEqual(flushes, 1)
        XCTAssertEqual(transcripts[0], transcripts[1])
        XCTAssertEqual(transcripts[1], transcripts[2])
    }

    func testDrainingTwiceSequentiallyReturnsTheSameTranscript() async throws {
        let recorder = Recorder()
        let scope = DrainScope(policy: .patient)
        try await scope.register("close") { await recorder.record("close") }

        let firstTranscript = await scope.drain()
        let secondTranscript = await scope.drain()

        XCTAssertEqual(firstTranscript, secondTranscript)
        let closes = await recorder.count(of: "close")
        let drained = await scope.hasDrained
        XCTAssertEqual(closes, 1)
        XCTAssertTrue(drained)
    }

    // MARK: - Budget

    /// With no budget left, `bestEffort` is dropped and `required` still runs.
    /// Deterministic: a zero total budget means no timing dependence at all.
    func testExhaustedBudgetSkipsBestEffortAndStillRunsRequired() async throws {
        let recorder = Recorder()
        let scope = DrainScope(
            policy: DrainPolicy(totalBudget: .zero, requiredStepGrace: .seconds(2), capacity: 16)
        )

        try await scope.register("analytics", criticality: .bestEffort) {
            await recorder.record("analytics")
        }
        try await scope.register("rollback", criticality: .required) {
            await recorder.record("rollback")
        }

        let transcript = await scope.drain()

        XCTAssertEqual(transcript.outcome(for: "rollback"), .completed)
        XCTAssertEqual(transcript.outcome(for: "analytics"), .skippedBudgetExhausted)
        let observed = await recorder.events
        XCTAssertEqual(observed, ["rollback"])
        XCTAssertTrue(transcript.budgetExhausted)
        XCTAssertTrue(transcript.requiredWorkCompleted)
        XCTAssertEqual(transcript.skippedCount, 1)
    }

    /// A skipped step must be recorded with zero duration, not omitted. A step
    /// missing from the transcript and a step that was deliberately dropped are
    /// different incidents.
    func testSkippedStepsStillAppearInTheTranscript() async throws {
        let scope = DrainScope(
            policy: DrainPolicy(totalBudget: .zero, requiredStepGrace: .zero, capacity: 8)
        )
        try await scope.register("a") { }
        try await scope.register("b") { }

        let transcript = await scope.drain()

        XCTAssertEqual(transcript.records.count, 2)
        XCTAssertEqual(transcript.records.map(\.duration), [.zero, .zero])
        XCTAssertTrue(transcript.records.allSatisfy { $0.outcome == .skippedBudgetExhausted })
    }

    /// Both budget and grace at zero: nothing can run, and the drain must still
    /// terminate promptly with a complete transcript rather than hanging.
    func testZeroBudgetAndZeroGraceTerminatesWithoutRunningAnything() async throws {
        let recorder = Recorder()
        let scope = DrainScope(
            policy: DrainPolicy(totalBudget: .zero, requiredStepGrace: .zero, capacity: 8)
        )
        try await scope.register("must-not-run", criticality: .required) {
            await recorder.record("must-not-run")
        }

        let transcript = await scope.drain()

        let nothingRan = await recorder.isEmpty
        XCTAssertEqual(
            transcript.outcome(for: "must-not-run"), .notAttempted,
            "the body never ran, so the transcript must not claim it was cancelled mid-flight"
        )
        XCTAssertTrue(nothingRan)
        XCTAssertFalse(transcript.requiredWorkCompleted)
        XCTAssertEqual(transcript.timedOutCount, 0)
        XCTAssertEqual(transcript.notAttemptedCount, 1)
    }

    /// A step that overruns its cap is cancelled and recorded as `.timedOut`.
    ///
    /// The step asks for 30 s against an 80 ms cap, so the classification holds
    /// on any machine; the elapsed bound proves the cap actually cut it short
    /// rather than the drain quietly waiting the full 30 s.
    func testStepExceedingItsCapIsCancelledAndRecordedAsTimedOut() async throws {
        let scope = DrainScope(
            policy: DrainPolicy(
                totalBudget: .milliseconds(80),
                requiredStepGrace: .milliseconds(80),
                capacity: 8
            )
        )
        try await scope.register("hung-upload", criticality: .required) {
            try await Task.sleep(for: .seconds(30))
        }

        let transcript = await scope.drain()

        XCTAssertEqual(transcript.outcome(for: "hung-upload"), .timedOut)
        XCTAssertFalse(transcript.requiredWorkCompleted)
        XCTAssertLessThan(
            transcript.elapsed, .seconds(10),
            "the cap did not cut the step short — the drain waited on it"
        )
    }

    /// CHARACTERISATION TEST — documents the limitation, does not guard it.
    ///
    /// A step that never suspends cannot be preempted: Swift cancellation is
    /// cooperative all the way down. The library's contract is that it will not
    /// *grant* more than the cap — not that an uncooperative step cannot *take*
    /// more.
    ///
    /// Being precise about what this proves: the overrun it asserts is produced
    /// by the test's own busy-wait, so an implementation with no budget
    /// enforcement whatsoever would also pass it. It pins documented behaviour
    /// and is deliberately **not** counted among the suite's mutation guards.
    /// The tests that genuinely fail against a gutted executor are
    /// `testStepExceedingItsCapIsCancelledAndRecordedAsTimedOut`,
    /// `testRequiredStepGetsItsGraceButBestEffortDoesNot`,
    /// `testBudgetIsAccountedAgainstTheInjectedClockNotWallTime` and
    /// `testDroppedBestEffortWorkDoesNotMakeTheDrainUnclean`.
    func testUncooperativeStepOverrunsItsCapAndTheTranscriptShowsIt() async throws {
        let scope = DrainScope(
            policy: DrainPolicy(
                totalBudget: .milliseconds(30),
                requiredStepGrace: .milliseconds(30),
                capacity: 4
            )
        )
        try await scope.register("spin", criticality: .required) {
            // Never suspends, never checks `Task.isCancelled`.
            let deadline = ContinuousClock.now + .milliseconds(200)
            while ContinuousClock.now < deadline { }
        }

        let transcript = await scope.drain()

        XCTAssertNotNil(transcript.outcome(for: "spin"))
        XCTAssertGreaterThanOrEqual(
            transcript.elapsed, .milliseconds(150),
            "an unpreemptable step must be reported as the overrun it is, not clipped to the cap"
        )
    }

    /// A `required` step is entitled to its grace even when the total budget is
    /// nearly gone, so "required" cannot silently degrade into "whatever
    /// milliseconds were left".
    ///
    /// The control arm is what gives this teeth: an identical `bestEffort` step
    /// doing identical work under the same 1 ms budget must NOT complete. An
    /// implementation with no budget enforcement would complete both and fail
    /// here; one that ignored criticality would fail both.
    func testRequiredStepGetsItsGraceButBestEffortDoesNot() async throws {
        let recorder = Recorder()
        let scope = DrainScope(
            policy: DrainPolicy(
                totalBudget: .milliseconds(1),
                requiredStepGrace: .seconds(2),
                capacity: 8
            )
        )
        // LIFO: "rollback" is registered last, runs first, and burns the 1 ms
        // budget. "analytics" is then reached with nothing left.
        try await scope.register("analytics", criticality: .bestEffort) {
            try await Task.sleep(for: .milliseconds(60))
            await recorder.record("analytics")
        }
        try await scope.register("rollback", criticality: .required) {
            try await Task.sleep(for: .milliseconds(60))
            await recorder.record("rollback")
        }

        let transcript = await scope.drain()

        let observed = await recorder.events
        XCTAssertEqual(transcript.outcome(for: "rollback"), .completed)
        XCTAssertNotEqual(
            transcript.outcome(for: "analytics"), .completed,
            "best-effort work must not inherit the required step\'s grace"
        )
        XCTAssertEqual(observed, ["rollback"])
    }

    // MARK: - Failure isolation

    func testAThrowingStepDoesNotAbortTheDrain() async throws {
        struct Boom: Error { }
        let recorder = Recorder()
        let scope = DrainScope(policy: .patient)

        try await scope.register("first") { await recorder.record("first") }
        try await scope.register("explodes") { throw Boom() }
        try await scope.register("last") { await recorder.record("last") }

        let transcript = await scope.drain()

        let observed = await recorder.events
        XCTAssertEqual(observed, ["last", "first"])
        XCTAssertEqual(transcript.failedCount, 1)
        XCTAssertEqual(transcript.completedCount, 2)

        guard case .failed(let failure)? = transcript.outcome(for: "explodes") else {
            return XCTFail("expected a recorded failure for 'explodes'")
        }
        XCTAssertEqual(failure.typeName, "Boom")
    }

    // MARK: - requiredWorkCompleted semantics

    /// The asymmetry is the whole point of declaring criticality: dropping a
    /// `bestEffort` step is a budget decision, not a dirty teardown.
    ///
    /// Mutating `requiredWorkCompleted` to a naive
    /// `records.allSatisfy { $0.outcome == .completed }` fails exactly two tests:
    /// this one and `testExhaustedBudgetSkipsBestEffortAndStillRunsRequired`.
    /// That is the measured number, not a rhetorical "everything else passes".
    func testDroppedBestEffortWorkDoesNotMakeTheDrainUnclean() async throws {
        let scope = DrainScope(
            policy: DrainPolicy(totalBudget: .zero, requiredStepGrace: .seconds(2), capacity: 8)
        )
        try await scope.register("analytics", criticality: .bestEffort) { }
        try await scope.register("rollback", criticality: .required) { }

        let transcript = await scope.drain()

        XCTAssertEqual(transcript.outcome(for: "analytics"), .skippedBudgetExhausted)
        XCTAssertTrue(
            transcript.requiredWorkCompleted,
            "a dropped best-effort step must not be reported as unclean teardown"
        )
        XCTAssertFalse(transcript.unfinished.isEmpty, "it is still reported as unfinished work")
    }

    func testDroppedRequiredWorkDoesMakeTheDrainUnclean() async throws {
        let scope = DrainScope(
            policy: DrainPolicy(totalBudget: .zero, requiredStepGrace: .zero, capacity: 8)
        )
        try await scope.register("rollback", criticality: .required) { }

        let transcript = await scope.drain()

        XCTAssertFalse(transcript.requiredWorkCompleted)
    }

    // MARK: - Registration errors

    func testRegisteringAfterTheDrainStartedThrows() async throws {
        let scope = DrainScope(policy: .patient)
        _ = await scope.drain()

        do {
            try await scope.register("too-late") { }
            XCTFail("registering after the drain must throw rather than silently never run")
        } catch let error as DrainScopeError {
            XCTAssertEqual(error, .alreadyDraining)
        }
    }

    func testDuplicateNamesThrow() async throws {
        let scope = DrainScope(policy: .patient)
        try await scope.register("rollback") { }

        do {
            try await scope.register("rollback") { }
            XCTFail("duplicate step names must throw — names are the transcript's primary key")
        } catch let error as DrainScopeError {
            XCTAssertEqual(error, .duplicateName("rollback"))
        }
    }

    func testCapacityCeilingIsEnforced() async throws {
        let scope = DrainScope(
            policy: DrainPolicy(totalBudget: .seconds(1), requiredStepGrace: .zero, capacity: 3)
        )
        for index in 0..<3 {
            try await scope.register("step-\(index)") { }
        }

        do {
            try await scope.register("step-3") { }
            XCTFail("the registry must refuse to grow past its documented ceiling")
        } catch let error as DrainScopeError {
            XCTAssertEqual(error, .capacityExceeded(capacity: 3))
        }

        let finalCount = await scope.registeredCount
        XCTAssertEqual(finalCount, 3)
    }

    // MARK: - Empty scope

    func testDrainingAnEmptyScopeProducesAnEmptyTranscriptNotNil() async {
        let scope = DrainScope(policy: .default)

        let beforeDrain = await scope.transcript
        XCTAssertNil(beforeDrain, "nil means 'never drained'")

        let transcript = await scope.drain()

        XCTAssertTrue(transcript.isEmpty)
        XCTAssertEqual(transcript.records.count, 0)
        XCTAssertTrue(transcript.requiredWorkCompleted)
        XCTAssertFalse(transcript.budgetExhausted)
        XCTAssertEqual(transcript.summaryLines(), [])
        let afterDrain = await scope.transcript
        XCTAssertNotNil(afterDrain, "after draining, the transcript exists and is empty")
    }

    // MARK: - Re-entrancy and nesting

    /// A teardown step owning a sub-component with its own scope is legitimate
    /// composition, not re-entrancy: it awaits a different detached task and
    /// cannot deadlock. Rejecting it would silently drop that component's
    /// required work — the exact failure this library exists to prevent.
    func testANestedScopeInsideATeardownStepStillDrains() async throws {
        let recorder = Recorder()
        let outer = DrainScope(policy: .patient)
        let inner = DrainScope(policy: .patient)

        try await inner.register("inner-rollback", criticality: .required) {
            await recorder.record("inner-rollback")
        }
        try await outer.register("owns-a-subcomponent", criticality: .required) {
            _ = await inner.drain()
            await recorder.record("outer-step")
        }

        let transcript = await outer.drain()

        let observed = await recorder.events
        let innerTranscript = await inner.transcript
        XCTAssertEqual(observed, ["inner-rollback", "outer-step"])
        XCTAssertEqual(transcript.outcome(for: "owns-a-subcomponent"), .completed)
        XCTAssertEqual(innerTranscript?.outcome(for: "inner-rollback"), .completed)
        XCTAssertTrue(transcript.requiredWorkCompleted)
    }

    /// A caller that joins an in-flight drain must leave the actor reporting the
    /// same thing it was told. `transcript == nil` is documented to mean "we
    /// never drained", so a joining caller observing nil after a successful drain
    /// would file completed teardown as missing teardown.
    ///
    /// The structure matters: the owner is unstructured and deliberately **not**
    /// awaited before the assertions, so the *joining* call is the one whose
    /// return is being checked. Awaiting both first would make this vacuous — the
    /// owner always advances the state before it returns, so the assertion could
    /// not fail no matter what the joining branch did.
    func testAJoiningCallerLeavesTheScopeReportingItHasDrained() async throws {
        for iteration in 0..<40 {
            let scope = DrainScope(policy: .patient)
            try await scope.register("flush") {
                try await Task.sleep(for: .milliseconds(30))
            }

            let owner = Task { await scope.drain() }
            // Let the owner claim the execution so the call below joins it.
            try await Task.sleep(for: .milliseconds(5))

            let joinerTranscript = await scope.drain()
            let hasDrained = await scope.hasDrained
            let stored = await scope.transcript

            XCTAssertTrue(
                hasDrained,
                "iteration \(iteration): drain() returned a transcript but the scope denies draining"
            )
            XCTAssertEqual(
                stored, joinerTranscript,
                "iteration \(iteration): the stored transcript must match what the joiner was handed"
            )
            _ = await owner.value
        }
    }

    // MARK: - Injected clock

    /// The budget is accounted against the injected clock, not wall time.
    ///
    /// No real time passes here: `expensive` advances the manual clock by 500 ms
    /// instantly, which must be enough to exhaust a 100 ms budget and get the
    /// next step dropped. An implementation reading wall time — or doing no
    /// budget accounting at all — runs both steps and fails.
    func testBudgetIsAccountedAgainstTheInjectedClockNotWallTime() async throws {
        let clock = ManualClock()
        let recorder = Recorder()
        let scope = DrainScope(
            policy: DrainPolicy(
                totalBudget: .milliseconds(100),
                requiredStepGrace: .zero,
                capacity: 8
            ),
            clock: clock
        )

        // LIFO: "expensive" runs first and burns the budget on the manual clock.
        try await scope.register("cheap", criticality: .bestEffort) {
            await recorder.record("cheap")
        }
        try await scope.register("expensive", criticality: .bestEffort) {
            clock.advance(by: .milliseconds(500))
            await recorder.record("expensive")
        }

        let started = ContinuousClock.now
        let transcript = await scope.drain()
        let realTimeSpent = ContinuousClock.now - started

        let observed = await recorder.events
        XCTAssertEqual(transcript.outcome(for: "expensive"), .completed)
        XCTAssertEqual(transcript.outcome(for: "cheap"), .skippedBudgetExhausted)
        XCTAssertEqual(observed, ["expensive"])
        XCTAssertTrue(transcript.budgetExhausted)
        XCTAssertEqual(
            transcript.elapsed, .milliseconds(500),
            "elapsed must be measured on the injected clock"
        )
        XCTAssertLessThan(
            realTimeSpent, .seconds(5),
            "the manual clock must remove real sleeping from budget tests entirely"
        )
    }

    // MARK: - Resource lifetime

    /// The registry holds every teardown closure, and every closure captures the
    /// thing it tears down. Holding them after the drain keeps dead resources
    /// alive for the whole life of the scope.
    func testStepClosuresAreReleasedOnceTheDrainCompletes() async throws {
        final class Probe: @unchecked Sendable {
            private let onDeinit: @Sendable () -> Void
            init(onDeinit: @escaping @Sendable () -> Void) { self.onDeinit = onDeinit }
            deinit { onDeinit() }
        }

        let recorder = Recorder()
        let scope = DrainScope(policy: .patient)

        do {
            let probe = Probe { Task { await recorder.record("released") } }
            try await scope.register("holds-a-resource") {
                _ = probe          // captured strongly, exactly like a real handle
            }
        }

        let beforeDrain = await recorder.count(of: "released")
        XCTAssertEqual(beforeDrain, 0, "precondition: the closure still holds the resource")

        _ = await scope.drain()
        // The deinit notification hops through a Task; give it a moment to land.
        try await Task.sleep(for: .milliseconds(200))

        let afterDrain = await recorder.count(of: "released")
        let remaining = await scope.registeredCount
        XCTAssertEqual(afterDrain, 1, "the scope must drop its step closures once they have run")
        XCTAssertEqual(remaining, 0)
    }

    // MARK: - Cancellation that is not CancellationError

    /// Not every cancellation surfaces as `CancellationError` — `URLSession`
    /// reports `NSURLErrorCancelled`, and transports wrap it in their own type.
    /// `withDrainScope` consults the task's own flag so those are classified as
    /// cancellation rather than filed as genuine failures.
    func testCancellationReportedAsACustomErrorIsStillClassifiedAsCancelled() async throws {
        struct TransportCancelled: Error { }

        let task = Task { () -> DrainRun<Int> in
            await withDrainScope(policy: .patient) { scope in
                try await scope.register("close-connection", criticality: .required) { }
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    // Re-thrown as a library-specific type, the way a transport
                    // layer does. Deliberately NOT a CancellationError.
                    throw TransportCancelled()
                }
                return 1
            }
        }

        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        let run = await task.value

        XCTAssertEqual(
            run.outcome.label, "cancelled",
            "a non-CancellationError thrown from a cancelled task is cancellation, not failure"
        )
        XCTAssertEqual(run.transcript.outcome(for: "close-connection"), .completed)
    }

    // MARK: - Concurrent registration

    func testConcurrentRegistrationLosesNothing() async throws {
        let scope = DrainScope(
            policy: DrainPolicy(totalBudget: .seconds(5), requiredStepGrace: .zero, capacity: 256)
        )

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<64 {
                group.addTask {
                    try? await scope.register("step-\(index)") { }
                }
            }
        }

        let registered = await scope.registeredCount
        XCTAssertEqual(registered, 64)
        let transcript = await scope.drain()
        XCTAssertEqual(transcript.records.count, 64)
        XCTAssertEqual(Set(transcript.records.map(\.name)).count, 64, "no duplicate or lost names")
    }
}
