import Foundation

/// Pure, view-free search over `HistoryEntry` bodies — §I of
/// `docs/superpowers/specs/2026-08-15-product-batch-plan.md`. Both the 听写
/// list (`DictationViews.swift`) and the 会话 list (`SessionsViews.swift`, via
/// `SessionSearch` below) call this one matcher rather than growing a second
/// one each.
///
/// The motivation is `SessionsViews.swift`'s own comment on the old
/// title-only filter: "the magnifying glass has to do something." What a
/// user remembers about an old dictation is a word they *said*, never an
/// auto-generated title.
///
/// Four decisions are pinned by `HistorySearchTests.swift` and repeated here
/// only as a summary — that file has the reasoning:
///
///  1. A query's terms are **ANDed**, not ORed, and order-independent — the
///     user is narrowing a recollection, not broadening a scan.
///  2. Terms may land in **different fields** — matching runs against the
///     entry's fields joined, so "微信 发布" finds a WeChat dictation whose
///     body mentions 发布.
///  3. `contextPreview` is **not searched** — it is text the user selected in
///     another app, not text they authored; matching it produces a row whose
///     visible content does not contain the query.
///  4. Matching is **case-insensitive and non-localised**
///     (`range(of:options:.caseInsensitive)`), not
///     `localizedCaseInsensitiveContains`, whose case folding depends on the
///     current locale.
enum HistorySearch {
    /// Whitespace-separated terms of a raw query, casing preserved (matching
    /// folds case; a caller that wants to highlight a hit needs the user's
    /// own string). `[]` for blank input, so "the user has not started
    /// searching" is one state rather than something every caller re-derives.
    ///
    /// CJK text has no word boundaries, so a query with no whitespace in it —
    /// spaced-ASCII or not — arrives as a single term and is matched as a
    /// substring. For 「会议纪要」 that is exactly phrase search, which is what
    /// the language needs; for spaced input it is looser than a phrase but
    /// tolerant of the filler words ASR inserts between the two words a user
    /// actually remembers.
    static func terms(_ query: String) -> [String] {
        query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }

    /// The core predicate: every term appears somewhere in `text`. `[]`
    /// matches everything, which is what makes an empty query behave as "no
    /// filter" rather than a special case every caller has to branch on.
    static func matches(text: String, terms: [String]) -> Bool {
        terms.allSatisfy { term in
            text.range(of: term, options: .caseInsensitive) != nil
        }
    }

    /// The fields of an entry a query is matched against, joined.
    /// `contextPreview` is deliberately excluded — see the type doc.
    static func searchableText(_ entry: HistoryEntry) -> String {
        // `entry.result` is optional as of Task 7 (a row can be recorded
        // without ever having delivered) — a nil contributes nothing to the
        // searchable text rather than being coerced into a literal string
        // that would itself become matchable.
        [entry.transcript, entry.result ?? "", entry.applicationName].joined(separator: "\n")
    }

    static func matches(_ entry: HistoryEntry, query: String) -> Bool {
        matches(text: searchableText(entry), terms: terms(query))
    }

    /// Filters `entries`, preserving their order. An empty or whitespace-only
    /// query returns every entry untouched.
    static func filter(_ entries: [HistoryEntry], query: String) -> [HistoryEntry] {
        let queryTerms = terms(query)
        guard !queryTerms.isEmpty else { return entries }
        return entries.filter { matches(text: searchableText($0), terms: queryTerms) }
    }
}

/// What a 会话-list search over an entry's **body** is allowed to claim.
///
/// Session bodies live in the sidecar; the main window holds at most the
/// conversations the user has actually opened (`AppModel.askConversationDetail`
/// / `agentConversationDetail`), so a body search only ever covers whatever of
/// those the caller has loaded — while the list on screen may show far more.
/// "没有匹配的会话" and "只搜索了已加载的会话，没有匹配" are different claims
/// about the world; collapsing them to a bare empty array would make the first
/// claim about data the product never consulted.
enum SessionSearchOutcome: Equatable {
    case matches([ConversationSummary])
    case noMatches
    case noMatchesInLoadedSubset(bodiesSearched: Int, total: Int)

    /// `[]` for the two empty cases, so a view can render `outcome.conversations`
    /// without switching on the case first and reserve the switch for the
    /// disclosure text alone.
    var conversations: [ConversationSummary] {
        if case .matches(let conversations) = self { return conversations }
        return []
    }
}

/// The 会话 list's search: title and preview always, plus every message of
/// whichever conversations the caller has a loaded `ConversationDetail` for.
enum SessionSearch {
    static func search(
        _ conversations: [ConversationSummary],
        query: String,
        loadedDetails: [Int: ConversationDetail]
    ) -> SessionSearchOutcome {
        let queryTerms = HistorySearch.terms(query)
        // Checked before the empty-list case below: a blank query is "not
        // searching", not "searched and found nothing", even over zero
        // conversations.
        guard !queryTerms.isEmpty else { return .matches(conversations) }
        guard !conversations.isEmpty else { return .noMatches }

        var matched: [ConversationSummary] = []
        var bodiesSearched = 0

        for conversation in conversations {
            var text = conversation.title
            // The newest message, already on the row — local text a user can
            // see, so leaving it out would be a search that ignores something
            // on screen. It does not, on its own, count as "this
            // conversation's body was searched": it is one truncated message,
            // and counting it would retire the disclosure exactly when it is
            // still true.
            if let preview = conversation.preview {
                text += "\n" + preview
            }
            if let detail = loadedDetails[conversation.id] {
                bodiesSearched += 1
                for message in detail.messages {
                    text += "\n" + message.content
                }
            }
            if HistorySearch.matches(text: text, terms: queryTerms) {
                matched.append(conversation)
            }
        }

        if !matched.isEmpty {
            return .matches(matched)
        }
        return bodiesSearched == conversations.count
            ? .noMatches
            : .noMatchesInLoadedSubset(bodiesSearched: bodiesSearched, total: conversations.count)
    }
}
