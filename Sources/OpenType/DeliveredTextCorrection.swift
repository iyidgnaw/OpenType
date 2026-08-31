import Foundation

/// The pure text seam behind the Direct/Tidy in-place correction history
/// rewrite (2026-08-30 batch,
/// `docs/superpowers/specs/2026-08-30-direct-tidy-in-place-correction-history-design.md`).
///
/// An in-place correction pastes only the replacement back into the target
/// app, but the sidecar's `episodic_events` row for that delivery still holds
/// the pre-correction full text — which is what the dictation history page
/// and the ask/agent recent-activity injection keep showing. Swift is the
/// only side that knows the full delivered text, the exact span the user
/// selected, and the replacement, so it is the side that must lift the
/// correction back to the whole string before PATCHing the row.
///
/// **No LLM call, no I/O, no AppKit** — the same product commitment
/// `TidyTranscript` keeps, enforced the same way: the signature is pure,
/// synchronous, and non-throwing, with nowhere to reach for anything but the
/// three strings it is given. The sidecar receives only text on the PATCH,
/// never the live selection range, so the one bit of evidence this seam is
/// allowed to use is *exact occurrence count*: the selected text must appear
/// in the delivered text **exactly once** for the rewrite to be unambiguous.
///
/// The tie-breaker for every judgement call here is the design's own:
/// **never guess.** A selection that is absent — or present more than once,
/// so the corrected span cannot be told apart from its twins — returns `nil`
/// and the whole rewrite is abandoned; mutating history on a guess would
/// teach the memory layer a "correction" the user never made.
enum DeliveredTextCorrection {

    /// Replaces the single occurrence of `selectedText` in `deliveredText`
    /// with `replacement` and returns the whole corrected string, or `nil`
    /// when the rewrite would be a guess.
    ///
    /// Matching uses Swift `String` range APIs — grapheme-cluster `Character`
    /// boundaries, never UTF-16 offsets — so emoji and CJK text are matched
    /// as exactly the ordinary visible characters they are.
    ///
    /// - Parameters:
    ///   - deliveredText: The full text the Direct/Tidy delivery actually put
    ///     in front of the user (post-Tidy, post-dictionary-rewrite — the
    ///     text the correction window was armed over), as it stands *after*
    ///     any earlier corrections.
    ///   - selectedText: The span the user selected in the target app when
    ///     they asked to correct it.
    ///   - replacement: What the correction produced for that span.
    /// - Returns: `deliveredText` with the one occurrence of `selectedText`
    ///   replaced by `replacement`, or `nil` if `selectedText` occurs zero or
    ///   more-than-once times (never guess) or is empty (an empty selection
    ///   matches everywhere and rewrites nothing in particular).
    static func reconstruct(
        deliveredText: String,
        selectedText: String,
        replacement: String
    ) -> String? {
        // An empty selection is not "one occurrence": `range(of: "")` matches
        // at the start of the text, and the same empty string follows it at
        // every position — i.e. the multiple-occurrence case, refused below
        // only after the first scan would already have rewritten the wrong
        // thing. Reject it outright so the multi-occurrence rule is the only
        // rule that ever runs.
        guard !selectedText.isEmpty else { return nil }

        // The first occurrence, or none at all — absence is unambiguous and
        // safe to refuse immediately (`testAbsentSelection…`).
        guard let first = deliveredText.range(of: selectedText) else { return nil }

        // Count the rest: if the selected text occurs again anywhere after
        // the first match, the exact intended span is unknowable from text
        // alone (the target app's live selection range never reaches the
        // sidecar), so the rewrite is a guess and is refused
        // (`testRepeatedSelection…`).
        let remainder = deliveredText[first.upperBound...]
        guard remainder.range(of: selectedText) == nil else { return nil }

        return deliveredText.replacingCharacters(in: first, with: replacement)
    }
}