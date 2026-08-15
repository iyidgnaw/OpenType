import Foundation

/// Which of the two assistant modes a conversation belongs to.
///
/// Raw values are the sidecar's own wire strings (`sidecar/src/memory/
/// conversations.ts` stores them in a `kind` column and `GET /conversations`
/// echoes them back), so this decodes straight off the payload rather than
/// through a translation table that could drift from it.
enum SessionKind: String, CaseIterable, Identifiable, Equatable {
    case ask
    case agent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return OpenTypeL10n.text("问答", english: "Q&A")
        case .agent: return OpenTypeL10n.text("Agent", english: "Agent")
        }
    }
}

extension ConversationSummary {
    /// `nil` for a `kind` this build does not know.
    ///
    /// Deliberately optional rather than defaulted: a conversation written by a
    /// newer sidecar should stay visible and unfiltered rather than silently
    /// impersonating an ask thread, which would send its next turn to the wrong
    /// endpoint.
    var sessionKind: SessionKind? { SessionKind(rawValue: kind) }
}

/// The chips above the session list.
enum SessionFilter: String, CaseIterable, Identifiable, Equatable {
    case all
    case agent
    case ask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return OpenTypeL10n.text("全部", english: "All")
        case .agent: return OpenTypeL10n.text("Agent", english: "Agent")
        case .ask: return OpenTypeL10n.text("问答", english: "Q&A")
        }
    }

    func matches(_ conversation: ConversationSummary) -> Bool {
        switch self {
        case .all: return true
        case .agent: return conversation.sessionKind == .agent
        case .ask: return conversation.sessionKind == .ask
        }
    }
}

/// Pure list assembly for the redesigned 会话 screen.
///
/// The Q&A and Agent tabs used to be two lists because they came from two
/// fetches. They were never two *places* — a user who asks a question and then
/// gives a task should not have to remember which tab it landed in — so the
/// screen shows one list and the row's type dot carries the distinction.
enum SessionList {
    /// Interleaves the two fetches into one most-recent-first list.
    ///
    /// Sorts rather than assuming its inputs are ordered: `AppModel` keeps the
    /// previous list on a failed refresh, so what arrives here is not
    /// guaranteed to be freshly sorted.
    ///
    /// Ties break on `id` descending. Ids are globally unique (one
    /// `conversations` table with a `kind` column), so this is a total order —
    /// without it, two conversations updated in the same second would swap
    /// places between renders for no visible reason.
    static func merged(
        ask: [ConversationSummary],
        agent: [ConversationSummary]
    ) -> [ConversationSummary] {
        (ask + agent).sorted { left, right in
            left.updatedAt == right.updatedAt
                ? left.id > right.id
                : left.updatedAt > right.updatedAt
        }
    }

    /// Filters for rendering only. The caller keeps the unfiltered list, so
    /// switching chips never costs a refetch and never loses rows.
    static func filtered(
        _ conversations: [ConversationSummary],
        by filter: SessionFilter
    ) -> [ConversationSummary] {
        conversations.filter(filter.matches)
    }
}

/// A conversation the user is currently working in, and the kind that decides
/// where its next turn goes.
///
/// The kind travels with the id on purpose. Looking it up in the list at
/// dispatch time would reintroduce two sources of truth for "which
/// conversation is this", which is exactly the split that lets a thread and an
/// endpoint disagree — see `VoiceFollowUp.continuation`.
struct FocusedConversation: Equatable {
    var id: Int
    var kind: SessionKind
}

/// Where the next spoken turn goes: which conversation it continues, and which
/// endpoint serves it.
struct SessionContinuation: Equatable {
    /// `nil` starts a fresh conversation.
    var conversationId: Int?
    var mode: InputMode
}

extension VoiceFollowUp {
    /// Resolves the thread **and** the endpoint from a single winner.
    ///
    /// This exists because resolving them independently is wrong in a way that
    /// is easy to miss. Before the merge, an ask dispatch read
    /// `focusedAskConversationId` and literally could not see an agent thread.
    /// With one focused conversation, two mechanisms answer two different
    /// questions from two different places: the visible card says *which
    /// thread*, the main window says *which endpoint*. Let them answer
    /// separately and an ask thread can be dispatched to `/agent/run` — the
    /// bleed the old split prevented by accident.
    ///
    /// So one winner supplies both. The surface still wins over the tab
    /// (commit `eaa03f3`: a card on screen is the more recent statement of
    /// what the user is working on), and `conversationId` and `mode` can never
    /// describe different conversations because they come from the same one.
    ///
    /// The rule for `spoken`: **`transcribe` is never captured by a thread**,
    /// because putting words in a text field is not a kind of conversation and
    /// redirecting it would paste a chat turn into whatever has focus. `ask`
    /// and `agent` are both "talk to the assistant", so an open thread decides
    /// which of the two — the thread is on screen and specific, the mode
    /// selector is ambient and may have been set hours ago.
    static func continuation(
        surface: FocusedConversation?,
        focused: FocusedConversation?,
        spoken: InputMode
    ) -> SessionContinuation {
        guard spoken != .transcribe else {
            return SessionContinuation(conversationId: nil, mode: .transcribe)
        }
        guard let winner = surface ?? focused else {
            return SessionContinuation(conversationId: nil, mode: spoken)
        }
        return SessionContinuation(
            conversationId: winner.id,
            mode: winner.kind == .agent ? .agent : .ask
        )
    }
}

/// The second-level Settings pages the redesign pushes into the detail column.
///
/// The rows that lead here used to be inline forms in a single scrolling
/// Settings tab, which is why that tab had nine sections: everything was on one
/// page because there was nowhere else to put it. A row that shows the provider
/// and model currently in force, and pushes to configure them, answers the
/// common question ("what is it using?") without opening anything.
enum SettingsRoute: String, Identifiable, Equatable {
    case speechRecognition
    case languageModel
    case agentTools
    case auditLog
    case clearLocalData

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speechRecognition: return OpenTypeL10n.text("语音识别", english: "Speech recognition")
        case .languageModel: return OpenTypeL10n.text("AI 模型", english: "AI model")
        case .agentTools: return OpenTypeL10n.text("Agent 工具", english: "Agent tools")
        case .auditLog: return OpenTypeL10n.text("审计记录", english: "Audit log")
        case .clearLocalData: return OpenTypeL10n.text("清除本地数据", english: "Clear local data")
        }
    }
}
