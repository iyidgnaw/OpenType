import Foundation

/// The lifecycle state of the local sidecar child process, as surfaced to the
/// UI. Replaces the previous free-form `String` status (which was set exactly
/// once at startup and could get stuck reading "ready" against a dead process
/// — bug P1-4): a single source of truth the display string is derived from.
enum SidecarStatus: Equatable {
    /// Spawning / waiting for the first healthy `/health` response.
    case starting
    /// Healthy and answering on its socket.
    case ready
    /// Died unexpectedly after a healthy start; an auto-restart with backoff is
    /// in progress. Transient — distinct from `.failed` so the UI can say
    /// "reconnecting" rather than "give up".
    case degraded
    /// Could not (re)start, or the bounded auto-restart attempts were exhausted.
    /// Terminal until the user triggers a manual restart.
    case failed
}

/// A sidecar process-lifecycle transition the supervisor maps to a
/// `SidecarStatus`. Kept separate from `SidecarStatus` so the pure mapping in
/// `SidecarSupervisor.status(for:)` is directly testable without any process
/// or UI state.
enum SidecarLifecycleEvent {
    /// The child exited without an intentional `stop()` / app-quit.
    case unexpectedTermination
    /// A restart attempt brought the sidecar back to a healthy state.
    case restartSucceeded
    /// The bounded restart budget was exhausted; no further auto-retries.
    case gaveUp
}

/// What the supervisor decides to do after the Nth consecutive sidecar failure.
enum SidecarRestartDecision: Equatable {
    /// Retry after this many seconds (bounded backoff).
    case restart(afterSeconds: TimeInterval)
    /// Stop retrying; a manual restart is required.
    case giveUp
}

/// Pure, stateless decision logic for sidecar crash recovery. Extracted from
/// `SidecarClient`/`AppModel` (which spawn real processes and drive AppKit UI,
/// so aren't cleanly unit-instantiable) so the backoff/give-up policy and the
/// termination→status mapping can be unit-tested in isolation. The actual
/// process/UI wiring that calls into these seams lives in `SidecarClient`
/// (termination notification) and `AppModel` (restart loop + status publish).
enum SidecarSupervisor {
    /// Upper bound on consecutive auto-restart attempts before giving up and
    /// requiring a manual restart. Small and finite so a sidecar that crashes
    /// on every launch can't spin forever.
    static let maxRestartAttempts = 5

    /// Decides whether — and after how long — to auto-restart the sidecar,
    /// given how many consecutive failures have occurred so far (1 == the
    /// first failure). Uses a capped exponential backoff: the first retry is
    /// quick, subsequent ones grow but never exceed 60s, and once the count
    /// passes `maxRestartAttempts` the decision becomes `.giveUp`.
    static func restartDecision(consecutiveFailureCount: Int) -> SidecarRestartDecision {
        guard consecutiveFailureCount <= maxRestartAttempts else {
            return .giveUp
        }
        // Attempt 1 → 0.5s (quick), then 1s, 2s, 4s, 8s … capped at 60s.
        let base = 0.5
        let exponent = Double(max(consecutiveFailureCount, 1) - 1)
        let delay = min(60.0, base * pow(2.0, exponent))
        return .restart(afterSeconds: delay)
    }

    /// Maps a lifecycle event to the visible status the UI should show.
    /// `.unexpectedTermination` and `.gaveUp` are deliberately distinct
    /// non-ready states (`.degraded` vs `.failed`) so the UI can tell an
    /// in-progress reconnect apart from an exhausted one that needs a manual
    /// "restart service" tap.
    static func status(for event: SidecarLifecycleEvent) -> SidecarStatus {
        switch event {
        case .unexpectedTermination:
            return .degraded
        case .restartSucceeded:
            return .ready
        case .gaveUp:
            return .failed
        }
    }
}
