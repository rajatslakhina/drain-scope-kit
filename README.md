# DrainScope

**Your rollback is the code most likely to be skipped, and cancellation is why.**

Swift's task cancellation is cooperative *and contagious*. The moment a task is
cancelled, every cancellation-aware `await` **in that task** starts failing —
including the awaits in the cleanup path you wrote precisely for this case. So
the teardown you are most sure about is the teardown least likely to run.

```swift
let tx = try await database.begin()
do {
    try await payments.authorize()   // ← user backs out; cancelled here
    try await tx.commit()
} catch {
    try? await tx.rollback()         // ← this await throws too. Immediately.
}
```

The `catch` block runs *in the cancelled task*. `rollback()`'s first `await`
throws `CancellationError` before it does anything. `try?` swallows it. The
transaction is left open, no error is logged, and it only ever reproduces under
cancellation. Moving the rollback into a structured child — `async let`, a task
group — changes nothing: children inherit cancellation too.

`DrainScope` is an ordered, budgeted, exactly-once teardown registry that
survives the cancellation of the task that owns it — and writes down what it
actually did.

```swift
let run = await withDrainScope(policy: .default) { scope in
    let tx = try await database.begin()
    try await scope.register("rollback", criticality: .required) {
        try await tx.rollbackIfOpen()
    }
    try await payments.authorize()   // cancelled here
    try await tx.commit()
}

if !run.transcript.requiredWorkCompleted {
    logger.error("teardown incomplete: \(run.transcript.unfinished)")
}
```

---

## Why this matters

Every non-trivial iOS app already has a teardown policy. It is just implicit,
scattered across a few hundred `Task { try? await ... }` calls, different on
every screen, and written down nowhere. Nobody has decided which cleanup is
worth blocking shutdown for, so the answer is whatever the runtime happened to
do that day.

That is a leadership problem before it is a code problem, and it has three parts
a team has to actually decide:

1. **What survives cancellation?** Not everything should. A metrics flush that
   blocks app exit is a worse bug than a lost metric.
2. **How long may cleanup take?** "Until it's done" is not an answer when the
   watchdog is counting.
3. **How do you know it ran?** Under cancellation, the failure mode is *silence*.

`DrainScope` makes all three a value you can review in a PR: `DrainPolicy`
answers (2), `DrainCriticality` answers (1), and `DrainTranscript` answers (3).

---

## The guarantees

| # | Guarantee | How |
|---|-----------|-----|
| 1 | **Shielded** | Steps run in a detached task, so caller cancellation does not propagate in. `drain()` still awaits it — shielded, not fire-and-forget. |
| 2 | **LIFO** | Reverse registration order. `defer` semantics, which is what resource ownership needs. |
| 3 | **Exactly once** | Concurrent and repeated `drain()` calls share one execution and one transcript. |
| 4 | **Bounded** | Total drain ≤ `totalBudget + (requiredStepCount × requiredStepGrace)`. |
| 5 | **Isolated** | A throwing step is recorded, not propagated; later steps still run. |
| 6 | **Evidenced** | Every step produces a `DrainRecord`, `Codable` for crash reports. |
| 7 | **Non-fiction** | A step that was never invoked is recorded as `.notAttempted`, never as `.timedOut`. A transcript that claims a step started and was cancelled when it never started is worse than no transcript. |

### And the one it does not give you

**The budget bounds the time a step is *granted*, not the time an uncooperative
step can *take*.** Cancellation is cooperative all the way down; nothing
in-process can preempt a step that never suspends and never checks
`Task.isCancelled`. Such a step overruns its cap and the drain waits for it.

This is a property of the language, not a gap in the implementation, so the
library does not pretend otherwise: a hard wall-clock bound on process exit can
only come from outside the process. What you get instead is the transcript
naming *which* step overran. There is a test that spins a deliberately
unpreemptable step and asserts the overrun is reported honestly
(`testUncooperativeStepOverrunsItsCapAndTheTranscriptShowsIt`), so the README
cannot quietly drift into over-claiming.

---

## Design decisions

### Detached task, then `await` it — rather than a child task or fire-and-forget

A structured child (`async let`, a task group) inherits cancellation, which is
the bug. `Task.detached { }` and walking away escapes cancellation but also
escapes structure — nobody waits, so the scene can deactivate mid-rollback.

**On `Task { }` specifically**, since it is the reflex fix and the received
wisdom about it is wrong: an unstructured `Task { }` does **not** inherit
cancellation. It inherits priority, actor context and task-locals only. So the
rollback genuinely starts — this is not the failure above. Its problem is the
second one: nobody awaits it, the ordering between several of them is undefined,
and the scene can deactivate or the process exit mid-flight. Verified rather than
assumed; `testCleanupInTheCancelledTaskIsSilentlySkipped` pins the arms that
*do* fail, and `Task { }` is deliberately not one of them.

