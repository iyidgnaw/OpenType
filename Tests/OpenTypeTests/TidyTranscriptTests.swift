import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for P1-8 听写「轻整理」档
/// (`docs/superpowers/specs/2026-08-14-product-batch-plan.md`).
///
/// Direct mode's promise is 「一个字都不多、一个字都不少」. Tidy is a third
/// *delivery* variant of the same transcribe mode that does deterministic
/// cleanup with **no LLM call at all** — a product commitment, not an
/// implementation detail: 轻整理 must never mean "send it to a model and hope."
/// A rule that cannot be executed deterministically therefore does not belong
/// in this tier, and several rules below are deliberately narrower than the
/// spec bullet that motivated them for exactly that reason.
///
/// The governing asymmetry for every removal rule: **leaving a filler in is a
/// cosmetic miss; deleting a real word is data loss the user may never
/// notice.** Every ambiguous case below resolves toward "leave it alone."
///
/// These tests are RED until Stage 3 adds `Sources/OpenType/TidyTranscript.swift`
/// with `TidyTranscript.tidy(_ text: String) -> String`. They currently fail to
/// COMPILE because that type does not exist — that is the intended red.
/// (`TranscribeVariant.tidy` and the settings/routing surface are pinned
/// separately in `TranscribeVariantTidyTests.swift`.)
///
/// The rules this file pins, in the order `tidy` must be able to apply them so
/// that the whole function is idempotent:
///
/// 1. **Whitespace** — ends trimmed; runs of spaces/tabs collapsed to one;
///    a space *between two CJK characters* removed (Chinese never uses one, and
///    MLX-Whisper emits them); a space between CJK and Latin/digits preserved.
/// 2. **Chinese fillers, tier A (`嗯`/`呃`)** — never real words, so removed
///    whenever they lead a clause (start of text, or right after a *pause or
///    terminal* mark — 「，。！？；：、」 and their ASCII twins, **not** an
///    opening quote or bracket), including repeated runs, together with the
///    punctuation mark that immediately follows the filler.
/// 3. **Chinese fillers, tier B (`那个`/`就是说`)** — both are also real
///    Chinese: 「那个文件」is a demonstrative and 「就是说明书」contains 就是说
///    as a substring of 说明书. Removed **only** when they lead a clause *and*
///    are immediately followed by a pause or terminal mark — i.e. only the
///    「那个，」/「就是说，」 hesitation shape. A following space is not a
///    following mark (「那个 PR」), and a clause boundary is a pause mark, not
///    any character `CharacterSet.punctuationCharacters` happens to contain.
/// 4. **English fillers (`um`/`uh`/`er`)** — standalone tokens, matched
///    case-insensitively, never inside a word and never across a hyphen
///    (`uh-huh` is a word). An ALL-CAPS token is left alone so "the ER"
///    survives. `like` is **excluded entirely** — see the test.
/// 5. **Immediate repetition** — CJK: a run of ≥3 identical *Han* characters,
///    minus an allowlist of onomatopoeia (哈/呵/嘿…) that repeats on purpose.
///    Latin: an immediately repeated word, minus an allowlist of legitimate
///    doublings. Both halves need the allowlist for the same reason: a rule
///    with no exceptions here shreds ordinary text.
/// 6. **Punctuation** — the *text's own script* picks the target width
///    (any CJK present → full-width pause/terminal marks; otherwise ASCII), a
///    `.` widens to 。 only when the character before it is CJK (so `3.14`,
///    `e.g.` and filenames survive), runs of one identical mark collapse to
///    one except dot-like marks (`.` `。` `…`, where a run is an ellipsis), and
///    a terminal mark is appended when the text ends without one.
/// 7. **Never empty** — filler-only input must still come back with content.
final class TidyTranscriptTests: XCTestCase {

    // MARK: - Helpers

