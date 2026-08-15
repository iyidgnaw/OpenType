import XCTest
@testable import OpenType

/// Stage-4 (review) coverage for P1-8 听写「轻整理」档.
///
/// `TidyTranscriptTests` pins the rules as designed. This file pins the
/// **false positives found by reading those rules and constructing sentences
/// they damage** — the ones the rule-by-rule tests could not see, because each
/// one lives in the gap between two rules that are individually correct.
///
/// Every case below is one of two kinds, and each test says which:
///
/// - **Fixed.** The rule deleted or corrupted something the user said. Tidy's
///   governing asymmetry (「leaving a filler in is a cosmetic miss; deleting a
///   real word is data loss the user may never notice」) makes these defects,
///   not trade-offs, so `TidyTranscript` was changed and the test pins the new
///   behaviour.
/// - **Accepted.** No deterministic rule can tell the good case from the bad
///   one, so the test is characterization: it pins what currently happens, says
///   what it costs, and exists so the cost is visible and has a name.
final class TidyTranscriptFalsePositiveTests: XCTestCase {

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

    // MARK: - Fixed: a filler that is a whole sentence is the answer, not a hesitation

    func testAStandaloneHesitationSentenceIsAnAnswerAndSurvives() {
        // 嗯 alone is 「yes」. The tier-A rule fires on any clause-leading 嗯, and
        // a sentence boundary is a clause boundary, so 「他问我明天去不去。嗯。」
        // lost its answer entirely — the question survived and the reply did
        // not. 「嗯。」 on its own only ever survived by falling through to the
        // never-empty floor, i.e. by the accident of being the whole
        // transcript; put anything in front of it and the accident stops
        // saving it.
        assertUntouched("嗯。")
        assertUntouched("他问我明天去不去。嗯。")
        assertUntouched("好的。嗯。我知道了。")
        // Still a hesitation when the sentence continues past it — this is the
        // shape the rule is actually for, and it must keep working.
        assertTidy("嗯，我觉得可以。", "我觉得可以。")
        assertTidy("好的。嗯，我觉得可以。", "好的。我觉得可以。")
    }

    func testAStandaloneNaGeSentenceIsAnAnswerAndSurvives() {
        // 那个 alone is 「that one」, and 「你要哪个？那个。」 is how the answer to
        // a which-one question is actually spoken. Before the fix this tidied
        // to 「你要哪个？」 — strictly worse than the contrastive-topic cost tier
        // B already accepts knowingly, because there the mutilated sentence at
        // least keeps its predicate; here the entire reply is gone.
        assertUntouched("你要哪个？那个。")
        assertUntouched("这个还是那个？那个！")
        // Same shape with the terminal mark not yet dictated: end of text is
        // where tidy is about to add one, so it counts as a sentence end.
        assertTidy("你说的是哪个？那个", "你说的是哪个？那个。")
        // And the hesitation shape is untouched by the fix.
        assertTidy("那个，我们下周再说。", "我们下周再说。")
    }

    func testTheWholeSentenceExemptionReadsTheOriginalTextNotTheOutputSoFar() {
        // The interaction that makes the exemption subtle enough to be worth a
        // test of its own. The clause-leading tests read the output built so
        // far, so that removing 「嗯，」 promotes what followed it. If the
        // exemption inherited that promotion, then in an all-filler utterance
        // every earlier filler would be gone by the time the last one is
        // reached, its left neighbour would read as "start of text", and it
        // would be exempted — while the never-empty floor, which still holds
        // all four, would tidy to something different on a second pass.
        // Idempotence is the property that catches it.
        let input = "嗯，呃，那个，就是说，"
        let once = TidyTranscript.tidy(input)
        XCTAssertEqual(TidyTranscript.tidy(once), once)
        XCTAssertFalse(once.isEmpty)
    }

    func testEnglishFillersAreDeliberatelyNotExemptedAsWholeSentences() {
        // The asymmetry is intentional and worth pinning so it does not look
        // like an oversight: 嗯 means 「yes」 and 那个 means 「that one」, but a
        // standalone 「Um.」 has no affirmative sense in English — it is a
        // hesitation and nothing else. The exemption exists for word senses
        // that exist; um/uh/er have none, so they keep being removed.
        assertTidy("Yes. Um. No.", "Yes. No.")
    }