`drain()` does both: detaches to escape cancellation, then `await`s the detached
task's value. Awaiting a detached task from a cancelled caller does not cancel
it and does not throw, so the caller stays synchronised with cleanup it can no
longer interrupt.

**Rejected:** `withTaskCancellationHandler`. It tells you cancellation *happened*
— the handler body is synchronous and cannot await, so it cannot run async
cleanup. It is a notification mechanism, not a shield.

### Two criticality levels, not five

`bestEffort` and `required` are the only distinction that changes behaviour:
whether the step is dropped when the budget is gone. A richer priority scale
would be sortable but not actionable, and would invite arguing about tiers
instead of deciding the one thing that matters.

The asymmetry is deliberate and tested: a dropped `bestEffort` step does **not**
make a drain unclean (`requiredWorkCompleted` stays `true`), but it is still
listed in `unfinished`. Mutating `requiredWorkCompleted` to a naive
`allSatisfy { $0.outcome == .completed }` fails exactly two tests —
`testDroppedBestEffortWorkDoesNotMakeTheDrainUnclean` and
`testExhaustedBudgetSkipsBestEffortAndStillRunsRequired` — which is the measured
number, not a rhetorical "everything else passes".

### `required` gets its grace even when the budget is gone

Otherwise `required` degrades into "whatever milliseconds happened to be left",
which is not a guarantee. The cost is a bounded, written-down overrun:
`requiredStepCount × requiredStepGrace`. `DrainPolicy.default` puts that at
250 ms per required step.

**Rejected:** letting `required` run unbounded. That converts a lost rollback
into a watchdog termination — a worse bug with a worse crash log.

### `ContinuousClock`, injected

`ContinuousClock` over `SuspendingClock` because `SuspendingClock` stops while
the device is suspended and the OS watchdog does not; budgeting against a clock
that pauses hands out time the process does not have. Over wall-clock time
because an NTP step or a user changing the date would silently lengthen or
collapse the budget.

Injected because that choice is a decision worth being able to change, and
because it makes budget tests deterministic instead of timing-dependent.

### `DrainFailure`, not `any Error`

The transcript crosses concurrency domains and outlives the scope, and `Error`
carries no `Sendable` guarantee. Capturing the type name and description keeps
`DrainTranscript` genuinely `Sendable` with no `@unchecked` escape hatch.
Teardown errors are diagnostic — nothing downstream can retry them — so the
fidelity loss is real and cheap.

### The transcript may not flatter the implementation

Three places where the easy version would have been a nicer-looking lie:

- A step reached with a zero cap is `.notAttempted`, not `.timedOut`. It never
  ran, so "cancelled mid-flight" would be false.
- `budgetExhausted` is also set when the final step consumes exactly the
  remainder, not only when exhaustion is observed at a step boundary. It is an
  audit field, so it has to agree with its own documentation.
- `DrainPolicy` has a custom `init(from:)` that routes decoded values back
  through the clamping initializer. Synthesized `Codable` assigns stored
  properties directly, and a decoded `capacity: 0` would make `register` reject
  **every** step — silently turning the scope into a no-op that drops the
  rollback it exists to run.

### Durations are clamped at both ends

`DrainPolicy.maximumDuration` is 24 hours, and it is not defensive padding.
`Duration` is a 128-bit quantity but `ContinuousClock.sleep(until:)` narrows it,
so a budget near `Int64.max` seconds is a **fatal error raised inside the
shielded drain task** — a teardown library crashing the process during teardown.
One day is already far past any defensible teardown budget, so the clamp costs
nothing real and removes a crash that nothing downstream could catch.

### Nesting is allowed; re-entering the same scope is not

The re-entrancy guard is keyed on scope identity, not on "is any drain running".
A teardown step that owns a sub-component with its own `DrainScope` awaits a
*different* detached task and cannot deadlock, so it is permitted — rejecting it
would silently drop that component's required work, which is the failure this
library exists to prevent. Draining the *same* scope from inside its own step
would await the task that step is running on: that traps in debug and degrades to
a no-op in release, because `drain()` cannot throw and a silent permanent hang in
a shutdown path is the worse outcome.

### The registry is emptied when the drain completes

Every closure in it captures the thing it tears down — a transaction, a file
handle, a lease. Keeping them after the teardown that released them would hold
dead resources for the life of the scope, which for an app-lifecycle scope is the
whole session.

### Registering after the drain starts throws

A resource acquired *during* teardown that registers its own cleanup would
otherwise be appended to a list nobody will read again, and would silently never
run. `DrainScopeError.alreadyDraining` makes that a loud programmer error. Same
reasoning for the `capacity` ceiling: an append-only registry that grows per
retry is a leak whose first symptom is teardown becoming the outage.

