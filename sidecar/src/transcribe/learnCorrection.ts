/**
 * Gate in front of "a Review-mode voice correction becomes an `entity_terms`
 * alias" (P0-2).
 *
 * `/transcribe/correct` is used for two quite different things: fixing a
 * mis-transcribed *term* ("呸泡" -> "PayPal"), which is exactly the pair the
 * dictionary wants to learn, and rewriting a span of prose ("rewrite this
 * more formally"), which would poison the dictionary if learned. Nothing in
 * the request distinguishes them, so this decides after the fact, from the
 * shape of the two strings alone -- deliberately a pure function so every
 * rule is testable without a router, a model, or a database.
 *
 * It is conservative on purpose: a false negative only means the user has to
 * correct the same word twice, while a false positive silently rewrites the
 * user's future transcripts.
 */

/** Longest span still plausibly a *term* rather than a rewritten phrase. */
const MAX_TERM_LENGTH = 24;

/**
 * Characters that carry no lexical content on their own: punctuation (both
 * ASCII "..." / "---" and CJK "。。。" / "！！！"), symbols, and whitespace. A
 * side made up entirely of these is not a term.
 */
const NON_LEXICAL = /^[\p{P}\p{S}\s]*$/u;

function isNonLexical(value: string): boolean {
  return NON_LEXICAL.test(value);
}

/**
 * Whether the pair `(selectedText -> replacement)` should be learned as
 * `alias -> canonicalTerm`. Both sides are compared trimmed, since the
 * selection came from a user drag and can carry stray whitespace.
 */
export function shouldLearnCorrection(
  selectedText: string,
  replacement: string
): boolean {
  const alias = selectedText.trim();
  const canonical = replacement.trim();

  // Empty (or whitespace-only) on either side: nothing to map.
  if (alias.length === 0 || canonical.length === 0) {
    return false;
  }

  // Not a correction at all, or a pure case fix -- ASR casing differences are
  // noise, and an alias that differs from its canonical only in case would
  // never match anything the canonical doesn't already match.
  if (alias.toLowerCase() === canonical.toLowerCase()) {
    return false;
  }

  // A long span is a rewritten phrase, not a term. The boundary is inclusive.
  if (alias.length > MAX_TERM_LENGTH || canonical.length > MAX_TERM_LENGTH) {
    return false;
  }

  // A multi-line replacement is a restructured block of text, never a term.
  if (canonical.includes("\n")) {
    return false;
  }

  // An expansion, not an alias: learning "PayPal" -> "PayPal 转账" would teach
  // the dictionary to expand every future "PayPal".
  if (canonical.toLowerCase().includes(alias.toLowerCase())) {
    return false;
  }

  if (isNonLexical(alias) || isNonLexical(canonical)) {
    return false;
  }

  return true;
}
