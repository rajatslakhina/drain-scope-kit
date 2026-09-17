//
//  TestSupport.swift
//  DrainScopeTests
//

import Foundation
@testable import DrainScope

/// Counts side effects across concurrency domains.
actor Recorder {
    private(set) var events: [String] = []

    func record(_ event: String) { events.append(event) }

    func count(of event: String) -> Int { events.filter { $0 == event }.count }

    var isEmpty: Bool { events.isEmpty }
}

/// A clock whose `uptime` advances only when a test says so.
///
/// This exists to prove the budget is accounted against the **injected** clock
/// rather than wall time. A step body calls ``advance(by:)`` to simulate having
/// taken time; no real time passes, so the budget tests built on it are
/// deterministic rather than a race against the machine's speed.
///
/// `sleep(for:)` deliberately ignores its argument and waits far longer than any
/// test step needs: the executor races the body against this sleep, the body
/// always wins, and the loser is cancelled immediately — so the long duration
/// costs no real time and removes timing from the outcome entirely.
///
/// `@unchecked Sendable` is carried by the lock: every access to `storage` goes
/// through `lock`, and nothing else is mutable.
final class ManualClock: DrainClock, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: Duration = .zero

    var uptime: Duration {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func advance(by duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        storage += duration
    }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .seconds(30))
    }
}

extension DrainTranscript {
    /// Outcome for a named step, or `nil` if the step is absent from the
    /// transcript entirely — a distinction worth keeping in assertions.
    func outcome(for name: String) -> DrainOutcome? {
        records.first { $0.name == name }?.outcome
    }
}
