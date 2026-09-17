//
//  DrainModelTests.swift
//  DrainScopeTests
//

import XCTest
@testable import DrainScope

final class DrainModelTests: XCTestCase {

    // MARK: - Arithmetic that would otherwise trap

    /// `Duration` is a 128-bit quantity and `Int` is 32-bit on watchOS, so
    /// narrowing it is a real overflow site. These inputs trap a naive
    /// `Int(duration.components.seconds * 1000)` implementation.
    func testDrainMillisecondsSaturatesInsteadOfTrapping() {
        let enormous = Duration(secondsComponent: Int64.max, attosecondsComponent: 0)
        XCTAssertEqual(enormous.drainMilliseconds, Int.max)

        let enormouslyNegative = Duration(secondsComponent: Int64.min, attosecondsComponent: 0)
        XCTAssertEqual(enormouslyNegative.drainMilliseconds, Int.min)
    }

    /// The nastier case, and the one a bounds check placed *after* the read
    /// misses entirely: `Duration` is 128-bit internally, so a value whose
    /// seconds do not fit in `Int64` is representable — and `Duration.components`
    /// traps on its own when asked for it.
    ///
    /// Reachable without `@testable`: `DrainTranscript`'s public memberwise
    /// initialiser and its synthesized `Codable` both accept any `Duration`, and
    /// `summaryLines()` and `budgetFraction` then narrow it. A transcript decoded
    /// from a log sink must not be able to abort the process that reads it.
    func testDrainMillisecondsSurvivesDurationsWhoseComponentsDoNotFitInInt64() {
        let beyondComponents =
            Duration(secondsComponent: .max, attosecondsComponent: 0)
            - Duration(secondsComponent: .min, attosecondsComponent: 0)

        XCTAssertEqual(beyondComponents.drainMilliseconds, Int.max)
        XCTAssertEqual((.zero - beyondComponents).drainMilliseconds, Int.min)

        // The public surfaces that narrow it must stay total too.
        let transcript = DrainTranscript(
            records: [
                DrainRecord(
                    name: "absurd",
                    criticality: .required,
                    outcome: .completed,
                    duration: beyondComponents,
                    order: 0
                )
            ],
            elapsed: beyondComponents,
            budget: .seconds(1),
            budgetExhausted: true
        )

        XCTAssertEqual(transcript.budgetFraction, 1)
        XCTAssertEqual(transcript.summaryLines().count, 1)
    }

    /// `DrainTranscript` is advertised as surviving a round trip through a log
    /// sink, so decoding a hostile one must not abort the reader.
    func testDecodingAnAbsurdTranscriptDoesNotTrapTheReader() throws {
        let json = Data(
            #"{"records":[],"elapsed":[9223372036854775807,999999999999999999],"budget":[1,0],"budgetExhausted":true}"#.utf8
        )

        let transcript = try JSONDecoder().decode(DrainTranscript.self, from: json)

        XCTAssertEqual(transcript.budgetFraction, 1)
        XCTAssertTrue(transcript.isEmpty)
    }

    func testDrainMillisecondsIsExactForOrdinaryValues() {
        XCTAssertEqual(Duration.zero.drainMilliseconds, 0)
        XCTAssertEqual(Duration.milliseconds(1).drainMilliseconds, 1)
        XCTAssertEqual(Duration.milliseconds(1500).drainMilliseconds, 1500)
        XCTAssertEqual(Duration.seconds(2).drainMilliseconds, 2000)
        XCTAssertEqual(Duration.microseconds(999).drainMilliseconds, 0, "truncates toward zero")
    }

    func testDrainMillisecondsHandlesNegativeDurations() {
        XCTAssertEqual(Duration.milliseconds(-1500).drainMilliseconds, -1500)
        XCTAssertEqual(Duration.seconds(-2).drainMilliseconds, -2000)
    }

    // MARK: - Policy clamping

    func testPolicyClampsNonsensicalLowInput() {
        let policy = DrainPolicy(
            totalBudget: .seconds(-5),
            requiredStepGrace: .milliseconds(-1),
            capacity: -10
        )

        XCTAssertEqual(policy.totalBudget, .zero)
        XCTAssertEqual(policy.requiredStepGrace, .zero)
        XCTAssertEqual(policy.capacity, 1, "capacity must stay usable, never zero or negative")
    }