    // MARK: - Fixed: punctuation width must not eat a file extension

    func testADotInsideACjkFilenameIsNotWidenedIntoAFullStop() {
        // The widening guard checked only the character *before* the dot, so a
        // filename whose stem is Chinese read as "Han character, then a full
        // stop": 「打开 报告.pdf」 delivered 「打开报告。pdf。」 — the user's
        // filename, broken, in the field they were dictating into. The stage-1
        // tests covered `report.pdf` and `3.14`, where the character before the
        // dot is ASCII and the old guard already fired; a CJK stem is the case
        // between them.
        assertTidy("打开 报告.pdf", "打开报告.pdf。")
        assertTidy("文件在 桌面/文档.txt 里。", "文件在桌面/文档.txt 里。")
        assertTidy("打开 网易.com 看看。", "打开网易.com 看看。")
        assertTidy(
            "路径是 /Users/diywang/报告.pdf",
            "路径是 /Users/diywang/报告.pdf。"
        )
        // The guard is dot-only and right-hand-side-only, so an ordinary
        // clause-ending mark after Han still widens exactly as before.
        assertTidy("我们开会,好吗?", "我们开会，好吗？")
        assertTidy("时间:3点", "时间：3点。")
        assertTidy("版本 3.14 已经发布了", "版本 3.14 已经发布了。")
    }

    // MARK: - Fixed: a repeated Han numeral is a value, not a stutter

    func testRepeatedHanNumeralsAreNotAStutter() {
        // The stutter rule is Han-only *because* repeated digits are a value —
        // and then Whisper writes a dictated 「二二二」 in Han, where the rule
        // does apply, and 「我的房间是二二二号」 became 「我的房间是二号」. Exactly
        // the failure the ASCII-digit restriction was written to prevent,
        // arriving through the script the restriction does not cover, and a
        // wrong number is the kind of error the user has no way to notice.
        assertUntouched("我的房间是二二二号。")
        assertUntouched("验证码是三三三。")
        assertUntouched("他说一一一是错的。")
        // Non-numeral stutters still collapse.
        assertTidy("我我我想说个事。", "我想说个事。")
    }

    // MARK: - Fixed: English repeats on purpose too

    func testEnglishOnomatopoeiaAndFarewellsSurviveLikeTheirChineseCounterparts() {
        // 哈哈哈 is protected because the run length carries the meaning, and
        // the English side had no such allowlist at all: "ha ha ha" collapsed
        // to "ha" and "bye bye" to "bye". The same loss, in the other script,
        // in a tool whose most common target is a chat app.
        assertUntouched("ha ha ha, that's funny.")
        assertUntouched("Bye bye!")
        assertTidy("bye bye", "bye bye.")
        // Ordinary doubled words still collapse.
        assertTidy("the the file is gone.", "the file is gone.")
    }

    func testARepeatedHesitationCharacterKeepsItsRunLengthOnceTierAKeepsIt() {
        // Follows from the two fixes together: tier A now keeps a whole-sentence
        // 嗯 run, which hands it to the stutter rule, where 「嗯嗯嗯。」 —
        // emphatic agreement, written exactly that way in Chinese chat — would
        // have collapsed to a flat 「嗯。」. Same reasoning as 哈哈哈, so 嗯/呃
        // join that allowlist.
        assertUntouched("嗯嗯嗯。")
        assertTidy("呃呃呃呃", "呃呃呃呃。")
    }

    // MARK: - Accepted: no deterministic rule can separate these

    func testFillersInsideAQuotedUtteranceAreStillRemoved() {
        // Characterization. The stage-1 tests pin that a filler *immediately*
        // after an opening quote survives, because an opening quote is not a
        // clause boundary. A filler after a comma *inside* the quote is a
        // different matter: that comma is a genuine clause boundary, so the
        // rule fires and a verbatim quotation loses a word it is quoting.
        //
        // Accepted rather than fixed: suppressing tidy inside quotes needs
        // balanced-quote tracking over text that routinely has unbalanced
        // quotes (dictation drops the closing one), and a mis-tracked quote
        // would suppress cleanup across the whole rest of the transcript. The
        // damage here is one filler inside a quote; the damage from a wrong
        // quote-range guess is the entire feature silently not working.
        assertTidy("他说『嗯，那个，我不确定』", "他说『嗯，我不确定』。")
    }

