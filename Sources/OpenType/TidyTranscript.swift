import Foundation

/// 听写「轻整理」档 (P1-8,
/// `docs/superpowers/specs/2026-08-14-product-batch-plan.md`): the tier between
/// Direct's 「一个字都不多、一个字都不少」 and Ask's 「问答」.
///
/// **No LLM call, ever.** That is the product commitment this type exists to
/// keep, not an implementation detail: 轻整理 must never mean "send it to a
/// model and hope." The signature is the enforcement — pure, synchronous,
/// non-throwing, with nowhere to await a provider — so a rule that cannot be
/// executed deterministically does not belong here at all. Several rules below
/// are therefore deliberately narrower than the spec bullet that motivated
/// them (`like` is dropped entirely; 那个/就是说 need a punctuation guard).
///
/// The governing asymmetry, and the tie-breaker for every judgement call in
/// this file: **leaving a filler in is a cosmetic miss; deleting a real word is
/// data loss the user may never notice.** Ambiguous cases resolve toward
/// "leave it alone."
///
/// Applied in this order, then re-applied to a fixed point (see `tidy`):
///
/// 1. Chinese hesitations 嗯/呃 (tier A: never real words).
/// 2. Chinese discourse fillers 那个/就是说 (tier B: also real Chinese).
/// 3. English fillers um/uh/er.
/// 4. Immediate repetition (stutters and doubled words).
/// 5. Whitespace — trim, collapse runs, close up CJK↔CJK gaps.
/// 6. Punctuation width, collapsed runs, sentence-final mark.
/// 7. Never empty: input that had content comes back with content.
///
/// Whitespace is cleaned *after* the removals, not before them, because a
/// space is **evidence**: MLX-Whisper emits a hesitation as its own
/// space-delimited token (「我 呃 觉得可以。」) as often as it emits one after a
/// comma, and closing the CJK↔CJK gap first would fuse that 呃 into the
/// surrounding words where tier A can no longer see it standing alone.
enum TidyTranscript {

    /// Cleans `text` and returns it. Everything about the result is a function
    /// of `text` alone.
    static func tidy(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Input with no content must not *acquire* a sentence-final mark out of
        // nowhere: an empty transcript is a failed recording, and 「。」 landing
        // in the user's field would be actively wrong.
        guard !trimmed.isEmpty else { return "" }

        // The floor: the user's words with nothing removed, only spacing and
        // punctuation regularised. Every removal rule below is allowed to fail
        // back to this, because the worst outcome for a dictation tool is that
        // the user speaks and gets nothing.
        let removalFreeFloor = normalizingPunctuation(normalizingWhitespace(trimmed))

        // Removals feed each other in both directions — dropping 「嗯，」
        // promotes whatever followed it to clause-leading, and closing up the
        // gap a removal left can expose the next one — so the removal rules run
        // to a fixed point rather than in a single hand-ordered sweep. Each
        // pass can only shorten the string, so this terminates; the bound is
        // belt-and-braces, and reaching it is not an error.
        //
        // The seed is the *untouched* trimmed text rather than a whitespace-
        // normalised one: tier A reads a surrounding space as "this filler
        // stands alone", so normalising first would delete the very evidence it
        // depends on. Each pass ends with `normalizingWhitespace`, which both
        // closes the gap a removal just left and re-exposes shapes the raw
        // spacing hid (「the  the file」 collapses on the pass after the double
        // space does) — the fixed point is what makes the late cleanup safe.
        var working = trimmed
        for _ in 0..<maximumRemovalPasses {
            let before = working
            working = removingChineseHesitations(working)
            working = removingChineseDiscourseFillers(working)
            working = removingEnglishFillers(working)
            working = collapsingImmediateRepetition(working)
            working = normalizingWhitespace(working)
            if working == before { break }
        }

        let tidied = normalizingPunctuation(working)
        return hasContent(tidied) ? tidied : removalFreeFloor
    }

