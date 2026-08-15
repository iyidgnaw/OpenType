import Foundation

/// 「交给助理去做」 — the exit for "I picked the wrong mode" (§H,
/// `docs/superpowers/specs/2026-08-15-product-batch-plan.md`, motivated by
/// `docs/reviews/2026-08-15-product-review.md` §6).
///
/// Ask and Agent differ by exactly one thing: the toolset. `/oneshot/ask`
/// runs the same `runAgentLoop` narrowed to `opentype__web_search` +
/// `opentype__web_fetch` (`filterToolSet`, 6-iteration cap); `/agent/run`
/// gets everything. That line is invisible from outside — 「帮我查一下今天的
/// 汇率」 could be either, and "does this need tools?" is an implementation
/// detail the user has no obligation to know before they open their mouth.
/// So one button: re-run **this turn** with the full toolset.
///
/// This is NOT the P1-5 merge the product owner rejected
/// (`2026-08-14-product-batch-plan.md`, kept struck through rather than
/// deleted so the decision stays legible). Escalating dispatches one turn to
/// `/agent/run`; the conversation's `SessionKind` is never touched, so the
/// *next* spoken turn in the same thread still routes to `/oneshot/ask`. The
/// sidecar already behaves this way for free — `resolveConversation`
/// (`sidecar/src/oneshot/routes.ts`) only assigns a `kind` when it *creates*
/// a conversation, so `/agent/run` handed an existing ask thread continues it
/// without relabelling it. The hazard is entirely Swift-side: once the
/// escalated run is dispatched, the surface is driven by `agentPanelState`,
/// and reading "which conversation is this" off whichever panel is live would
/// report an agent-kind copy of what is still an ask thread. That is why this
/// type carries the whole `FocusedConversation` — kind included — rather than
/// just an id, and why `VoiceFollowUp.continuation` is what call sites must
/// keep consulting afterward.
///
/// One-directional by construction, not by a flag: an agent card never offers
/// this (`offered` only recognises a finished *ask* result), so the card the
/// escalated run itself produces has no button either. "Re-run once" needs no
/// already-escalated bookkeeping because of that shape.
struct AssistantEscalation: Equatable {
    /// The user's own words, re-dispatched verbatim. Never the answer —
    /// sending the model its own output as a task fails silently, producing a
    /// plausible run against the wrong input.
    let task: String
    /// The thread this run continues, and the kind that thread keeps.
    /// `nil` starts a fresh one.
    let conversation: FocusedConversation?

    /// Where *this turn* goes. Constant: the toolset is the point.
    static let dispatchMode: InputMode = .agent

    /// The escalation the unified voice surface offers, or `nil` when the
    /// button must not be drawn at all.
    ///
    /// Only a finished ask result qualifies: a run still in flight has no
    /// result to escalate and no `conversationId` yet, and an agent result —
    /// succeeded, failed, or stopped — is the other side of the one-way door.
    /// `conversationId` is threaded through separately rather than read off
    /// the card because `ResultCard` itself carries no id; the caller passes
    /// whatever it already tracks for the live surface (`AskPanelState.
    /// conversationId`).
    static func offered(
        for surface: VoiceSurfaceState,
        conversationId: Int?
    ) -> AssistantEscalation? {
        guard case .result(let card) = surface, card.kind == .ask else { return nil }
        return AssistantEscalation(
            task: card.query,
            conversation: conversationId.map { FocusedConversation(id: $0, kind: .ask) }
        )
    }

    /// The session detail page's copy of the same decision, for one assistant
    /// turn in an open thread.
    ///
    /// Deliberately the same rule as `offered(for:conversationId:)` rather
    /// than a second one grown beside it — that is how the two surfaces end
    /// up disagreeing about whether a thread is escalatable. The extra work
    /// here is only finding which user turn produced the answer being
    /// escalated: the nearest preceding `"user"` message, not the thread's
    /// latest one, since a mid-thread answer must re-run the question that
    /// actually produced it.
    static func offered(
        forAssistantMessage message: ConversationMessageSummary,
        in detail: ConversationDetail
    ) -> AssistantEscalation? {
        guard SessionKind(rawValue: detail.kind) == .ask else { return nil }
        guard message.conversationId == detail.id else { return nil }
        guard message.role == "assistant" else { return nil }
        guard let index = detail.messages.firstIndex(of: message) else { return nil }
        guard let question = detail.messages[..<index].last(where: { $0.role == "user" }) else {
            return nil
        }
        return AssistantEscalation(
            task: question.content,
            conversation: FocusedConversation(id: detail.id, kind: .ask)
        )
    }
}
