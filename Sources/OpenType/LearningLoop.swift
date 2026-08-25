import Foundation

/// The learning loop's three exits, made visible (§D of
/// `docs/superpowers/specs/2026-08-15-product-batch-plan.md`, motivated by
/// `docs/reviews/2026-08-15-product-review.md` §1).
///
/// The 2026-08-14 batch closed a real loop in code: the entity dictionary
/// biases ASR (P0-1), an accepted correction teaches the dictionary (P0-2), and
/// the next transcription comes out right. **All three of its exits were
/// silent.** A user corrected 「呸泡」 to PayPal, the next dictation spelled it
/// correctly, and the only two explanations available to them were "Whisper got
/// lucky" and "something rewrote my words and I don't know what". The product
/// did the work and got none of the credit — and, worse, a *wrongly* learned
/// alias rewrote the user's words with no explanation and no exit but hunting
/// through the memory page.
///
/// Everything here is pure and screen-free, for the reason `CorrectionWindow`,
/// `OutputDeliveryPolicy` and `UsageStats` are: `AppModel.init` has side
/// effects and is not instantiable in tests, so a decision that only exists
/// inside it is a decision nobody can check. Nothing in this file touches
/// AppKit, the main actor, or the network.

// MARK: - D-1: what the dictionary rewrote

/// One rewrite `POST /asr/transcribe` applied on the way out, as the user reads
/// it: the alias it heard, the canonical it wrote, and the dictionary row that
/// said so.
///
/// `termId` is what makes the rewrite *undoable* — `DELETE /memory/terms/:id`
/// needs an id, and `{from, to}` alone would force a reverse lookup against
/// `AppModel.memoryTerms`, a list that is only populated once the memory panel
/// has been opened. The sidecar holds the whole dictionary when it builds this
/// row, so it is the only place where the answer is both free and unambiguous
/// (`sidecar/src/asr/dictionaryBias.ts`'s `termIdForReplacement`).
struct AliasReplacement: Decodable, Equatable {
    /// The alias, spelled as it sits in the dictionary — not as the recogniser
    /// happened to emit it. It is half of the pair the user is about to delete.
    let from: String
    /// The canonical spelling that was written into the text, in its own casing.
    let to: String
    /// The row `DELETE /memory/terms/:id` targets.
    let termId: Int
}

/// `POST /asr/transcribe`'s response.
///
/// `replacements` is absent from every response written before D-1 and from
/// every response that rewrote nothing — the sidecar omits the key rather than
/// sending `[]` — so the absence has to decode, and it decodes to an empty list
/// rather than to an optional every call site would then unwrap. This is the
/// hottest path in the product: a decoding failure here costs the user their
/// dictation, not a toast.
///
/// `rawText` (Task 4 of
/// `docs/superpowers/plans/2026-08-25-unified-memory-and-recent-context.md`)
/// is what Whisper actually produced, before the entity dictionary rewrote
/// any alias — `text` is the rewritten form. The sidecar always sends both
/// (unlike `replacements`, there is no absent-key/back-compat case for this
/// one), so it decodes as a plain required `String`. `EpisodicEventRecorder`
/// is what needs the two kept apart: it feeds `rawText` and `text` to
/// `AppModel`'s episodic-event write as `rawTranscript`/`correctedTranscript`
/// respectively, and consolidation mines that pair to find mishearings.
struct TranscribeResponse: Decodable, Equatable {
    let text: String
    let rawText: String
    /// In text order, left to right. Empty when nothing was rewritten.
    let replacements: [AliasReplacement]

    private enum CodingKeys: String, CodingKey {
        case text
        case rawText
        case replacements
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        rawText = try container.decode(String.self, forKey: .rawText)
        replacements = try container.decodeIfPresent(
            [AliasReplacement].self,
            forKey: .replacements
        ) ?? []
    }
}

/// The line the delivery toast gains when the dictionary changed something.
enum AliasReplacementNotice {
    /// 「自动修正 N 处」, or `nil` when there is nothing to announce.
    ///
    /// Absence is representable on purpose: 「自动修正 0 处」 is noise on the one
    /// path the user takes hundreds of times a day, and a toast that says
    /// something every time is a toast nobody reads.
    ///
    /// The count is **places, not distinct terms** — two rewrites of the same
    /// term in one utterance are two spots where the text changed, and the
    /// expanded list offers an undo control for each.
    static func summary(for replacements: [AliasReplacement]) -> String? {
        guard !replacements.isEmpty else { return nil }
        let count = replacements.count
        return OpenTypeL10n.text(
            "自动修正 \(count) 处",
            english: count == 1
                ? "1 automatic correction"
                : "\(count) automatic corrections"
        )
    }
}