    private func assertTidy(
        _ input: String,
        _ expected: String,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            TidyTranscript.tidy(input),
            expected,
            message,
            file: file,
            line: line
        )
    }

    /// For text that is already clean: tidying must be a no-op, byte for byte.
    private func assertUntouched(
        _ input: String,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            TidyTranscript.tidy(input),
            input,
            message,
            file: file,
            line: line
        )
    }

    /// True when `text` still carries at least one character that is neither
    /// whitespace nor punctuation — i.e. the user's dictation did not vanish
    /// into a lone period.
    private func hasContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
        }
    }

    // MARK: - 1. Chinese fillers, tier A: 嗯 / 呃

    func testLeadingChineseHesitationAndItsCommaAreBothRemoved() {
        // Removing 嗯 but leaving its comma behind would produce 「，我觉得可以。」
        // — a worse result than doing nothing. The punctuation that belonged to
        // the filler goes with the filler.
        assertTidy("嗯，我觉得可以。", "我觉得可以。")
    }

    func testLeadingChineseHesitationWithNoPunctuationAfterItIsStillRemoved() {
        // 嗯/呃 are pure interjections: there is no Chinese word they can be the
        // start of, so unlike 那个/就是说 (below) they need no punctuation guard.
        assertTidy("嗯我觉得可以。", "我觉得可以。")
    }

    func testRepeatedHesitationRunAfterACommaIsRemovedWithItsTrailingComma() {
        // Clause-initial means "after a punctuation mark" too, not only "at the
        // start of the text" — mid-sentence hesitation is the common case.
        assertTidy("我看了一下，呃呃，应该没问题。", "我看了一下，应该没问题。")
    }

    func testAStandaloneHesitationBetweenSpacesIsRemoved() {
        // "Stands alone" is the other half of the tier-A rule: MLX-Whisper often
        // emits a hesitation as its own space-delimited token rather than after
        // a comma. Removing it leaves 「我  觉得」, which the CJK-space rule then
        // closes up.
        assertTidy("我 呃 觉得可以。", "我觉得可以。")
        assertTidy("嗯 um 呃 uh 我们开会", "我们开会。")
    }

    func testTrailingHesitationLeavesNoDanglingComma() {
        // 「……开会，嗯。」 must not tidy to 「……开会，。」 or 「……开会，」.
        assertTidy("我们明天开会，嗯。", "我们明天开会。")
    }

    func testAQuotedHesitationIsContentAndKeepsItsQuotesIntact() {
        // 「他回了一个「嗯」」 is a sentence *about* the word 嗯 — quoting a
        // one-word reply is an everyday chat shape, and there the filler is the
        // whole point of the sentence. Both halves of the tier-A rule would
        // fire on a careless implementation: 「 is in
        // `CharacterSet.punctuationCharacters`, so a "right after a punctuation
        // mark" test reads 嗯 as clause-leading, and "remove the mark that
        // follows the filler" would then eat the *closing* quote as well,
        // leaving 「他回了一个「」。」. A clause boundary is a pause or terminal
        // mark, never an opening quote or bracket.
        assertUntouched("他回了一个「嗯」。")
        // Same trap on the Latin path: `\bum\b` matches happily inside quotes,
        // because a quote is a word boundary.
        assertUntouched("He said \"um\" and left.")
    }

    // MARK: - 2. Chinese fillers, tier B: 那个 / 就是说 (the dangerous ones)

    func testHesitationShapedNaGeIsRemoved() {
        // 「那个，」 with the pause actually spoken: the only shape where 那个 is
        // unambiguously a filler.
        assertTidy("那个，我们下周再说。", "我们下周再说。")
    }

    func testDemonstrativeNaGeSurvivesBecauseDeletingItWouldDeleteAWord() {
        // 那个 is a real demonstrative — 「那个文件」 is "that file". Dropping it
        // here changes which file the user meant, silently. This is the single
        // most important test in this file: a tidy pass that deletes words the
        // user actually said is worse than one that leaves a filler in, because
        // the user cannot see what is missing.
        assertUntouched("那个文件在桌面上。")
        assertUntouched("帮我把那个文档打开。")
        // 「我要那个。」 is the case that pins the *and* in the tier-B rule: 那个
        // here IS immediately followed by a punctuation mark, and is still a
        // real word ("I want that one"). Position alone and punctuation alone
        // are each insufficient; only both together mean hesitation.
        assertUntouched("我要那个。")
    }

    func testClauseLeadingNaGeSurvivesWhenItIsFollowedByWordsRatherThanAPause() {
        // 「那个时候」 = "back then". Clause-initial, no pause after it, and
        // fully load-bearing — so clause position alone must never be enough to
        // delete 那个.
        assertUntouched("那个时候我还在上学。")
    }

    func testHesitationShapedJiuShiShuoIsRemoved() {
        assertTidy("就是说，这件事不用急。", "这件事不用急。")
    }

    func testJiuShiShuoSurvivesWhenItIsTheHeadOfARealWord() {
        // 「就是说明书上没写清楚」 = "it's that the manual doesn't say." The
        // filler string 就是说 is a prefix of 就是+说明书; deleting it yields
        // 「明书上没写清楚」, which is gibberish the user would have to
        // re-dictate. Hence the punctuation guard on this tier.
        assertUntouched("就是说明书上没写清楚。")
    }

    func testJiuShiShuoSurvivesMidClause() {
        // 「他的意思就是说……」 is ordinary prose, not hesitation.
        assertUntouched("他的意思就是说这件事不急。")
    }

    func testJiuShiShuoSurvivesMidClauseEvenWhenAPauseFollowsIt() {
        // The case that pins the *and* in the tier-B rule for 就是说, the way
        // 「我要那个。」 pins it for 那个: here 就是说 IS immediately followed by
        // a pause mark, and is still the sentence's actual verb phrase —
        // 「我的意思就是说」 = "what I mean is". An implementation that dropped
        // the clause-leading half of the rule and matched on "filler followed
        // by a mark" alone would pass every other 就是说 test in this file and
        // silently produce 「我的意思，我们该走了。」 here.
        assertUntouched("我的意思就是说，我们该走了。")
        assertUntouched("他要表达的就是说，这事没那么急。")
    }

    func testTierBFillersSurviveWhenOnlyASpaceFollowsThem() {
        // A space is not a pause mark. 「那个 PR」 is a demonstrative in front
        // of a Latin token, which is this product's most ordinary mixed-script
        // shape — and it is exactly what a "standalone token between spaces"
        // reading of the tier-A rule (`testAStandaloneHesitationBetweenSpaces`)
        // would destroy if it were generalized to tier B, since 那个 here is
        // text-leading with a space after it.
        assertUntouched("那个 PR 我看了。")
        assertUntouched("那个 bug 我修好了。")
    }

    func testContrastiveTopicNaGeIsTheKnownCostOfTheTierBRule() {
        // Characterization, not endorsement: 「那个，」 as a *contrastive topic*
        // (「这个，我来处理；那个，你来处理。」 = "this one I'll handle; that one
        // you handle") is character-for-character the same string as 「那个，」
        // the hesitation, so no deterministic rule can keep one and drop the
        // other. Tier B chooses to drop it, and this is what that costs: the
        // second half of the sentence loses the thing it contrasts with.
        //
        // Pinned so the cost is visible and has a name. It is also the reason
        // 那个 and 就是说 are not equally safe members of this tier — 那个 is
        // *referential*, so deleting it can leave a sentence pointing at
        // nothing, while 就是说 is a discourse connective whose deletion costs
        // nuance but never a referent. If this tier is ever narrowed further,
        // 那个 is the one to drop, and this test is the one to delete.
        assertTidy(
            "这个，我来处理；那个，你来处理。",
            "这个，我来处理；你来处理。",
            "tier B cannot tell a contrastive topic from a hesitation"
        )
    }

    // MARK: - 3. English fillers: um / uh / er

    func testLeadingEnglishFillerAndItsCommaAreBothRemoved() {
        assertTidy(
            "So, um, I think we should ship it.",
            "So, I think we should ship it."
        )
    }

    func testMidSentenceEnglishFillerIsRemovedAndTheGapClosed() {
        // Removal must not leave the double space behind, and the sentence gains
        // the terminal period it was missing.
        assertTidy(
            "The file is uh on the desktop",
            "The file is on the desktop."
        )
    }

    func testEnglishFillerMatchingIsCaseInsensitive() {
        assertTidy("Um I think so.", "I think so.")
        assertTidy("Uh, forty two.", "forty two.")
    }

    func testTidyNeverChangesLetterCase() {
        // Deliberately no re-capitalisation after a leading filler is removed:
        // deciding a word's case needs syntax knowledge this tier does not have,
        // and a case rule that mangles `iPhone`, `npm`, or an identifier the
        // user dictated is a real regression. Lowercase "sure." is the honest
        // output of a case-preserving pass.
        assertTidy("Um, sure.", "sure.")
        assertUntouched("Ship the iPhone build to npm today.")
    }

    func testFillerLettersInsideRealWordsAreNotTouched() {
        // Word-boundary matching, not substring matching: `um` in "umbrella",
        // `er` in "newer"/"Ernest", `uh` nowhere.
        assertUntouched("The umbrella is under the newer server.")
        assertUntouched("Ernest sent the summary.")
    }

    func testHyphenatedUhHuhSurvives() {
        // "uh-huh" is a word. Treating the hyphen as a token boundary would
        // leave "-huh" behind, which is worse than leaving the whole thing.
        assertUntouched("She said uh-huh.")
    }

    func testAllCapsErSurvivesBecauseItIsAnAbbreviation() {
        // Dictated fillers come out of Whisper as "er"/"Er", never as "ER".
        // Skipping ALL-CAPS tokens is the cheap deterministic guard that keeps
        // "took him to the ER" intact.
        assertUntouched("I took him to the ER.")
    }

    func testLikeIsNeverRemovedAtAll() {
        // Deliberate deviation from the spec bullet, which lists `like`
        // alongside um/uh/er. `like` is a verb ("I like it"), a preposition
        // ("like magic"), and a conjunction ("looks like it works"); telling
        // those from the filler needs syntax, i.e. a model — which is exactly
        // what this tier promises not to use. So `like` is excluded, including
        // in the position where it really is a filler: a rule that is right 80%
        // of the time here deletes a real word 20% of the time, and this tier's
        // whole value is that the user can trust it blindly.
        assertUntouched("I like it, and it's like, magic.")
    }

    // MARK: - 4. Immediate repetition

    func testStutteredChineseCharacterRunCollapses() {
        // Three or more identical Han characters in a row: no Chinese word does
        // this, so it is always a stutter.
        assertTidy("我我我想说个事。", "我想说个事。")
        assertTidy("这这这个文件不对。", "这个文件不对。")
    }

    func testDoubledChineseCharactersSurviveBecauseReduplicationIsGrammatical() {
        // 刚刚 / 谢谢 / 看看 / 常常 are words, not stutters. A 2× rule would
        // shred ordinary Chinese, so the threshold is deliberately 3.
        assertUntouched("刚刚我看到他了。")
        assertUntouched("你先看看这个文件。")
        // Verb reduplication (看看/试试/想想) is one of the most frequent
        // patterns in spoken Chinese, and 常常/渐渐 are ordinary adverbs.
        // Halving any of them would be a constant, silent corruption.
        assertUntouched("你试试这个方法。")
        assertUntouched("我想想再回复你。")
        assertUntouched("他常常加班到很晚。")
        assertUntouched("天渐渐黑了。")
    }

    func testLaughterAndOnomatopoeiaRunsSurviveBecauseTheyRepeatOnPurpose() {
        // The one place the ≥3 threshold's premise — "no Chinese word repeats a
        // character three times" — is simply false. 哈哈哈 / 呵呵呵 / 嘻嘻嘻 /
        // 呜呜呜 are laughter and crying, they are written exactly this way, and
        // they are extremely common in the chat apps this tool dictates into.
        // The run length carries the meaning: collapsing 哈哈哈 to 哈 turns
        // laughter into sarcasm, and collapsing 哈哈哈哈 to 哈哈 changes how
        // hard the user is laughing. So onomatopoeia is an allowlist on the CJK
        // side, mirroring the English one in
        // `testLegitimatelyDoubledEnglishWordsSurvive`.
        assertUntouched("哈哈哈，太好笑了。")
        assertUntouched("哈哈哈哈哈，你太逗了。")
        assertUntouched("呵呵呵，随你吧。")
    }

    func testRepeatedDigitsAreNotACharacterStutter() {
        // The repetition rule is Han-only. Room numbers, years, verification
        // codes and phone numbers are full of repeated digits, and a rule that
        // ran over every script would turn 2222 into 22 — a wrong number the
        // user has no way to notice.
        assertUntouched("我的房间是 2222 号。")
        assertUntouched("验证码是 000123。")
    }

    func testIdenticalWordsSeparatedByAMarkAreNotAnImmediateRepetition() {
        // "Immediate" means adjacent, with nothing between. A mark between two
        // identical words means the speaker said the word twice on purpose —
        // and a tokenizer that strips punctuation before comparing (the obvious
        // way to write this rule) cannot see the difference.
        assertUntouched("No. No. I mean it.")
        assertUntouched("好，好，我知道了。")
    }

    func testATwoCharacterStutterIsLeftAloneOnPurpose() {
        // 「我我想」 really is a stutter, and it survives. That is the accepted
        // cost of the 3× threshold above: this tier under-cleans rather than
        // risk deleting a reduplicated word.
        assertUntouched("我我想说个事。")
    }

    func testAnEvenLengthRunIsTreatedAsADoubledWordNotASingleCharacter() {
        // 「谢谢谢谢你」 is 谢谢 said twice, not a 谢 stutter — collapsing the run
        // to one character would produce 「谢你」. An even-length run collapses to
        // two characters, an odd-length run to one: deterministic, and it errs
        // toward keeping a character rather than losing a word.
        assertTidy("谢谢谢谢你。", "谢谢你。")
    }

    func testImmediatelyRepeatedEnglishWordCollapses() {
        assertTidy("the the file is gone.", "the file is gone.")
        assertTidy("I need to to check it.", "I need to check it.")
    }

    func testLegitimatelyDoubledEnglishWordsSurvive() {
        // English does double words for real: "had had" (past perfect of have),
        // "that that", and the intensifiers very/really/so. These are an
        // allowlist, because collapsing them silently rewrites the sentence's
        // grammar.
        assertUntouched("I had had enough.")
        assertUntouched("It was very very good.")
        assertUntouched("No no, that is fine.")
        // "that that" is named in the reasoning above but was not asserted; it
        // is the doubling most likely to be dictated in a work sentence.
        assertUntouched("He said that that file was wrong.")
    }

    // MARK: - 5. Punctuation normalisation

    func testAsciiPunctuationInChineseTextBecomesFullWidth() {
        assertTidy("我们明天开会,好吗?", "我们明天开会，好吗？")
        assertTidy("先看邮件;再回我", "先看邮件；再回我。")
    }

    func testFullWidthPunctuationInEnglishTextBecomesAscii() {
        // The text's own script decides the target width, so an English
        // sentence never keeps a stray 。 from a Chinese-biased ASR pass.
        assertTidy("Let's ship it。", "Let's ship it.")
    }

    func testAPeriodBetweenAsciiCharactersIsNeverWidened() {
        // The one exception to "CJK text ⇒ full-width marks": a `.` widens only
        // when the character before it is CJK. Otherwise 「版本 3.14」 becomes
        // 「版本 3。14」 and a dictated filename or `e.g.` is destroyed.
        assertTidy("版本 3.14 已经发布了", "版本 3.14 已经发布了。")
        assertUntouched("比如 e.g. 这样。")
        assertUntouched("打开 report.pdf 看一下。")
    }

    func testRunsOfTheSameMarkCollapseToOne() {
        assertTidy("真的？？？", "真的？")
        assertTidy("wow!!!", "wow!")
        assertTidy("我知道了，，你先走。", "我知道了，你先走。")
    }

    func testEllipsesSurviveBecauseARunOfDotsIsItsOwnMark() {
        // A run of dot-like marks is an ellipsis, not repeated punctuation, so
        // `.` / 。 / … runs are excluded from the collapse rule.
        assertUntouched("Wait... let me check.")
        assertUntouched("等一下……我看看。")
    }

    func testMixedMarksAreNotCollapsed() {
        // Only *identical* marks collapse; "?!" is a deliberate pairing.
        assertUntouched("really?!")
    }

    func testTerminalPunctuationIsAddedWhenMissingUsingTheTextsOwnScript() {
        assertTidy("我们明天开会", "我们明天开会。")
        assertTidy("ship it", "ship it.")
        // Mixed text is Chinese text: it ends with 。 even when the last token
        // is Latin, which is what a Chinese writer would type.
        assertTidy("我用的是 GPT-4 的 API", "我用的是 GPT-4 的 API。")
    }

    func testTextThatAlreadyEndsInPunctuationGainsNothing() {
        assertUntouched("你确定吗？")
        assertUntouched("Done!")
        assertUntouched("等一下……")
    }

    // MARK: - 6. Whitespace

    func testEndsAreTrimmedAndSpaceRunsCollapse() {
        assertTidy("   we  should   ship it.  ", "we should ship it.")
    }

    func testSpacesBetweenCjkCharactersAreRemoved() {
        // MLX-Whisper emits these; Chinese never uses them.
        assertTidy("  我们   明天开会。  ", "我们明天开会。")
    }

    func testSpacesBetweenCjkAndLatinArePreserved() {
        // The inverse failure: no space may be *inserted* into a CJK run, and no
        // space may be *removed* from a CJK↔Latin boundary, where it is
        // conventional and load-bearing for readability.
        assertUntouched("我用的是 GPT-4 的 API。")
        assertUntouched("我们明天 review 一下 PR。")
    }

    // MARK: - 7. Never empty

    func testFillerOnlyChineseInputStillComesBackWithContent() {
        // The worst possible outcome for a dictation tool is that the user
        // speaks and gets nothing. If every rule fires and would leave nothing,
        // tidy must fall back to the (whitespace/punctuation-normalised) input
        // rather than return an empty string or a bare period.
        let result = TidyTranscript.tidy("嗯，嗯，呃。")
        XCTAssertTrue(
            hasContent(result),
            "filler-only input must not tidy away to nothing, got \(result.debugDescription)"
        )
    }

    func testInputThatIsNothingButFillersFromBothTiersStillComesBackWithContent() {
        // The hardest never-empty case, because every rule in the file fires on
        // it: tier A takes 嗯 and 呃, tier B takes the 那个 that the first
        // removal promoted to text-leading, and nothing at all is left. The
        // fallback is what stands between the user and an empty paste after
        // they have spoken — and 「嗯，那个，呃」 is a real thing to say while
        // deciding what to dictate.
        for input in ["嗯，那个，呃", "那个，那个。", "嗯，呃，那个，就是说，"] {
            let result = TidyTranscript.tidy(input)
            XCTAssertTrue(
                hasContent(result),
                "\(input.debugDescription) tidied away to \(result.debugDescription)"
            )
        }
    }

    func testFillerOnlyEnglishInputStillComesBackWithContent() {
        let result = TidyTranscript.tidy("um, uh, um")
        XCTAssertTrue(
            hasContent(result),
            "filler-only input must not tidy away to nothing, got \(result.debugDescription)"
        )
    }

    func testEmptyAndWhitespaceOnlyInputStayEmpty() {
        // The never-empty guarantee is about input that *had* content. Input
        // with none must not acquire a period out of nowhere — an empty
        // transcript is a failed recording, and 「。」 in the user's field would
        // be actively wrong.
        XCTAssertEqual(TidyTranscript.tidy(""), "")
        XCTAssertEqual(TidyTranscript.tidy("   "), "")
        XCTAssertEqual(TidyTranscript.tidy(" \n\t "), "")
    }

    // MARK: - 8. Mixed Chinese/English — this product's normal case

    func testMixedChineseEnglishDictation() {
        // Leading 嗯 goes; clause-initial 就是说 + its comma go; 那个 before
        // "bug" is a demonstrative and stays; the spaces around the Latin
        // tokens stay; the ASCII comma is widened; the sentence gains 。.
        assertTidy(
            "嗯，我们明天 review 一下 PR，就是说,把那个 bug 修掉",
            "我们明天 review 一下 PR，把那个 bug 修掉。"
        )
    }

    func testEveryRuleAtOnce() {
        // 嗯 + its comma; the now-leading 「那个，」 hesitation; the 我我我
        // stutter; a mid-clause 就是说 that is real prose and stays; a
        // clause-initial 那个 followed by 文件 that stays; ASCII 「,」/「?」
        // widened.
        assertTidy(
            "嗯，那个，我我我想说的就是说，那个文件在桌面上,你看一下?",
            "我想说的就是说，那个文件在桌面上，你看一下？"
        )
    }

    func testARemovalThatWouldStrandAMarkResolvesInOnePass() {
        // The rule-interaction shape the corpus-wide idempotence property is
        // there to catch, pinned concretely so a failure says *what* is wrong
        // rather than only "tidy is not idempotent". Filler removal and
        // punctuation normalisation feed each other in both directions:
        //
        // - a pre-existing doubled mark collapses, and the filler behind it is
        //   still recognised as clause-leading afterwards;
        // - removing a filler must not leave the marks on either side of it
        //   stacked up, whether the implementation takes the following mark
        //   with the filler or collapses the pair afterwards;
        // - a filler at the very end leaves a pause mark where a terminal one
        //   belongs, and 「……开会，」 is not an acceptable output.
        assertTidy("我看了一下，，嗯，应该没问题。", "我看了一下，应该没问题。")
        assertTidy("先看这个，嗯，再看那个，就是说，明天再说。",
                   "先看这个，再看那个，明天再说。")
        // A trailing filler is bounded by the end of the text, not only by a
        // mark: requiring a space on *both* sides would leave this one behind.
        assertTidy("我们明天开会 嗯", "我们明天开会。")
    }

    // MARK: - 9. Properties over the whole corpus

    /// Every input used above, plus a few extra shapes. Properties are asserted
    /// over the lot so a rule added later cannot quietly break one of them on
    /// an input its own test does not cover.
    private static let corpus: [String] = [
        "",
        "   ",
        " \n\t ",
        "嗯，我觉得可以。",
        "嗯我觉得可以。",
        "我看了一下，呃呃，应该没问题。",
        "我 呃 觉得可以。",
        "我们明天开会，嗯。",
        "那个，我们下周再说。",
        "那个文件在桌面上。",
        "帮我把那个文档打开。",
        "我要那个。",
        "那个时候我还在上学。",
        "就是说，这件事不用急。",
        "就是说明书上没写清楚。",
        "他的意思就是说这件事不急。",
        "So, um, I think we should ship it.",
        "The file is uh on the desktop",
        "Um I think so.",
        "Uh, forty two.",
        "Um, sure.",
        "Ship the iPhone build to npm today.",
        "The umbrella is under the newer server.",
        "Ernest sent the summary.",
        "She said uh-huh.",
        "I took him to the ER.",
        "I like it, and it's like, magic.",
        "我我我想说个事。",
        "这这这个文件不对。",
        "刚刚我看到他了。",
        "你先看看这个文件。",
        "我我想说个事。",
        "谢谢谢谢你。",
        "the the file is gone.",
        "I need to to check it.",
        "I had had enough.",
        "It was very very good.",
        "No no, that is fine.",
        "我们明天开会,好吗?",
        "先看邮件;再回我",
        "Let's ship it。",
        "版本 3.14 已经发布了",
        "比如 e.g. 这样。",
        "打开 report.pdf 看一下。",
        "真的？？？",
        "wow!!!",
        "我知道了，，你先走。",
        "Wait... let me check.",
        "等一下……我看看。",
        "really?!",
        "我们明天开会",
        "ship it",
        "我用的是 GPT-4 的 API",
        "你确定吗？",
        "Done!",
        "等一下……",
        "   we  should   ship it.  ",
        "  我们   明天开会。  ",
        "我用的是 GPT-4 的 API。",
        "我们明天 review 一下 PR。",
        "嗯，嗯，呃。",
        "um, uh, um",
        "嗯，我们明天 review 一下 PR，就是说,把那个 bug 修掉",
        "嗯，那个，我我我想说的就是说，那个文件在桌面上,你看一下?",
        "我的意思就是说，我们该走了。",
        "他要表达的就是说，这事没那么急。",
        "那个 PR 我看了。",
        "那个 bug 我修好了。",
        "这个，我来处理；那个，你来处理。",
        "他回了一个「嗯」。",
        "He said \"um\" and left.",
        "你试试这个方法。",
        "我想想再回复你。",
        "他常常加班到很晚。",
        "天渐渐黑了。",
        "哈哈哈，太好笑了。",
        "哈哈哈哈哈，你太逗了。",
        "呵呵呵，随你吧。",
        "我的房间是 2222 号。",
        "验证码是 000123。",
        "No. No. I mean it.",
        "好，好，我知道了。",
        "He said that that file was wrong.",
        "我看了一下，，嗯，应该没问题。",
        "先看这个，嗯，再看那个，就是说，明天再说。",
        "我们明天开会 嗯",
        "嗯，那个，呃",
        "那个，那个。",
        "嗯，呃，那个，就是说，",
        // Extra shapes no single rule test covers.
        "嗯，那个，那个，我说完了",
        "呃呃呃呃",
        "um um um um",
        "那个那个文件",
        "。",
        "，，，",
        "OK",
        "1234",
        "嗯 um 呃 uh 我们开会",
        "什么?!",
        "我用的是 GPT-4."
    ]

    func testTidyIsIdempotentOverTheWholeCorpus() {
        // The property that catches rule-interaction bugs: if tidying a tidied
        // string changes it, some rule is producing output another rule still
        // wants to rewrite — e.g. filler removal leaving a dangling comma that
        // the next pass would strip, or terminal punctuation being appended
        // twice. Also the practical guarantee for Review mode, where the same
        // text can pass through tidy more than once.
        for input in Self.corpus {
            let once = TidyTranscript.tidy(input)
            let twice = TidyTranscript.tidy(once)
            XCTAssertEqual(
                twice,
                once,
                "tidy is not idempotent for \(input.debugDescription): \(once.debugDescription) -> \(twice.debugDescription)"
            )
        }
    }

    func testTidyNeverEmptiesInputThatHadContent() {
        for input in Self.corpus where hasContent(input) {
            let result = TidyTranscript.tidy(input)
            XCTAssertTrue(
                hasContent(result),
                "\(input.debugDescription) tidied away to \(result.debugDescription)"
            )
        }
    }

    func testTidyIsDeterministic() {
        // The no-LLM commitment, expressed as a test: a synchronous,
        // non-throwing, pure signature is what enforces it at compile time
        // (there is nowhere to await a provider call), and byte-identical output
        // across repeated calls is what would fail loudly if that ever changed.
        for input in Self.corpus {
            let first = TidyTranscript.tidy(input)
            for _ in 0..<5 {
                XCTAssertEqual(
                    TidyTranscript.tidy(input),
                    first,
                    "tidy is not deterministic for \(input.debugDescription)"
                )
            }
        }
    }

    func testTidyNeverIntroducesASpaceIntoACjkRun() {
        // Cheap global guard on the whitespace rule: a CJK character followed
        // directly by another CJK character in the input must never come back
        // with a space wedged between them.
        for input in Self.corpus {
            let result = TidyTranscript.tidy(input)
            XCTAssertFalse(
                Self.containsSpaceBetweenCjk(result),
                "\(input.debugDescription) tidied to \(result.debugDescription), which wedges a space into a CJK run"
            )
        }
    }

    func testTidyNeverGrowsTextByMoreThanTheTerminalMark() {
        // 轻整理 subtracts and normalises; the only character it may *add* is
        // the sentence-final mark. Stated as a property because the failures it
        // catches are the ones no expected-value test would think to look for:
        // a removal that re-inserts the text it removed, a normalisation pass
        // that duplicates a clause, a never-empty fallback that concatenates
        // rather than falls back. It also holds the line on a specific
        // temptation — inserting spaces at CJK↔Latin boundaries the ASR did not
        // emit. The spec's whitespace bullet is 「首尾空白、多余空格」, i.e.
        // remove excess, and a tier the user is meant to trust blindly should
        // not be silently rewriting spacing it was never asked about.
        for input in Self.corpus {
            let result = TidyTranscript.tidy(input)
            XCTAssertLessThanOrEqual(
                result.count,
                input.count + 1,
                "\(input.debugDescription) grew to \(result.debugDescription)"
            )
        }
    }

    /// True if `text` has ` CJK` on both sides of a run of spaces.
    private static func containsSpaceBetweenCjk(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            guard scalars[index] == " " else {
                index += 1
                continue
            }
            var end = index
            while end < scalars.count, scalars[end] == " " { end += 1 }
            let before = index > 0 ? scalars[index - 1] : nil
            let after = end < scalars.count ? scalars[end] : nil
            if let before, let after, isCjk(before), isCjk(after) { return true }
            index = end
        }
        return false
    }

    /// Han characters and CJK-width punctuation — enough for these assertions.
    private static func isCjk(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,   // CJK symbols and punctuation
             0x3400...0x4DBF,   // extension A
             0x4E00...0x9FFF,   // unified ideographs
             0xF900...0xFAFF,   // compatibility ideographs
             0xFF00...0xFFEF:   // full-width forms
            return true
        default:
            return false
        }
    }
}