    /// The upper clamp is not defensive padding: `ContinuousClock.sleep` narrows
    /// `Duration`, so an unclamped absurd budget is a **fatal error inside the
    /// shielded drain task** — a teardown library crashing during teardown.
    func testPolicyClampsAbsurdlyLargeDurations() {
        let absurd = Duration(secondsComponent: Int64.max, attosecondsComponent: 0)
        let policy = DrainPolicy(
            totalBudget: absurd,
            requiredStepGrace: absurd,
            capacity: 8
        )

        XCTAssertEqual(policy.totalBudget, DrainPolicy.maximumDuration)
        XCTAssertEqual(policy.requiredStepGrace, DrainPolicy.maximumDuration)
    }

    /// A drain must survive a policy built from an absurd duration, because the
    /// crash it would otherwise cause happens inside the shield, where nothing
    /// can catch it.
    func testDrainSurvivesAnAbsurdlyLargeBudget() async throws {
        let absurd = Duration(secondsComponent: Int64.max, attosecondsComponent: 0)
        let scope = DrainScope(
            policy: DrainPolicy(totalBudget: absurd, requiredStepGrace: absurd, capacity: 4)
        )
        try await scope.register("rollback", criticality: .required) { }

        let transcript = await scope.drain()

        XCTAssertEqual(transcript.outcome(for: "rollback"), .completed)
    }

    /// Synthesized `Codable` would assign the stored properties directly and
    /// bypass every invariant the initializer promises. A decoded `capacity: 0`
    /// would make `register` reject *every* step — silently turning the scope
    /// into a no-op that drops the rollback it exists to run.
    func testDecodingCannotBypassThePolicyInvariants() throws {
        let json = Data(
            #"{"totalBudget":[-5,0],"requiredStepGrace":[-1,0],"capacity":0}"#.utf8
        )

        let policy = try JSONDecoder().decode(DrainPolicy.self, from: json)

        XCTAssertEqual(policy.totalBudget, .zero)
        XCTAssertEqual(policy.requiredStepGrace, .zero)
        XCTAssertEqual(policy.capacity, 1, "a decoded capacity of 0 would reject every step")
    }

