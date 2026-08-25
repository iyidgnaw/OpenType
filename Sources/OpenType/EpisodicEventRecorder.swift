import Foundation

/// The body of `POST /memory/events` — the single write point for episodic
/// events (design §3.2 of
/// `docs/superpowers/specs/2026-08-25-unified-memory-and-recent-context-design.md`).
///
/// Before this batch, three sidecar routes (`/asr/transcribe`,
/// `/oneshot/ask`, `/agent/run`) each wrote their own episodic event from only
/// the half of the truth they could see: `/asr/transcribe` didn't know the
/// real mode or the frontmost app, and `/oneshot/ask`/`/agent/run` hardcoded a
/// placeholder `applicationName`. None of the three could see a Review-mode
/// edit or a `tidy` rewrite, because both happen to the transcript *after*
/// the sidecar has already answered. Swift is the only place all of that is
/// known at once, and only at the moment delivery actually completes — see
/// each `.completed` `recordAuditEvent(...)` call site in `AppModel.swift`,
/// which this is meant to sit right beside.
///
/// `Equatable` purely so `EpisodicEventRecorderTests` can assert on the
/// individual fields it cares about without needing a live sidecar.
struct EpisodicEventBody: Encodable, Equatable {
    let mode: String
    /// What Whisper actually heard, before the entity dictionary touched it.
    let rawTranscript: String
    /// `rawTranscript` after the entity dictionary rewrote any known alias
    /// (`sidecar/src/asr/dictionaryBias.ts`) — for `ask`/`agent`, which have
    /// no dictionary stage, this is always identical to `rawTranscript`.
    let correctedTranscript: String
    /// Out of scope for this pass (see `EpisodicEventRecorder.body`'s doc
    /// comment) — always `nil` here. `sidecar/src/memory/routes.ts` already
    /// treats a missing/`null` value as a legitimate "this session has none",
    /// not a safety net papering over something that should exist, so this is
    /// not a gap the way an always-`nil` `correctedTranscript` would be.
    let effectiveInput: String?
    let selectedContext: String?
    /// What actually reached the user: for `transcribe`, the text after
    /// `tidy` or a Review edit (never the raw ASR output); for `ask`/`agent`,
    /// the answer/result. This is the whole reason the write moved from the
    /// sidecar to Swift — the sidecar never sees either kind of post-answer
    /// rewrite.
    let result: String?
    let applicationName: String
    let origin: String
    /// `ask`/`agent` only; `transcribe` has no conversation.
    let conversationId: Int?
}

/// Builds `EpisodicEventBody` values and decides when one should be sent.
/// Pure and screen-free like `LearningLoop.swift`'s other policy types —
/// `AppModel.init` has side effects and isn't instantiable in a plain XCTest
/// target, so any decision that only lived inside it would be a decision
/// nobody could check.
enum EpisodicEventRecorder {

