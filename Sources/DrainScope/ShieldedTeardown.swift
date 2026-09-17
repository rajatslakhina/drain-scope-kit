//
//  ShieldedTeardown.swift
//  DrainScope
//

import Foundation

/// How the guarded operation itself ended.
///
/// Separate from ``DrainTranscript`` on purpose: "did the work succeed" and
/// "did the cleanup run" are independent questions, and conflating them is how
/// a cancelled checkout gets reported as a clean one.
public enum OperationOutcome<T: Sendable>: Sendable {

    case completed(T)

    /// The operation was cancelled. The drain still ran.
    case cancelled

    case failed(DrainFailure)

    public var value: T? {
        if case .completed(let value) = self { return value }
        return nil
    }

    public var label: String {
        switch self {
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }
}

/// The result of ``withDrainScope(policy:clock:operation:)``.
public struct DrainRun<T: Sendable>: Sendable {

    public let outcome: OperationOutcome<T>
    public let transcript: DrainTranscript

    public init(outcome: OperationOutcome<T>, transcript: DrainTranscript) {
        self.outcome = outcome
        self.transcript = transcript
    }

    /// The only definition of "clean" worth shipping: the operation finished
    /// *and* every `required` teardown step completed.
    public var isClean: Bool {
        if case .completed = outcome {
            return transcript.requiredWorkCompleted
        }
        return false
    }
}

/// Runs `operation` with a ``DrainScope``, then drains it under `policy` —
/// whether the operation returned, threw, or was cancelled.
///
/// This is the whole thesis in one function. The drain happens *after* the
/// `catch`, in a context that may already be cancelled, and it still runs to
/// completion because ``DrainScope/drain()`` shields it.
///
/// ```swift
/// let run = await withDrainScope(policy: .default) { scope in
///     let tx = try await database.begin()
///     try await scope.register("rollback", criticality: .required) {
///         try await tx.rollbackIfOpen()
///     }
///     try await payments.authorize()   // cancelled here
///     try await tx.commit()
/// }
///
/// if !run.transcript.requiredWorkCompleted {
///     logger.error("teardown incomplete: \(run.transcript.unfinished)")
/// }
/// ```
///
/// - Note: This never rethrows. A teardown that is skipped because the error
///   path unwound past it is the bug this library exists to remove, so the
///   error is captured into ``OperationOutcome`` and the drain is unconditional.
public func withDrainScope<T: Sendable>(
    policy: DrainPolicy = .default,
    clock: any DrainClock = ContinuousDrainClock(),
    operation: @Sendable (DrainScope) async throws -> T
) async -> DrainRun<T> {

    let scope = DrainScope(policy: policy, clock: clock)
    let outcome: OperationOutcome<T>

    do {
        outcome = .completed(try await operation(scope))
    } catch is CancellationError {
        outcome = .cancelled
    } catch {
        // Not every cancellation surfaces as `CancellationError`: URLSession
        // reports `NSURLErrorCancelled`, and hand-rolled code throws its own
        // types. Consulting the task's own flag classifies those correctly
        // instead of filing them as genuine failures.
        outcome = Task.isCancelled ? .cancelled : .failed(DrainFailure(error))
    }

    let transcript = await scope.drain()
    return DrainRun(outcome: outcome, transcript: transcript)
}
