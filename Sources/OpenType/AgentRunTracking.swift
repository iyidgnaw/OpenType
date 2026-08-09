import Foundation

/// One dispatched Agent-mode (`/agent/run`) task, tracked from the moment
/// it's handed off to the sidecar through to completion (or failure) —
/// independent of `AppModel`'s foreground recording `state`, since the
/// whole point of this type is that a run keeps going in the background
/// while the user is free to start something else. Replaces the previous
/// `lastAgentRunSteps: [AgentStepSummary]` (singular, overwritten every run)
/// with a real per-run record so a bounded history of recent runs
/// (`AgentRunHistory`) can be shown, not just whatever ran most recently.
struct AgentRunRecord: Identifiable, Equatable {
    enum Status: Equatable {
        case running
        case completed(String)
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    let id: UUID
    let task: String
    let applicationName: String
    let contextPreview: String?
    let dispatchedAt: Date
    var completedAt: Date?
    var steps: [AgentStepSummary]
    var status: Status
    /// The sidecar-persisted conversation this run belongs to, once known.
    /// `/agent/run` is a single blocking call (`SidecarClient.request`
    /// doesn't return until the whole loop finishes), so this is `nil` while
    /// `status == .running` and gets filled in from the response's
    /// `conversationId` the moment the run completes or fails to complete
    /// with one. Lets `focusAgentRun(_:)` (a tapped completion notification)
    /// open the matching thread in the Agent tab (`AppModel.openAgentConversation(_:)`)
    /// instead of just switching tabs.
    var conversationId: Int?

    init(
        id: UUID = UUID(),
        task: String,
        applicationName: String,
        contextPreview: String?,
        dispatchedAt: Date = Date(),
        completedAt: Date? = nil,
        steps: [AgentStepSummary] = [],
        status: Status = .running,
        conversationId: Int? = nil
    ) {
        self.id = id
        self.task = task
        self.applicationName = applicationName
        self.contextPreview = contextPreview
        self.dispatchedAt = dispatchedAt
        self.completedAt = completedAt
        self.steps = steps
        self.status = status
        self.conversationId = conversationId
    }
}

/// Pure, side-effect-free operations over the bounded Agent run history list
/// `AppModel.agentRuns` maintains. Kept free of `AppModel`/`SidecarClient`
/// dependencies specifically so the eviction/update/counting logic — the
/// part most likely to hide an off-by-one or an accidental full-array
/// replace-when-it-should-mutate bug — is unit testable without having to
/// construct a whole `AppModel` (which spawns a hotkey listener and the
/// sidecar child process from `init()`, and so isn't practical to
/// instantiate in tests).
enum AgentRunHistory {
    /// In-memory history depth. Per product direction this is a v1
    /// convenience list, not a persistent store — the sidecar's own audit
    /// trail (`ImmutableAuditStore`) already durably records every dispatch
    /// and completion/failure, so capping this in-memory list is safe: nothing
    /// user-visible is lost, only how far back the Task List panel scrolls.
    static let capacity = 50

    /// Inserts a newly-dispatched run at the front (most recent first) and
    /// evicts the oldest entries beyond `capacity`.
    static func inserting(
        _ record: AgentRunRecord,
        into records: [AgentRunRecord]
    ) -> [AgentRunRecord] {
        var updated = [record] + records
        if updated.count > capacity {
            updated.removeLast(updated.count - capacity)
        }
        return updated
    }

    /// Mutates the record matching `id` in place (e.g. marking it completed
    /// with its final steps/result) without disturbing the order of the rest
    /// of the list. A no-op if `id` isn't present (e.g. it aged out of the
    /// capped history before its own completion arrived).
    static func updating(
        id: UUID,
        in records: [AgentRunRecord],
        _ transform: (inout AgentRunRecord) -> Void
    ) -> [AgentRunRecord] {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            return records
        }
        var updated = records
        transform(&updated[index])
        return updated
    }

    /// Count of runs still in flight — backs the lightweight menubar badge.
    static func runningCount(in records: [AgentRunRecord]) -> Int {
        records.reduce(0) { $0 + ($1.status.isRunning ? 1 : 0) }
    }
}