    /// Turns one completed delivery into the body `POST /memory/events`
    /// expects. A pure passthrough of whatever three text-shaped strings the
    /// caller hands it — `rawTranscript`, `correctedTranscript`, and
    /// `deliveredText` are never derived from one another in here, because
    /// only `AppModel` (which pipeline stage produced which string) knows
    /// that.
    ///
    /// Three strings matter and are kept distinct on purpose:
    ///  - `rawTranscript` is what Whisper heard,
    ///  - `correctedTranscript` is that text after the entity dictionary
    ///    rewrote any known alias (`ask`/`agent` never go through the
    ///    dictionary, so callers pass the same string for both),
    ///  - `result` (from `deliveredText` below) is what was actually
    ///    delivered — after `tidy`'s local cleanup or a Review edit for
    ///    `transcribe`, or the model's answer for `ask`/`agent`.
    ///
    /// Consolidation (`sidecar/src/memory/consolidator.ts`) reads the first
    /// two as a pair to mine mishearings; collapsing either into the other
    /// would make that mining impossible, and the third is the reason this
    /// write moved to Swift in the first place — the sidecar can never see a
    /// post-answer rewrite.
    ///
    /// - Parameters:
    ///   - mode: Decides `origin` below. `transcribe` records `"owner"` —
    ///     end to end, it's the user's own words, no model involved. `ask`
    ///     and `agent` record `"agent"`: `result` is machine-produced and may
    ///     quote a fetched web page, and recording that as the owner's own
    ///     words is exactly the provenance confusion `EventOrigin` exists to
    ///     prevent — it gates whether a consolidation-derived fact can ever
    ///     pass the `origin === "owner"` trust check downstream, so this is
    ///     not a field to fill in casually.
    ///   - applicationName: The frontmost app at capture time. An empty
    ///     string (Accessibility resolved a frontmost app but it reported no
    ///     name — a normal `CapturedContext` shape, not a malformed request)
    ///     falls back to `"Unknown app"`, the literal already used in three
    ///     other places in this codebase (`ContextBridge.swift`,
    ///     `AgentMemoryStore.swift`, and this file's third use two lines
    ///     down). **This deliberately does not match**
    ///     `sidecar/src/memory/routes.ts`'s own `body.applicationName ??
    ///     "Unknown"` (no "app") — that fallback answers a different
    ///     question ("the POST body omitted the field entirely"), which
    ///     should be unreachable once Swift always sends a real value here.
    ///     Keep the two spellings apart as evidence they are not the same
    ///     guard; do not "clean up" them into one string later.
    static func body(
        mode: InputMode,
        rawTranscript: String,
        correctedTranscript: String,
        deliveredText: String?,
        selectedContext: String?,
        applicationName: String,
        conversationId: Int?
    ) -> EpisodicEventBody {
        let origin: String
        switch mode {
        case .transcribe:
            origin = "owner"
        case .ask, .agent:
            origin = "agent"
        }

        return EpisodicEventBody(
            mode: mode.rawValue,
            rawTranscript: rawTranscript,
            correctedTranscript: correctedTranscript,
            effectiveInput: nil,
            selectedContext: selectedContext,
            result: deliveredText,
            applicationName: applicationName.isEmpty ? "Unknown app" : applicationName,
            origin: origin,
            conversationId: conversationId
        )
    }

    /// Whether a delivery at this audit status should also write an episodic
    /// event. All three gates must be open, and each is required (no
    /// defaults) so the one production caller
    /// (`AppModel.recordEpisodicEvent(for:_:)`) cannot compile without
    /// answering all three:
    ///
    ///  - `status == .completed` — a cancelled or failed run must record
    ///    nothing: teaching the memory layer from work the user abandoned
    ///    fills it with results nobody accepted.
    ///  - `keepHistory` — the user's own opt-out
    ///    (`AppConfiguration.keepHistory`, Settings' 「保留本地输入历史」
    ///    row). Before the 2026-08-25 fix, every pre-migration call site
    ///    gated its `history.add(...)` on this flag, but the migration to
    ///    this type dropped the check entirely, so a user who turned history
    ///    off kept being recorded regardless — and, since this same design
    ///    batch made these records injectable into every Ask/Agent prompt,
    ///    an explicit "don't keep my dictation" preference was being
    ///    overridden at exactly the moment the product started sending
    ///    dictation to a model.
    ///  - `!isPractice` — the guided first-run onboarding exercise
    ///    (`AppModel.togglePracticeDictation()`, `mode: .ask, practice:
    ///    true`) is by definition not real intent (two throwaway sentences
    ///    read aloud during onboarding). Recording it made it eligible for
    ///    the same recent-context injection and `opentype__read_history`
    ///    tool as a real dictation, landing in the exact minutes the user is
    ///    forming an impression of whether the product understands them.
    ///
    /// Every one of the four call sites (transcribe Direct/Tidy, the Review
    /// commit, `ask`, `agent`) already has all three values in hand at the
    /// point it decides what to write, so this gives the rule a single,
    /// unit-testable home instead of leaving it as an unenforced convention
    /// repeated at every call site.
    static func shouldRecord(for status: AuditEventStatus, keepHistory: Bool, isPractice: Bool) -> Bool {
        status == .completed && keepHistory && !isPractice
    }
}
