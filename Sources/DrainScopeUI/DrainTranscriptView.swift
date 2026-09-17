//
//  DrainTranscriptView.swift
//  DrainScopeUI
//

#if canImport(SwiftUI)

import SwiftUI
import DrainScope

/// Renders a ``DrainTranscript`` as the audit artifact it is: what ran, what
/// was dropped, what overran, and whether the drain was clean by the only
/// definition that matters — every `required` step completed.
///
/// Deliberately takes a plain value rather than observing a model. A transcript
/// is immutable once produced, so there is nothing to observe, and keeping the
/// view a pure function of a value is what makes it previewable and snapshot-testable.
public struct DrainTranscriptView: View {

    private let transcript: DrainTranscript
    private let title: String

    public init(transcript: DrainTranscript, title: String = "Teardown transcript") {
        self.transcript = transcript
        self.title = title
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if transcript.isEmpty {
                emptyState
            } else {
                budgetBar
                rows
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Spacer(minLength: 8)
            verdictBadge
        }
    }

    private var verdictBadge: some View {
        let clean = transcript.requiredWorkCompleted
        return Text(clean ? "REQUIRED WORK DONE" : "INCOMPLETE")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                (clean ? Color.green : Color.red).opacity(0.18),
                in: Capsule()
            )
            .foregroundStyle(clean ? Color.green : Color.red)
            .accessibilityLabel(
                clean
                ? "All required teardown steps completed"
                : "Teardown incomplete: \(transcript.unfinished.count) step(s) did not complete"
            )
    }

    // MARK: Empty state

    /// A drain with nothing registered is a real, correct outcome — not an
    /// error and not a spinner. Saying so beats rendering a blank card.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No teardown steps were registered.")
                .font(.subheadline)
            Text("The scope drained cleanly because there was nothing to do.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    // MARK: Budget

    private var budgetBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(transcript.elapsed.drainMilliseconds) ms elapsed")
                    .font(.caption.monospacedDigit())
                Spacer(minLength: 8)
                Text("budget \(transcript.budget.drainMilliseconds) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(transcript.budgetExhausted ? Color.orange : Color.accentColor)
                        .frame(width: max(0, proxy.size.width * transcript.budgetFraction))
                }
            }
            .frame(height: 6)
            if transcript.budgetExhausted {
                // The flag means the budget ran out, which does not by itself
                // mean anything was lost: a drain with no best-effort steps can
                // exhaust its budget and still complete everything. Saying
                // "steps were dropped" above a list of green checkmarks is the
                // kind of confident falsehood this library exists to prevent.
                Text(
                    transcript.skippedCount > 0
                    ? "Budget exhausted — \(transcript.skippedCount) best-effort step(s) dropped."
                    : "Budget fully consumed. Nothing was dropped."
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Rows

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(transcript.records) { record in
                DrainRecordRow(record: record)
                if record.id != transcript.records.last?.id {
                    Divider()
                }
            }
        }
    }
}

// MARK: - Row

/// One transcript row.
public struct DrainRecordRow: View {

    private let record: DrainRecord

    public init(record: DrainRecord) {
        self.record = record
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
                .font(.callout)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.subheadline.weight(.medium))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text("\(record.duration.drainMilliseconds) ms")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.name), \(record.criticality.rawValue), \(record.outcome.label)")
    }

    private var subtitle: String {
        switch record.outcome {
        case .completed:
            return "\(record.criticality.rawValue) · completed"
        case .failed(let failure):
            return "\(record.criticality.rawValue) · threw \(failure.typeName)"
        case .timedOut:
            return "\(record.criticality.rawValue) · cap elapsed, step cancelled"
        case .notAttempted:
            return "\(record.criticality.rawValue) · no time granted, never started"
        case .skippedBudgetExhausted:
            return "\(record.criticality.rawValue) · skipped, budget gone"
        }
    }

    private var symbolName: String {
        switch record.outcome {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .timedOut: return "clock.fill"
        case .notAttempted: return "slash.circle.fill"
        case .skippedBudgetExhausted: return "minus.circle.fill"
        }
    }

    private var tint: Color {
        switch record.outcome {
        case .completed: return .green
        case .failed: return .red
        case .timedOut: return .orange
        case .notAttempted: return .red
        case .skippedBudgetExhausted: return .secondary
        }
    }
}

#endif