    /// Generous enough that no realistic utterance reaches it (each pass
    /// strictly shortens the string, and `tidy` breaks as soon as a pass
    /// changes nothing).
    private static let maximumRemovalPasses = 8

    // MARK: - Character classes

    /// Marks that end a clause without ending the sentence, in both widths.
    static let pauseMarks: Set<Character> = ["，", "、", "；", "：", ",", ";", ":"]

    /// Marks that end a sentence, in both widths. `…` is here so 「等一下……」
    /// reads as finished and gains no second mark.
    static let terminalMarks: Set<Character> = ["。", "！", "？", "…", ".", "!", "?"]

    /// Whether `character` closes a clause — the only evidence this file
    /// accepts for "what follows begins a new clause."
    ///
    /// Deliberately **not** `CharacterSet.punctuationCharacters`, which also
    /// contains 「, 【, ", and ( . Treating an opening quote as a clause
    /// boundary is what makes 「他回了一个「嗯」。」 — a sentence *about* the
    /// word 嗯 — look like a hesitation, and treating a closing quote as a
    /// removable trailing mark is what would then eat the 」 too.
    private static func isClauseBoundary(_ character: Character) -> Bool {
        pauseMarks.contains(character) || terminalMarks.contains(character)
    }

    /// Han ideographs. Used for the *script* decisions (which punctuation width
    /// the text wants, whether a repeated character is a stutter) because those
    /// must not be swayed by a stray full-width mark a Chinese-biased ASR pass
    /// left in an otherwise English sentence.
    private static func isHan(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first
        else { return false }
        switch scalar.value {
        case 0x3400...0x4DBF,   // extension A
             0x4E00...0x9FFF,   // unified ideographs
             0xF900...0xFAFF,   // compatibility ideographs
             0x20000...0x2FA1F: // extensions B and beyond
            return true
        default:
            return false
        }
    }

    /// Han plus CJK-width punctuation and full-width forms — "wide enough that
    /// a space next to it is wrong." Used for the whitespace rule and for the
    /// guard on widening a token-internal mark.
    private static func isCjkWidth(_ character: Character) -> Bool {
        if isHan(character) { return true }
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first
        else { return false }
        switch scalar.value {
        case 0x3000...0x303F,   // CJK symbols and punctuation
             0xFF00...0xFFEF:   // full-width forms
            return true
        default:
            return false
        }
    }