/// What 「撤销并删除该词条」 is allowed to do at this instant.
///
/// Alias learning is heuristic, so a wrong alias is a reachable state, and the
/// click that takes it back has to be able to fail safely. Every way it can
/// fail is a product decision:
///
///  - it must never paste over text the user has moved on from,
///  - it must never paste into an app that was not the delivery's target,
///  - it must never guess *which* occurrence of a word to put back, and
///  - it must delete the offending term in **all** of those cases, because the
///    term is wrong regardless of whether this particular paste can be undone.
///
/// That last one is why the outcome is a value rather than a `Bool`: "did it
/// restore the text" and "did it delete the term" have different answers, and a
/// UI that collapses them either lies about the deletion or sends the user off
/// to do it themselves.
///
/// **The timing is borrowed, not re-derived.** The undo is live exactly while
/// the post-delivery correction window is (`CorrectionWindow.State.isExpired`)
/// and exactly while a delivery would be allowed to write
/// (`OutputDeliveryPolicy.shouldInsert`), because the restore goes out through
/// the very same `ContextBridge.insert` path. A second time limit — a longer
/// one for undo, one measured from the toast instead of the delivery — would be
/// a rule that drifts away from the real one and has to be adjudicated later.
enum AliasUndo {

    /// Why the delivered text could not be put back.
    enum Blocker: Equatable {
        /// The correction window has closed.
        case windowExpired
        /// The user is looking at a different app than the delivery landed in.
        case targetApplicationChanged
        /// The delivered text no longer says what the rewrite report says it
        /// says, so which occurrence to restore is a guess.
        case textNoLongerMatches
    }

    enum Decision: Equatable {
        /// Put this text back where the delivery went, and delete the term.
        case restoreText(String)
        /// Delete the term and leave the text alone, for this reason.
        case forgetTermOnly(Blocker)

        var restoredText: String? {
            switch self {
            case .restoreText(let text): return text
            case .forgetTermOnly: return nil
            }
        }

        /// Always true. Spelled out rather than left implicit because it is the
        /// half of the outcome that never varies: the alias was wrong, and it
        /// stays wrong whether or not this particular paste can be undone.
        var deletesTerm: Bool { true }
    }

    /// Decides what one 「撤销并删除该词条」 click may do.
    ///
    /// - Parameters:
    ///   - replacement: The row the user clicked.
    ///   - deliveredText: What was actually delivered — after Tidy, after a
    ///     Review edit — not what ASR returned.
    ///   - replacements: Every rewrite this delivery carried, in text order.
    ///   - window: The open correction window, or `nil` if there is none.
    ///   - now: Read from the caller so the decision stays pure.
    ///   - frontmostBundleId: The app in front *now*.
    static func decide(
        undoing replacement: AliasReplacement,
        in deliveredText: String,
        replacements: [AliasReplacement],
        window: CorrectionWindow.State?,
        now: Date,
        frontmostBundleId: String?
    ) -> Decision {
        // Expiry first, and it wins even when the app also changed: it is the
        // one blocker that is unconditionally true. Telling someone who waited
        // a minute that the problem was switching apps invites them to switch
        // back and try again, which will not work.
        //
        // No window at all counts as expired rather than as permission:
        // `AppModel` clears the window on a new recording, on Esc and on an
        // ineligible delivery, and a toast can outlive all three.
        guard let window, !window.isExpired(at: now) else {
            return .forgetTermOnly(.windowExpired)
        }

        // Where the caret is beats what the text says, so this is asked before
        // the text is inspected: the user's fix for a changed app is real ("go
        // back to Notes"), while reporting the text would send them looking at
        // something they cannot even see.
        guard OutputDeliveryPolicy.shouldInsert(
            capturedBundleId: window.capturedBundleId,
            frontmostBundleId: frontmostBundleId
        ) else {
            return .forgetTermOnly(.targetApplicationChanged)
        }

        guard let restored = restoring(
            replacement,
            in: deliveredText,
            replacements: replacements
        ) else {
            return .forgetTermOnly(.textNoLongerMatches)
        }
        return .restoreText(restored)
    }