    func testPolicyRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(DrainPolicy.default)
        let decoded = try JSONDecoder().decode(DrainPolicy.self, from: data)
        XCTAssertEqual(decoded, DrainPolicy.default)
    }

    /// Asserts the documented, load-bearing shape of the presets — not that
    /// clamping worked, which is guaranteed by construction and therefore
    /// untestable here.
    func testPresetsHaveTheDocumentedShape() {
        XCTAssertEqual(DrainPolicy.hostile.totalBudget, .zero, "hostile drops best-effort on sight")
        XCTAssertGreaterThan(
            DrainPolicy.hostile.requiredStepGrace, .zero,
            "hostile must still grant required work some time, or it guarantees nothing"
        )
        XCTAssertEqual(DrainPolicy.default.totalBudget, .seconds(2))
        XCTAssertEqual(DrainPolicy.default.requiredStepGrace, .milliseconds(250))
        XCTAssertEqual(DrainPolicy.patient.totalBudget, .seconds(30))
        XCTAssertGreaterThan(
            DrainPolicy.patient.totalBudget, DrainPolicy.default.totalBudget,
            "patient must be more generous than default, or the name lies"
        )
    }

    // MARK: - Criticality ordering

    func testCriticalityOrdersByBudgetEntitlement() {
        XCTAssertLessThan(DrainCriticality.bestEffort, DrainCriticality.required)
        XCTAssertEqual(max(DrainCriticality.bestEffort, .required), .required)
        XCTAssertFalse(DrainCriticality.required < DrainCriticality.bestEffort)
        XCTAssertFalse(DrainCriticality.bestEffort < DrainCriticality.bestEffort, "strict ordering")
    }

    // MARK: - Transcript

    private func record(
        _ name: String,
        _ criticality: DrainCriticality,
        _ outcome: DrainOutcome,
        order: Int = 0
    ) -> DrainRecord {
        DrainRecord(
            name: name,
            criticality: criticality,
            outcome: outcome,
            duration: .milliseconds(5),
            order: order
        )
    }

    func testTranscriptCountsPartitionTheRecords() {
        let transcript = DrainTranscript(
            records: [
                record("a", .required, .completed, order: 0),
                record("b", .bestEffort, .timedOut, order: 1),
                record("c", .bestEffort, .skippedBudgetExhausted, order: 2),
                record("d", .required, .failed(DrainFailure(typeName: "Boom", message: "boom")), order: 3)
            ],
            elapsed: .milliseconds(20),
            budget: .seconds(1),
            budgetExhausted: true
        )

        XCTAssertEqual(transcript.completedCount, 1)
        XCTAssertEqual(transcript.timedOutCount, 1)
        XCTAssertEqual(transcript.skippedCount, 1)
        XCTAssertEqual(transcript.failedCount, 1)
        XCTAssertEqual(
            transcript.completedCount + transcript.timedOutCount
            + transcript.skippedCount + transcript.failedCount,
            transcript.records.count,
            "the four counts must partition the records with no overlap and no gap"
        )
        XCTAssertEqual(transcript.unfinished.count, 3)
        XCTAssertFalse(transcript.requiredWorkCompleted)
    }

    func testEmptyTranscriptIsCleanButDistinctFromNotHavingDrained() {
        let transcript = DrainTranscript.empty(budget: .seconds(2))

        XCTAssertTrue(transcript.isEmpty)
        XCTAssertTrue(transcript.requiredWorkCompleted)
        XCTAssertEqual(transcript.budget, .seconds(2))
        XCTAssertEqual(transcript.elapsed, .zero)
        XCTAssertFalse(transcript.budgetExhausted)
    }

    func testSummaryLinesAreStableAndOrdered() {
        let transcript = DrainTranscript(
            records: [
                record("lock", .required, .completed, order: 0),
                record("metrics", .bestEffort, .skippedBudgetExhausted, order: 1)
            ],
            elapsed: .milliseconds(10),
            budget: .seconds(1),
            budgetExhausted: true
        )

        XCTAssertEqual(
            transcript.summaryLines(),
            [
                "0. lock [required] → completed (5ms)",
                "1. metrics [bestEffort] → skipped (5ms)"
            ]
        )
    }

    // MARK: - Budget fraction

    /// `budget` is legitimately zero under `.hostile`, which makes this a real
    /// divide-by-zero site rather than a theoretical one.
    func testBudgetFractionGuardsAZeroBudget() {
        let nothingHappened = DrainTranscript(
            records: [], elapsed: .zero, budget: .zero, budgetExhausted: false
        )
        XCTAssertEqual(nothingHappened.budgetFraction, 0)

        let overran = DrainTranscript(
            records: [], elapsed: .milliseconds(40), budget: .zero, budgetExhausted: true
        )
        XCTAssertEqual(overran.budgetFraction, 1, "any elapsed time against no budget is full")
    }

    func testBudgetFractionIsProportionalAndClamped() {
        func fraction(elapsed: Duration, budget: Duration) -> Double {
            DrainTranscript(records: [], elapsed: elapsed, budget: budget, budgetExhausted: false)
                .budgetFraction
        }

        XCTAssertEqual(fraction(elapsed: .milliseconds(500), budget: .seconds(1)), 0.5, accuracy: 0.001)
        XCTAssertEqual(fraction(elapsed: .zero, budget: .seconds(1)), 0)
        XCTAssertEqual(fraction(elapsed: .seconds(9), budget: .seconds(1)), 1, "clamped, never > 1")
        XCTAssertEqual(fraction(elapsed: .seconds(-9), budget: .seconds(1)), 0, "clamped, never < 0")
    }

    // MARK: - Failure capture

    func testDrainFailureCapturesTypeAndMessageWithoutRetainingTheError() {
        struct Boom: Error, CustomStringConvertible {
            var description: String { "detonated" }
        }

        let failure = DrainFailure(Boom())

        XCTAssertEqual(failure.typeName, "Boom")
        XCTAssertEqual(failure.message, "detonated")
        XCTAssertEqual(failure.description, "Boom: detonated")
    }

    func testOutcomeLabelsAreStable() {
        XCTAssertEqual(DrainOutcome.completed.label, "completed")
        XCTAssertEqual(DrainOutcome.timedOut.label, "timedOut")
        XCTAssertEqual(DrainOutcome.skippedBudgetExhausted.label, "skipped")
        XCTAssertEqual(DrainOutcome.notAttempted.label, "notAttempted")
        XCTAssertNotEqual(
            DrainOutcome.notAttempted, DrainOutcome.timedOut,
            "'never started' and 'started then cancelled' must not be the same record"
        )
        XCTAssertEqual(DrainOutcome.failed(DrainFailure(typeName: "E", message: "m")).label, "failed")
        XCTAssertTrue(DrainOutcome.completed.isSuccess)
        XCTAssertFalse(DrainOutcome.timedOut.isSuccess)
    }

    // MARK: - Codable round-trip

    /// The transcript is an audit artifact, so it has to survive being written
    /// to a crash report or a log sink and read back.
    func testTranscriptRoundTripsThroughJSON() throws {
        let original = DrainTranscript(
            records: [
                record("tx", .required, .completed, order: 0),
                record("cache", .bestEffort, .failed(DrainFailure(typeName: "IOError", message: "disk")), order: 1)
            ],
            elapsed: .milliseconds(37),
            budget: .seconds(2),
            budgetExhausted: false
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DrainTranscript.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}