    /// True while `text` still carries something that is neither whitespace nor
    /// punctuation — i.e. the user's dictation did not vanish into a lone
    /// period.
    private static func hasContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
        }
    }

    // MARK: - 1. Whitespace

    /// Trims the ends, collapses every run of spaces/tabs to one, and deletes
    /// the run entirely when CJK-width characters sit on both sides — Chinese
    /// never uses a space there and MLX-Whisper emits them anyway.
    ///
    /// A CJK↔Latin gap is left exactly as dictated: conventional, load-bearing
    /// for readability, and not ours to invent or delete. Newlines are passed
    /// through untouched — merging lines would be a content decision, not
    /// spacing cleanup.
    private static func normalizingWhitespace(_ text: String) -> String {
        let characters = Array(text)
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        var index = 0
        while index < characters.count {
            guard characters[index] == " " || characters[index] == "\t" else {
                output.append(characters[index])
                index += 1
                continue
            }
            var end = index
            while end < characters.count,
                  characters[end] == " " || characters[end] == "\t" {
                end += 1
            }
            let before = output.last
            let after = end < characters.count ? characters[end] : nil
            // A run at either end of the text disappears (that is the trim); a
            // run between two wide characters disappears too; anything else
            // becomes exactly one space.
            if let before, let after, !(isCjkWidth(before) && isCjkWidth(after)) {
                output.append(" ")
            }
            index = end
        }
        return String(output)
    }

    // MARK: - 2. Chinese hesitations, tier A

    /// 嗯 and 呃 are pure interjections: there is no Chinese word either of them
    /// can begin, so unlike tier B they need no punctuation guard on the right —
    /// 「嗯我觉得可以」 is as much a hesitation as 「嗯，我觉得可以」.
    private static let chineseHesitations: Set<Character> = ["嗯", "呃"]

    /// Removes runs of 嗯/呃 that begin a clause or stand alone, together with
    /// the mark that belonged to them.
    ///
    /// The mark goes with the filler because removing 嗯 out of 「嗯，我觉得可以。」
    /// and leaving its comma produces 「，我觉得可以。」 — a worse result than
    /// doing nothing. Only pause/terminal marks are eligible (see
    /// `isClauseBoundary`), so a closing quote is never swallowed.
    ///
    /// A filler that is a whole sentence by itself is exempt — see
    /// `isAWholeSentence`.
    private static func removingChineseHesitations(_ text: String) -> String {
        let characters = Array(text)
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        var index = 0
        while index < characters.count {
            guard chineseHesitations.contains(characters[index]),
                  beginsClauseOrStandsAlone(after: output.last)
            else {
                output.append(characters[index])
                index += 1
                continue
            }
            var end = index
            while end < characters.count,
                  chineseHesitations.contains(characters[end]) {
                end += 1
            }
            let following = end < characters.count ? characters[end] : nil
            guard !isAWholeSentence(
                precededBy: sentenceContext(of: characters, before: index),
                followedBy: following
            ) else {
                output.append(contentsOf: characters[index..<end])
                index = end
                continue
            }
            if let following, isClauseBoundary(following) {
                end += 1
            }
            index = end
        }
        return String(output)
    }

    // MARK: - The whole-sentence exemption, shared by both Chinese tiers

    /// Whether a filler standing between these two neighbours is not a
    /// hesitation at all but **the entire sentence** — the user's whole
    /// utterance, which deleting would answer a question with silence.
    ///
    /// A hesitation is by definition followed by the thing being hesitated
    /// about, inside the same sentence: 「嗯，我觉得可以。」, 「那个，我们下周再说。」.
    /// A filler with a *sentence* boundary on both sides is the opposite shape,
    /// and in both tiers it is far more likely to be a real word:
    ///
    /// - 嗯 alone is 「yes」. 「他问我明天去不去。嗯。」 loses its answer without
    ///   this guard, and 「嗯。」 only survived by falling through to the
    ///   never-empty floor — i.e. by accident of being the whole transcript.
    /// - 那个 alone is 「that one」. 「你要哪个？那个。」 loses its answer, which is
    ///   strictly worse than the contrastive-topic cost tier B already accepts,
    ///   because there the sentence at least keeps its predicate.
    ///
    /// The cost, accepted knowingly and in the direction this file always
    /// resolves toward: a hesitation that Whisper happened to punctuate as its
    /// own sentence (「嗯。我觉得可以。」) is now left in. That is a visible
    /// cosmetic miss at the front of the text, against invisible data loss.
    ///
    /// **English fillers are deliberately not exempted.** um/uh/er have no
    /// affirmative sense — a standalone 「Um.」 is a hesitation and nothing else
    /// — so the reason for the guard does not exist on that side.
    private static func isAWholeSentence(
        precededBy previous: Character?,
        followedBy following: Character?
    ) -> Bool {
        closesASentence(previous) && closesASentence(following)
    }

    /// `nil` — the start or the end of the text — counts: the end is exactly
    /// where the sentence-final mark is about to be added.
    private static func closesASentence(_ character: Character?) -> Bool {
        guard let character else { return true }
        return terminalMarks.contains(character) || character.isNewline
    }

    /// The character to this filler's left **in the text as it arrived**, not in
    /// the output built so far.
    ///
    /// The distinction is load-bearing. The clause-leading tests
    /// (`beginsClause…`) read `output.last` on purpose, so that removing 「嗯，」
    /// promotes what followed it to clause-leading. The whole-sentence exemption
    /// must not inherit that promotion: in 「嗯，呃，那个，就是说，」 every earlier
    /// filler is gone by the time 就是说 is reached, so `output.last` is `nil`
    /// and the exemption would read the last filler as a whole sentence — and
    /// then the never-empty floor, which still contains all four, would tidy to
    /// something different on a second pass. Reading the original left neighbour
    /// keeps the exemption a statement about the user's sentence structure, and
    /// keeps `tidy` idempotent.
    ///
    /// Spaces and tabs are transparent, so 「他问我。 嗯。」 reads the same as
    /// 「他问我。嗯。」.
    private static func sentenceContext(
        of characters: [Character],
        before index: Int
    ) -> Character? {
        var cursor = index - 1
        while cursor >= 0, characters[cursor] == " " || characters[cursor] == "\t" {
            cursor -= 1
        }
        return cursor >= 0 ? characters[cursor] : nil
    }

    /// Tier A's left-hand context: the start of the text, a clause boundary, or
    /// whitespace. Whitespace counts because MLX-Whisper often emits a
    /// hesitation as its own space-delimited token (「我 呃 觉得可以。」) rather
    /// than after a comma; the leftover double space is closed up afterwards by
    /// `normalizingWhitespace`. What it must *not* count is another word
    /// character on the left, which is the guard that keeps a 嗯 sitting inside
    /// a quotation or a word out of reach.
    private static func beginsClauseOrStandsAlone(after previous: Character?) -> Bool {
        guard let previous else { return true }
        return previous.isWhitespace || isClauseBoundary(previous)
    }

    // MARK: - 3. Chinese discourse fillers, tier B

    /// The dangerous tier, and the reason this file has doc comments at all.
    ///
    /// Both of these are **ordinary Chinese**, not only fillers:
    ///
    /// - 那个 is a demonstrative. 「那个文件在桌面上。」 is "that file is on the
    ///   desktop"; deleting 那个 silently changes which file the user meant.
    ///   「那个时候我还在上学。」 is "back then". 「我要那个。」 is "I want that
    ///   one" — clause-leading *and* followed by a mark is not enough on its
    ///   own either, which is why the rule below needs both halves at once.
    /// - 就是说 is a verb phrase. 「我的意思就是说，我们该走了。」 is "what I
    ///   mean is, we should go" — the filler string is the sentence's actual
    ///   predicate, and it is followed by a comma. 「就是说明书上没写清楚」
    ///   contains 就是说 only as a prefix of 就是 + 说明书; deleting it yields
    ///   「明书上没写清楚」, gibberish the user has to re-dictate.
    ///
    /// So the shape below is **both** conditions together — clause-leading
    /// *and* immediately followed by a pause or terminal mark, i.e. the
    /// 「那个，」/「就是说，」 hesitation and nothing else. If you are reading this
    /// intending to simplify the rule to "remove the filler wherever it leads a
    /// clause" or "wherever a comma follows it", each of those alone deletes
    /// real words in the examples above. A following *space* is likewise not a
    /// following mark: 「那个 PR 我看了。」 is this product's most ordinary
    /// mixed-script shape.
    ///
    /// Known cost, accepted deliberately: a contrastive topic
    /// (「这个，我来处理；那个，你来处理。」) is character-for-character the same
    /// string as the hesitation, so no deterministic rule can keep one and drop
    /// the other. If this tier is ever narrowed further, 那个 is the one to
    /// drop — it is *referential*, so deleting it can leave a sentence pointing
    /// at nothing, while 就是说 is a discourse connective whose loss costs
    /// nuance but never a referent.
    private static let chineseDiscourseFillers: [[Character]] = [
        Array("就是说"),
        Array("那个")
    ]

    private static func removingChineseDiscourseFillers(_ text: String) -> String {
        let characters = Array(text)
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        var index = 0
        scan: while index < characters.count {
            if beginsClause(after: output.last) {
                for filler in chineseDiscourseFillers {
                    let end = index + filler.count
                    guard end <= characters.count,
                          Array(characters[index..<end]) == filler
                    else { continue }
                    let following = end < characters.count ? characters[end] : nil
                    // 「你要哪个？那个。」 — a one-word answer, not a hesitation.
                    guard !isAWholeSentence(
                        precededBy: sentenceContext(of: characters, before: index),
                        followedBy: following
                    ) else { continue }
                    guard let following else {
                        // End of the text is where the sentence-final mark is
                        // about to be added, so it counts as one. Without this,
                        // 「先看这个，那个」 would keep 那个 on the first pass and
                        // drop it on the second — tidy has to be idempotent.
                        index = end
                        continue scan
                    }
                    guard isClauseBoundary(following) else { continue }
                    index = end + 1  // the filler's own mark goes with it
                    continue scan
                }
            }
            output.append(characters[index])
            index += 1
        }
        return String(output)
    }

    /// Tier B's left-hand context: the start of the text or a clause boundary —
    /// and, unlike tier A, *not* whitespace. Narrower on purpose: whitespace on
    /// the left is exactly the evidence that would make 「那个 PR」 look
    /// clause-leading, and this tier is where a wrong guess costs the user a
    /// real word.
    private static func beginsClause(after previous: Character?) -> Bool {
        guard let previous else { return true }
        return isClauseBoundary(previous)
    }

    // MARK: - 4. English fillers

    /// `like` is **absent on purpose**, in deviation from the spec bullet that
    /// lists it alongside these. It is a verb ("I like it"), a preposition
    /// ("like magic") and a conjunction ("looks like it works"); telling those
    /// from the filler needs syntax, i.e. a model — the one thing this tier
    /// promises not to use. A rule that is right 80% of the time here deletes a
    /// real word the other 20%, and this tier's whole value is that the user
    /// can trust it without proof-reading.
    private static let englishFillers: Set<String> = ["um", "uh", "er"]

    /// Removes um/uh/er when they stand as their own token, plus the mark that
    /// belonged to them (「So, um, I think」 → 「So, I think」).
    private static func removingEnglishFillers(_ text: String) -> String {
        let characters = Array(text)
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        var index = 0
        while index < characters.count {
            guard isTokenCharacter(characters[index]) else {
                output.append(characters[index])
                index += 1
                continue
            }
            var end = index
            while end < characters.count, isTokenCharacter(characters[end]) {
                end += 1
            }
            let token = String(characters[index..<end])
            let following = end < characters.count ? characters[end] : nil
            if isRemovableEnglishFiller(
                token,
                previous: output.last,
                following: following
            ) {
                index = end
                if let following, isClauseBoundary(following) { index += 1 }
                continue
            }
            output.append(contentsOf: characters[index..<end])
            index = end
        }
        return String(output)
    }

    private static func isRemovableEnglishFiller(
        _ token: String,
        previous: Character?,
        following: Character?
    ) -> Bool {
        guard englishFillers.contains(token.lowercased()) else { return false }
        // Dictated fillers come out of Whisper as "er"/"Er", never as "ER", so
        // a token with no lowercase letter at all is an abbreviation: "I took
        // him to the ER." keeps its ER.
        guard token.contains(where: \.isLowercase) else { return false }
        // Whitespace, a clause boundary, or the edge of the text on both sides.
        // A quote is neither — `\bum\b` matches happily inside one, because a
        // quote is a word boundary, and 「He said "um" and left.」 is a sentence
        // about the word. A hyphen is neither either, which is what keeps
        // "uh-huh" whole: token scanning treats it as one word, and leaving
        // "-huh" behind would be worse than leaving the whole thing.
        let leftIsOpen = previous.map { $0.isWhitespace || isClauseBoundary($0) } ?? true
        let rightIsOpen = following.map { $0.isWhitespace || isClauseBoundary($0) } ?? true
        return leftIsOpen && rightIsOpen
    }

    /// What holds a word together. Hyphens and apostrophes are inside the token
    /// so that "uh-huh", "GPT-4" and "it's" are each one word rather than
    /// several — the difference between leaving "uh-huh" alone and mangling it.
    private static func isTokenCharacter(_ character: Character) -> Bool {
        character.isLetter
            || character.isNumber
            || character == "-"
            || character == "'"
            || character == "\u{2019}"
    }

    // MARK: - 5. Immediate repetition

    private static func collapsingImmediateRepetition(_ text: String) -> String {
        String(collapsingDoubledWords(collapsingHanStutters(Array(text))))
    }

    /// Characters that repeat *on purpose*. 哈哈哈 / 呵呵呵 / 嘻嘻嘻 / 呜呜呜 are
    /// laughter and crying, they are written exactly this way, and they are
    /// everywhere in the chat apps this tool dictates into. The run length
    /// carries the meaning: collapsing 哈哈哈 to 哈 turns laughter into sarcasm,
    /// and 哈哈哈哈 to 哈哈 changes how hard the user is laughing.
    ///
    /// 嗯 and 呃 are here for the same reason, and only ever reach this rule in
    /// the one shape tier A leaves them in: a whole-sentence 「嗯嗯嗯。」, which
    /// in Chinese chat is emphatic agreement written exactly that way.
    /// Collapsing it to 「嗯。」 flattens enthusiastic assent into a shrug —
    /// precisely the 哈哈哈-to-哈 loss, in the one place tier A has already
    /// decided the characters are the user's message rather than a hesitation.
    private static let onomatopoeia: Set<Character> = [
        "哈", "呵", "嘿", "嘻", "呜", "啊", "嗯", "呃"
    ]

    /// Han numerals, exempt for exactly the reason ASCII digits are (see
    /// `collapsingHanStutters`'s "Han-only, deliberately" note): a repeated
    /// digit is a *value*, not a stutter. Whisper writes a dictated 「三三三」 in
    /// Han as readily as in Arabic, and 「我的房间是二二二号」 collapsing to
    /// 「二号」 is a wrong room number the user cannot see is wrong — the exact
    /// failure the Han-only restriction was written to prevent, arriving
    /// through the script it does not restrict.
    private static let hanNumerals: Set<Character> = [
        "〇", "零", "一", "二", "三", "四", "五", "六", "七", "八", "九",
        "十", "百", "千", "万", "两", "幺"
    ]

    /// Collapses a run of three or more identical Han characters.
    ///
    /// The threshold is 3, not 2, because Chinese reduplication is grammatical
    /// and extremely frequent: 看看 / 试试 / 想想 / 刚刚 / 常常 / 渐渐 / 谢谢 are
    /// words, and halving any of them would be a constant, silent corruption of
    /// the user's text. The accepted cost is that a genuine two-character
    /// stutter (「我我想」) survives — this tier under-cleans rather than risk
    /// deleting a reduplicated word.
    ///
    /// An even-length run collapses to two characters and an odd-length one to
    /// a single character, because 「谢谢谢谢你」 is 谢谢 said twice, not a 谢
    /// stutter, and 「谢你」 would be the wrong repair.
    ///
    /// Han-only, deliberately: room numbers, years, verification codes and
    /// phone numbers are full of repeated digits, and a rule that ran over
    /// every script would turn 2222 into 22 — a wrong number the user has no
    /// way to notice.
    private static func collapsingHanStutters(_ characters: [Character]) -> [Character] {
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            var end = index
            while end < characters.count, characters[end] == character { end += 1 }
            let length = end - index
            let keep: Int
            if length >= 3,
               isHan(character),
               !onomatopoeia.contains(character),
               !hanNumerals.contains(character) {
                keep = length.isMultiple(of: 2) ? 2 : 1
            } else {
                keep = length
            }
            output.append(contentsOf: Array(repeating: character, count: keep))
            index = end
        }
        return output
    }

    /// English doubles words for real: "had had" is the past perfect of have,
    /// "that that" is the doubling most likely to turn up in a work sentence,
    /// and very/really/so/no are intensifiers. Collapsing any of them silently
    /// rewrites the sentence's grammar, so they are an allowlist — the mirror
    /// of `onomatopoeia` on the CJK side.
    ///
    /// "ha" and "bye" are that mirror literally: the CJK side protects 哈哈哈
    /// because the run length carries the meaning, and "ha ha ha" → "ha" and
    /// "bye bye" → "bye" are the same loss in the other script. The asymmetry
    /// was real — those two collapsed while 哈哈哈 was protected.
    private static let legitimatelyDoubledWords: Set<String> = [
        "had", "that", "very", "really", "so", "no", "ha", "bye"
    ]

    /// Collapses an immediately repeated word ("the the file" → "the file").
    ///
    /// "Immediately" means adjacent with a single space between and nothing
    /// else: a mark between two identical words means the speaker said the word
    /// twice on purpose ("No. No. I mean it."), and a tokenizer that stripped
    /// punctuation before comparing — the obvious way to write this — could not
    /// tell the difference. Only all-ASCII-letter words qualify, so digits
    /// ("code 1 1 2") and Han runs are out of scope for the same reason they
    /// are in `collapsingHanStutters`.
    private static func collapsingDoubledWords(_ characters: [Character]) -> [Character] {
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        var index = 0
        while index < characters.count {
            guard isTokenCharacter(characters[index]) else {
                output.append(characters[index])
                index += 1
                continue
            }
            var end = index
            while end < characters.count, isTokenCharacter(characters[end]) { end += 1 }
            let token = String(characters[index..<end])

            if isCollapsibleWord(token),
               end + 1 < characters.count,
               characters[end] == " ",
               isTokenCharacter(characters[end + 1]) {
                var nextEnd = end + 1
                while nextEnd < characters.count, isTokenCharacter(characters[nextEnd]) {
                    nextEnd += 1
                }
                if String(characters[(end + 1)..<nextEnd]).lowercased()
                    == token.lowercased() {
                    // Keep the first copy — it carries the capitalisation the
                    // speaker's sentence started with — and drop the space and
                    // the second one. A run of three or more is handled by
                    // `tidy`'s fixed-point loop rather than by looking ahead
                    // further here.
                    output.append(contentsOf: characters[index..<end])
                    index = nextEnd
                    continue
                }
            }

            output.append(contentsOf: characters[index..<end])
            index = end
        }
        return output
    }

    private static func isCollapsibleWord(_ token: String) -> Bool {
        guard token.allSatisfy({ $0.isLetter && $0.isASCII }) else { return false }
        return !legitimatelyDoubledWords.contains(token.lowercased())
    }

    // MARK: - 6. Punctuation

    /// ASCII marks that also occur *inside* a token — a decimal point, a
    /// thousands separator, a clock time, a filename, a URL — so widening them
    /// needs positive evidence that this one ends a clause: the character
    /// before it must be CJK-width. Without the guard, 「版本 3.14」 becomes
    /// 「版本 3。14」 and a dictated `e.g.` or `report.pdf` is destroyed.
    private static let tokenInternalMarkWidening: [Character: Character] = [
        ".": "。", ",": "，", ":": "："
    ]

    /// A dot needs the same evidence on its **right**, and only a dot does.
    ///
    /// The left-hand guard alone reads 「打开 报告.pdf」 as a Chinese character
    /// followed by a full stop and produces 「打开报告。pdf。」 — the user's
    /// filename, broken, in the field they were dictating into. A file
    /// extension, a domain (「网易.com」), and a version number are all
    /// "ASCII word character immediately after the dot", and a clause never is:
    /// Chinese text resumes with Han, and English text resumes after a space.
    ///
    /// Only `.` gets this. A colon before a digit is a clock time in ASCII but
    /// an ordinary 「时间：3点」 in Chinese, and that one is much more often the
    /// clause mark, so widening it stays unconditional.
    private static func endsAToken(_ following: Character?) -> Bool {
        guard let following else { return false }
        return following.isASCII && (following.isLetter || following.isNumber)
    }

    /// ASCII marks that only ever end a clause, so the text's own script is
    /// evidence enough.
    private static let sentenceMarkWidening: [Character: Character] = [
        "!": "！", "?": "？", ";": "；"
    ]

    /// The reverse map, unguarded: an English sentence has no business keeping
    /// a stray 。 from a Chinese-biased ASR pass. 、 has no ASCII twin of its
    /// own and narrows to a comma.
    private static let markNarrowing: [Character: Character] = [
        "。": ".", "，": ",", "、": ",", "：": ":", "！": "!", "？": "?", "；": ";"
    ]

    /// A run of dot-like marks is an ellipsis, not repeated punctuation, so
    /// 「Wait... let me check.」 and 「等一下……」 keep their dots. `…` is also
    /// never expanded to `...` or contracted from it — that would rewrite the
    /// user's spelling of the same mark.
    private static let dotLikeMarks: Set<Character> = [".", "。", "…"]

    private static func normalizingPunctuation(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        // The *text's own script* picks the target width. Han only: a lone 。 in
        // an otherwise English sentence is the thing being corrected, so it
        // must not get a vote on which way to correct it.
        let wantsFullWidth = text.contains(where: isHan)
        var characters = convertingMarkWidth(Array(text), toFullWidth: wantsFullWidth)
        characters = collapsingRepeatedMarks(characters)
        return String(endingWithATerminalMark(characters, fullWidth: wantsFullWidth))
    }

    private static func convertingMarkWidth(
        _ characters: [Character],
        toFullWidth: Bool
    ) -> [Character] {
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        for (offset, character) in characters.enumerated() {
            guard toFullWidth else {
                output.append(markNarrowing[character] ?? character)
                continue
            }
            if let wide = sentenceMarkWidening[character] {
                output.append(wide)
            } else if let wide = tokenInternalMarkWidening[character] {
                let previousIsWide = output.last.map(isCjkWidth) ?? false
                let following = offset + 1 < characters.count
                    ? characters[offset + 1]
                    : nil
                let insideAToken = character == "." && endsAToken(following)
                output.append(previousIsWide && !insideAToken ? wide : character)
            } else {
                output.append(character)
            }
        }
        return output
    }

    /// 「真的？？？」 → 「真的？」. Only *identical* marks collapse — "?!" is a
    /// deliberate pairing, not a repetition.
    private static func collapsingRepeatedMarks(_ characters: [Character]) -> [Character] {
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            var end = index
            while end < characters.count, characters[end] == character { end += 1 }
            let length = end - index
            if length >= 2,
               isClauseBoundary(character),
               !dotLikeMarks.contains(character) {
                output.append(character)
            } else {
                output.append(contentsOf: Array(repeating: character, count: length))
            }
            index = end
        }
        return output
    }

    /// Appends the sentence-final mark the text is missing — the only character
    /// this whole file is allowed to *add*.
    ///
    /// A trailing pause mark is replaced rather than followed, because the
    /// sentence ends there: a removed trailing filler leaves 「……开会，」, and
    /// neither that nor 「……开会，。」 is an acceptable thing to paste into
    /// someone's message box.
    private static func endingWithATerminalMark(
        _ characters: [Character],
        fullWidth: Bool
    ) -> [Character] {
        guard let last = characters.last else { return characters }
        if terminalMarks.contains(last) { return characters }
        let terminal: Character = fullWidth ? "。" : "."
        var output = characters
        if pauseMarks.contains(last) {
            output[output.count - 1] = terminal
        } else {
            output.append(terminal)
        }
        return output
    }
}