    /// What the user is told afterwards.
    ///
    /// Four sentences rather than one shared 「已撤销」, because the failure this
    /// guards against is the user clicking, seeing the text not change, and
    /// finding nothing on screen that explains why. Each blocker also names the
    /// thing the user could do differently, where there is one.
    static func message(for decision: Decision) -> String {
        switch decision {
        case .restoreText:
            return OpenTypeL10n.text(
                "已改回原话，并删除了这条词典记录",
                english: "Put your own words back and deleted the dictionary entry"
            )
        case .forgetTermOnly(.windowExpired):
            return OpenTypeL10n.text(
                "已删除这条词典记录，但撤销时限已过，这次的文本没有改回",
                english: "Deleted the dictionary entry. The undo window had closed, so this text was left as delivered."
            )
        case .forgetTermOnly(.targetApplicationChanged):
            return OpenTypeL10n.text(
                "已删除这条词典记录，但前台应用已切换，这次的文本没有改回",
                english: "Deleted the dictionary entry. You had switched apps, so this text was left as delivered."
            )
        case .forgetTermOnly(.textNoLongerMatches):
            return OpenTypeL10n.text(
                "已删除这条词典记录，但那段文本已经变了，没有改回",
                english: "Deleted the dictionary entry. The delivered text had already changed, so it was left alone."
            )
        }
    }

    /// The delivered text with every place *this term* rewrote given back the
    /// word the user actually said, or `nil` when that cannot be done without
    /// guessing.
    ///
    /// Scoped to one term but resolved against every rewrite that produced the
    /// same canonical spelling, because that is what makes the positions
    /// knowable: the report is in text order and so are the occurrences, so the
    /// *i*-th occurrence of the canonical belongs to the *i*-th row that wrote
    /// it. Rows belonging to other terms keep their canonical — undo is scoped
    /// to the row the user clicked — while rows belonging to this one get their
    /// own alias back, which is what makes 「呸泡 和 paipal」 come back as two
    /// different words rather than as whichever alias happened to be first.
    ///
    /// The count check is the whole safety argument. If the delivered text
    /// carries more (or fewer) occurrences of the canonical than the report
    /// accounts for, then at least one of them was not ours — the user said
    /// 「PayPal」 correctly once and was misheard once, or Tidy/Review changed
    /// the text after the rewrite — and nothing in `{from, to, termId}` says
    /// which. Rewriting a word the user said correctly is strictly worse than
    /// the mis-transcription being undone, so the answer is to decline.
    private static func restoring(
        _ replacement: AliasReplacement,
        in deliveredText: String,
        replacements: [AliasReplacement]
    ) -> String? {
        let canonical = replacement.to
        guard !canonical.isEmpty else { return nil }

        let rows = replacements.filter { $0.to == canonical }
        guard !rows.isEmpty,
              rows.contains(where: { $0.termId == replacement.termId })
        else { return nil }

        let occurrences = ranges(of: canonical, in: deliveredText)
        guard occurrences.count == rows.count else { return nil }

        var restored = ""
        var cursor = deliveredText.startIndex
        for (row, occurrence) in zip(rows, occurrences) {
            restored += deliveredText[cursor..<occurrence.lowerBound]
            restored += row.termId == replacement.termId ? row.from : canonical
            cursor = occurrence.upperBound
        }
        restored += deliveredText[cursor...]
        return restored
    }

    /// Non-overlapping occurrences, left to right.
    ///
    /// `.literal` rather than a default search: the canonical is written back
    /// with its own casing, so an occurrence in different casing came from the
    /// user rather than from us and must not be counted as one of ours. A
    /// case- or width-folding search would quietly claim it and then overwrite
    /// a word nobody asked us to touch.
    private static func ranges(
        of needle: String,
        in haystack: String
    ) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack.range(
                of: needle,
                options: .literal,
                range: searchStart..<haystack.endIndex
              ) {
            found.append(range)
            searchStart = range.upperBound
        }
        return found
    }
}

// MARK: - D-2: what a correction taught

