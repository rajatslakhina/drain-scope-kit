//
//  DrainModel.swift
//  DrainScope
//
//  The value types that describe *what a teardown did*. These are the audit
//  artifact: after a scope drains, the transcript is the only evidence anyone
//  has that a rollback, a flush or a handle close actually happened.
//

import Foundation

// MARK: - Criticality

/// How much of the teardown budget a step is entitled to.
///
/// The distinction exists because "clean up everything" and "shut down promptly"
/// are in direct conflict once the budget runs out. Declaring criticality at
/// registration forces that trade-off to be decided by the author of the step,
/// who knows what it protects, rather than by whatever ordering the runtime
/// happened to produce.
public enum DrainCriticality: String, Sendable, Codable, CaseIterable, Comparable {

    /// Dropped without running once the total budget is exhausted.
    ///
    /// Correct for work whose absence is an inconvenience: analytics flushes,
    /// cache warm-downs, breadcrumb writes.
    case bestEffort

    /// Attempted even after the total budget is exhausted, under
    /// ``DrainPolicy/requiredStepGrace``.
    ///
    /// Correct for work whose absence is a correctness or money bug: a
    /// transaction rollback, releasing a lease someone else is blocked on,
    /// closing a file handle that would otherwise be left in a torn state.
    case required

    /// `bestEffort < required`. Ordering is by entitlement to the budget, not
    /// by execution order — execution order is LIFO regardless of criticality.
    public static func < (lhs: DrainCriticality, rhs: DrainCriticality) -> Bool {
        lhs == .bestEffort && rhs == .required
    }
}

// MARK: - Failure

/// A `Sendable` snapshot of an error thrown by a teardown step.
///
/// Deliberately not `any Error`: the transcript crosses concurrency domains and
/// is retained for the lifetime of the scope, and `Error` carries no `Sendable`
/// guarantee. Capturing the type name and description keeps the transcript
/// `Sendable` without an `@unchecked` escape hatch. Teardown errors are
/// diagnostic — nothing downstream can retry them — so the fidelity loss is
/// real but cheap.
public struct DrainFailure: Sendable, Equatable, Codable, CustomStringConvertible {

    /// The dynamic type name of the thrown error, e.g. `"CancellationError"`.
    public let typeName: String

    /// `String(describing:)` of the thrown error.
    public let message: String

    public init(typeName: String, message: String) {
        self.typeName = typeName
        self.message = message
    }

    public init(_ error: any Error) {
        self.typeName = String(describing: type(of: error))
        self.message = String(describing: error)
    }

    public var description: String { "\(typeName): \(message)" }
}

// MARK: - Outcome

/// What happened to one registered step.
public enum DrainOutcome: Sendable, Equatable, Codable {

    /// The step's body returned without throwing, inside its cap.
    case completed

    /// The step's body threw. Later steps still ran — a failing teardown step
    /// does not abort the drain.
    case failed(DrainFailure)

    /// The step's body was invoked, was still running when its cap elapsed, and
    /// was cancelled.
    ///
    /// Note that this records that the cap *elapsed*, not that the step stopped:
    /// see the cooperative-cancellation caveat on ``DrainScope``. It is never
    /// used for a step that was not invoked at all — that is ``notAttempted``.
    case timedOut

    /// The step was reached with a cap of zero, so its body was never invoked.
    ///
    /// Distinct from ``timedOut`` on purpose. A transcript that says "cancelled
    /// mid-flight" about a step that never started is a lie, and this library's
    /// entire product is the transcript. Distinct from
    /// ``skippedBudgetExhausted`` too: that one is policy deliberately dropping
    /// best-effort work, this one is a `required` step whose grace was zero.
    case notAttempted

    /// The total budget was already exhausted when this step was reached, and
    /// the step was ``DrainCriticality/bestEffort``, so it never ran.
    case skippedBudgetExhausted

    /// `true` only for ``completed``. Everything else left something undone.
    public var isSuccess: Bool { self == .completed }

    /// A short, stable token suitable for logs and snapshot tests.
    public var label: String {
        switch self {
        case .completed: return "completed"
        case .failed: return "failed"
        case .timedOut: return "timedOut"
        case .notAttempted: return "notAttempted"
        case .skippedBudgetExhausted: return "skipped"
        }
    }
}

// MARK: - Record