---

## Installation

```swift
.package(url: "https://github.com/rajatslakhina/drain-scope-kit.git", from: "1.0.0")
```

```swift
.product(name: "DrainScope", package: "drain-scope-kit")     // core, no UI dependency
.product(name: "DrainScopeUI", package: "drain-scope-kit")   // SwiftUI transcript view
```

`DrainScopeUI` is a separate product so a non-UI consumer never links SwiftUI.
Its sources are behind `#if canImport(SwiftUI)`, so the package also builds on
Linux.

## Policies

| Policy | Budget | Grace | For |
|--------|--------|-------|-----|
| `.default` | 2 s | 250 ms | Normal screen and flow teardown |
| `.hostile` | 0 s | 100 ms | Termination / memory pressure — required work only |
| `.patient` | 30 s | 5 s | CLI and batch, where finishing beats exiting |

## Running it

```bash
git clone https://github.com/rajatslakhina/drain-scope-kit.git
cd drain-scope-kit
swift build -Xswiftc -warnings-as-errors
swift test
```

**Demo app:** [rajatslakhina/drain-scope-demo-app](https://github.com/rajatslakhina/drain-scope-demo-app)
— a SwiftUI checkout that gets cancelled 400 ms in, with the resulting transcript
rendered on screen under five different budget policies.

---

## Verification

### Local verification (this build)

- `swift build -Xswiftc -warnings-as-errors` from a **clean** `.build` — succeeded,
  zero warnings. (A `swift build` on an up-to-date tree compiles nothing and still
  prints "Build complete!", so the tree was deleted first. The same flag is in the
  Linux CI job, which makes the zero-warning claim machine-enforced rather than
  asserted here.)
- `swift test` — **47 tests, 0 failures**. Swift 6.0.3, Linux aarch64, language mode 6.
- The demo app's four-outcome claim was checked by **execution, not reasoning**: a
  scratch consumer package replicating `DemoScenario.steps` exactly was run against
  this executor under the demo's Tight policy, and produced
  `["completed", "failed", "skipped", "timedOut"]` — all four kinds in one transcript.

### Which tests would actually catch a broken implementation

Coverage counts are easy to inflate, so here is the honest breakdown. These four
fail against an executor gutted of budget, cap and criticality logic:

- `testStepExceedingItsCapIsCancelledAndRecordedAsTimedOut`
- `testRequiredStepGetsItsGraceButBestEffortDoesNot` — a `bestEffort` control arm
  doing identical work under the same budget must *not* complete
- `testBudgetIsAccountedAgainstTheInjectedClockNotWallTime` — a manual clock
  advanced by 500 ms with no real time passing must exhaust a 100 ms budget
- `testDroppedBestEffortWorkDoesNotMakeTheDrainUnclean` — mutating
  `requiredWorkCompleted` to a naive `allSatisfy { $0.outcome == .completed }`
  fails this one and `testExhaustedBudgetSkipsBestEffortAndStillRunsRequired`, and
  nothing else in the suite

There is exactly **one** true negative control —
`testCleanupInTheCancelledTaskIsSilentlySkipped`, which asserts that cleanup in
the `catch` block and cleanup in a structured child both *fail* under the same
conditions. Without it the shield test would prove nothing, and it is also what
keeps the README's opening example honest: it exercises exactly the pattern the
hook blames.

`testUncooperativeStepOverrunsItsCapAndTheTranscriptShowsIt` is labelled in the
source as a **characterisation test, not a guard**: the overrun it asserts is
produced by the test's own busy-wait, so it would pass against an implementation
with no budget enforcement at all. It documents the cooperative-cancellation
limit; it does not defend it.

### Continuous integration

<!-- CI-PENDING -->

### What has NOT been verified

- **The demo app has never been launched, and has never been compiled either.**
  This library was built by an unattended scheduled run with no macOS toolchain
  and no iOS SDK, and computer-use approval for Xcode and the Simulator was
  refused three times. The demo repo's CI job compiles the app for an iOS
  Simulator — but at the time this paragraph was written that job had not yet run.
  "Compiled for a Simulator" and "ran on a Simulator" are different claims and
  neither is being asserted here on the strength of the other.
- **There are no screenshots** anywhere in either repo, and none are described as
  if they existed.
- **`DrainScopeUI` has been compiled on Linux only**, where `#if canImport(SwiftUI)`
  makes it empty. No SwiftUI code in this package has ever been type-checked. The
  divide-by-zero guard the view depends on was moved into `DrainTranscript.budgetFraction`
  in the core module precisely so it could be tested; the view itself is unverified.

---

## License

MIT. See [LICENSE](LICENSE).