/// What `POST /transcribe/correct` wrote into the entity dictionary, when the
/// correction qualified (P0-2). The sidecar omits the key entirely rather than
/// sending null, so a caller can test for its presence.
struct LearnedTerm: Decodable, Equatable {
    let canonicalTerm: String
    let alias: String
}

/// `POST /transcribe/correct`'s response, shared by both correction paths — the
/// Review panel's and Direct mode's in-place one.
///
/// One decoder for one endpoint, deliberately: the `learned` field spent this
/// whole batch decoded-but-unread, and a second, parallel body type is how a
/// field ends up read by nobody in the first place.
struct CorrectionResponse: Decodable, Equatable {
    let replacement: String
    let learned: LearnedTerm?
}

/// The 「已记住」 acknowledgement.
enum LearnedTermNotice {

    /// The sentence, plus the row a click on it reveals.
    ///
    /// A bare `String` cannot carry the second half, and re-parsing the term
    /// back out of the sentence is exactly the kind of thing that survives
    /// until someone translates the copy.
    struct Notice: Equatable {
        let text: String
        /// The dictionary is keyed on the canonical spelling; the alias is one
        /// of possibly several on that row and would select nothing on its own.
        let canonicalTerm: String
    }

    /// 「已记住：呸泡 → PayPal」, or `nil` when this correction taught nothing.
    ///
    /// Silence is the majority case and it is the correct one: most rewrites —
    /// a reworded phrase, a pure case fix, a span too long to be a term — do
    /// not qualify, and claiming 「已记住」 after one that was deliberately not
    /// learned would teach the user to distrust the one signal this adds.
    ///
    /// The direction is the content: 「呸泡 → PayPal」 and 「PayPal → 呸泡」
    /// describe opposite dictionaries, and only one of them is what happened.
    static func notice(for learned: LearnedTerm?) -> Notice? {
        guard let learned else { return nil }
        let canonical = learned.canonicalTerm
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let alias = learned.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        // Defensive, and cheap: the sidecar's gate should never emit a blank
        // half, but a toast reading 「已记住： →  」 is a bug the user is left
        // holding, and showing nothing instead costs nothing.
        guard !canonical.isEmpty, !alias.isEmpty else { return nil }

        return Notice(
            text: OpenTypeL10n.text(
                "已记住：\(alias) → \(canonical)",
                english: "Remembered: \(alias) → \(canonical)"
            ),
            canonicalTerm: canonical
        )
    }
}

// MARK: - D-3: how much the dictionary has learned

/// 「词典已学会 N 个词」, counted over the rows the memory panel has already
/// fetched (`GET /memory/terms` → `AppModel.memoryTerms`).
///
/// The trend line beside it answers 「is this getting better」; this answers
/// 「what has it actually learned」, which is the figure that makes the loop
/// legible on day three, before there is enough history for a slope to mean
/// anything. It adds no endpoint, no second store and no counter — it is a
/// count over rows that were on screen anyway.
enum DictionaryStats {

    struct LearnedTermCounts: Equatable {
        /// Every row in the dictionary, whatever its provenance.
        let total: Int
        /// Rows the owner taught it, directly or by accepting a correction.
        let owner: Int
        /// Rows `remember_fact` wrote out of agent context (P1-12) — text that
        /// arrived from a web page or a file the agent read, not from the user.
        let untrusted: Int
    }

    /// Counts **rows, not aliases**: 「学会了 N 个词」 means N entries. Counting
    /// aliases instead would make a term the user corrected three times read as
    /// three learned words, and the number would climb fastest exactly when
    /// recognition was working worst.
    ///
    /// Split by `origin` because a blended total would let a number the user
    /// reads as "how much I have taught it" quietly include rows nobody taught
    /// it — the provenance confusion the `origin` badge exists to prevent. A
    /// row with an unrecognised or missing origin counts toward the total only:
    /// unknown provenance is not owner provenance, and the split has to
    /// under-claim rather than credit the user with a row nobody can vouch for.
    static func counts(for terms: [EntityTermSummary]) -> LearnedTermCounts {
        LearnedTermCounts(
            total: terms.count,
            owner: terms.filter { $0.origin == "owner" }.count,
            untrusted: terms.filter { $0.origin == "untrusted" }.count
        )
    }
}