    func testACapitalisedErIsTreatedAsAFillerEvenWhenItIsAName() {
        // Characterization. The ALL-CAPS guard saves 「the ER」, but a
        // capitalised 「Er」 is exactly what a sentence-initial dictated filler
        // looks like ("Er, I think we should ship it."), so it cannot also be
        // reserved for the romanised name. The filler reading is far more
        // common in this product's input, and the cost is pinned here.
        assertTidy("Er Wang 来了。", "Wang 来了。")
        // The reason the guard cannot simply be "keep capitalised er".
        assertTidy("Er, I think so.", "I think so.")
    }

    func testAnIntentionallyDoubledMarkIsCollapsedLikeAnyOtherRun() {
        // Characterization, and the deliberate half of it is worth naming: a
        // mixed pair is a pairing and survives, but a doubled *identical* mark
        // is indistinguishable from ASR noise, so emphasis loses.
        assertUntouched("什么？！")
        assertTidy("什么？？", "什么？")
    }

    func testARepeatedProperNounCollapsesLikeAnyOtherDoubledWord() {
        // Characterization. "New York York" is a dictation slip far more often
        // than a real string, and no deterministic rule distinguishes a
        // repeated proper noun from a repeated article.
        assertTidy("New York York", "New York.")
    }

    func testAnEmojiOnlyUtteranceAcquiresATerminalMark() {
        // Characterization, cosmetic. An emoji is not "content" to the
        // never-empty check (it is a symbol), so an emoji-only transcript
        // returns through the removal-free floor — which still appends the
        // sentence-final mark. Harmless, pinned because it is visible.
        assertTidy("😀", "😀.")
        assertTidy("好的 😀", "好的 😀。")
    }

    // MARK: - Properties over the cases this file adds

    /// The stage-1 corpus properties cannot see these inputs, and the fixes
    /// above changed rule *ordering* (a filler tier A now keeps is a filler the
    /// repetition rule now sees), which is exactly the kind of change that
    /// breaks a fixed point.
    private static let corpus: [String] = [
        "嗯。", "他问我明天去不去。嗯。", "好的。嗯。我知道了。", "嗯。好的。",
        "你要哪个？那个。", "你说的是哪个？那个", "这个还是那个？那个！",
        "那个。那个。", "嗯。那个。", "。嗯。", "？那个。", "嗯\n好的",
        "嗯嗯嗯。", "嗯嗯", "呃呃呃呃", "Yes. Um. No.",
        "打开 报告.pdf", "文件在 桌面/文档.txt 里。", "打开 网易.com 看看。",
        "路径是 /Users/diywang/报告.pdf", "时间:3点", "1.5 vs 1。5",
        "我的房间是二二二号。", "验证码是三三三。", "他说一一一是错的。",
        "ha ha ha, that's funny.", "bye bye", "Bye bye!", "New York York",
        "他说『嗯，那个，我不确定』", "Er Wang 来了。", "Er, I think so.",
        "什么？！", "什么？？", "😀", "好的 😀", "第一行\n第二行",
        "看 https://example.com/a 这个链接。", "会议时间是 3:30。",
        "报告,v2 在桌面。", "先看这个，那个", "我们明天开会，那个。"
    ]

    private func hasContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
        }
    }

    func testTidyIsIdempotentOverTheseCasesToo() {
        for input in Self.corpus {
            let once = TidyTranscript.tidy(input)
            XCTAssertEqual(
                TidyTranscript.tidy(once),
                once,
                "tidy is not idempotent for \(input.debugDescription): \(once.debugDescription)"
            )
        }
    }

    func testTidyStillNeverEmptiesInputThatHadContent() {
        for input in Self.corpus where hasContent(input) {
            XCTAssertTrue(
                hasContent(TidyTranscript.tidy(input)),
                "\(input.debugDescription) tidied away to nothing"
            )
        }
    }

    func testTidyStillGrowsByNoMoreThanTheTerminalMark() {
        for input in Self.corpus {
            let result = TidyTranscript.tidy(input)
            XCTAssertLessThanOrEqual(
                result.count,
                input.count + 1,
                "\(input.debugDescription) grew to \(result.debugDescription)"
            )
        }
    }
}