/// One row of the transcript.
public struct DrainRecord: Sendable, Equatable, Codable, Identifiable {

    /// The name the step was registered under. Unique within a scope.
    public let name: String

    public let criticality: DrainCriticality

    public let outcome: DrainOutcome

    /// Wall time the step occupied. Zero for ``DrainOutcome/skippedBudgetExhausted``.
    public let duration: Duration

    /// Zero-based position in execution order (LIFO over registration order).
    public let order: Int

    public var id: String { name }

    public init(
        name: String,
        criticality: DrainCriticality,
        outcome: DrainOutcome,
        duration: Duration,
        order: Int
    ) {
        self.name = name
        self.criticality = criticality
        self.outcome = outcome
        self.duration = duration
        self.order = order
    }
}

// MARK: - Transcript

/// The complete, ordered record of one drain.
///
/// A transcript is produced exactly once per scope and is the answer to the only
/// question that matters after the fact: *did the rollback run?*
public struct DrainTranscript: Sendable, Equatable, Codable {

    /// Rows in execution order (LIFO over registration order).
    public let records: [DrainRecord]

    /// Total time the drain occupied, measured on the injected clock.
    public let elapsed: Duration

    /// The total budget the drain was granted.
    public let budget: Duration

    /// `true` if the budget ran out during the drain — either before some step
    /// was reached, or consumed exactly by the time the last one finished.
    ///
    /// Note the second clause: it does **not** imply anything was dropped. A
    /// drain with no best-effort steps can exhaust its budget and still complete
    /// everything. Read ``skippedCount`` for what was actually lost.
    public let budgetExhausted: Bool

    public init(
        records: [DrainRecord],
        elapsed: Duration,
        budget: Duration,
        budgetExhausted: Bool
    ) {
        self.records = records
        self.elapsed = elapsed
        self.budget = budget
        self.budgetExhausted = budgetExhausted
    }

    /// An empty transcript — the honest result of draining a scope with nothing
    /// registered. Distinct from "we did not drain", which is `nil`.
    public static func empty(budget: Duration = .zero) -> DrainTranscript {
        DrainTranscript(records: [], elapsed: .zero, budget: budget, budgetExhausted: false)
    }

    public var isEmpty: Bool { records.isEmpty }

    public var completedCount: Int { records.filter { $0.outcome == .completed }.count }

    public var timedOutCount: Int { records.filter { $0.outcome == .timedOut }.count }

    public var notAttemptedCount: Int { records.filter { $0.outcome == .notAttempted }.count }

    public var skippedCount: Int { records.filter { $0.outcome == .skippedBudgetExhausted }.count }

    public var failedCount: Int {
        records.filter {
            if case .failed = $0.outcome { return true }
            return false
        }.count
    }

    /// Steps that did not complete. This is the list a reviewer actually reads.
    public var unfinished: [DrainRecord] { records.filter { $0.outcome != .completed } }

    /// `true` when every `required` step completed.
    ///
    /// The deliberate asymmetry: a `bestEffort` step that was skipped or timed
    /// out does **not** make a drain unclean. That is the entire point of
    /// declaring criticality — it decides what counts as failure.
    public var requiredWorkCompleted: Bool {
        records.allSatisfy { $0.criticality != .required || $0.outcome == .completed }
    }

    /// Elapsed against budget, clamped to `0...1`.
    ///
    /// Lives here rather than in the view so it is covered by the Linux test
    /// suite: `budget` is legitimately zero under ``DrainPolicy/hostile``, which
    /// makes this a real divide-by-zero site, and a divide-by-zero guard that
    /// only exists inside a SwiftUI view is a guard nobody can test.
    public var budgetFraction: Double {
        let budgetMilliseconds = budget.drainMilliseconds
        let elapsedMilliseconds = elapsed.drainMilliseconds
        guard budgetMilliseconds > 0 else {
            return elapsedMilliseconds > 0 ? 1 : 0
        }
        let raw = Double(elapsedMilliseconds) / Double(budgetMilliseconds)
        return min(max(raw, 0), 1)
    }

    /// One line per row, stable enough to assert against in tests.
    public func summaryLines() -> [String] {
        records.map { record in
            "\(record.order). \(record.name) [\(record.criticality.rawValue)] "
            + "→ \(record.outcome.label) (\(record.duration.drainMilliseconds)ms)"
        }
    }
}
