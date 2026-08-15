import { describe, expect, test } from "bun:test";
import { applyAliasCorrections, buildInitialPrompt } from "../../src/asr/dictionaryBias";
import type { EntityTerm } from "../../src/memory/MemoryStore";

let nextTermId = 1;

/**
 * Mirrors `contextDebugLog.test.ts`'s `makeTerm`, widened to let each test
 * override only the fields it cares about (confidence/updatedAt/origin drive
 * every `buildInitialPrompt` rule).
 */
function makeTerm(overrides: Partial<EntityTerm> & { canonicalTerm: string }): EntityTerm {
  return {
    id: nextTermId++,
    aliases: [],
    category: "term",
    confidence: 0.9,
    origin: "owner",
    sourceEventIds: [],
    createdAt: 0,
    updatedAt: 0,
    supersedes: null,
    ...overrides,
  };
}

// The prompt is fed to Whisper as if it were the *previous* transcript, so it
// has to read as a sentence rather than a bare list. These three constants are
// the stable shape the spec pins (`可能出现的专有名词：PayPal、Anthropic、OpenType。`);
// the tests below assert against them rather than re-spelling the wording.
const PROMPT_PREFIX = "可能出现的专有名词：";
const PROMPT_SEPARATOR = "、";
const PROMPT_SUFFIX = "。";

/** Pulls the canonical terms back out of a built prompt. */
function termsInPrompt(prompt: string): string[] {
  expect(prompt.startsWith(PROMPT_PREFIX)).toBe(true);
  expect(prompt.endsWith(PROMPT_SUFFIX)).toBe(true);
  const body = prompt.slice(PROMPT_PREFIX.length, prompt.length - PROMPT_SUFFIX.length);
  return body.split(PROMPT_SEPARATOR);
}

describe("buildInitialPrompt", () => {
  test("returns an empty string for an empty dictionary", () => {
    expect(buildInitialPrompt([])).toBe("");
  });

  test("renders a natural sentence of canonical terms, not a bare list", () => {
    const prompt = buildInitialPrompt([
      makeTerm({ canonicalTerm: "PayPal", confidence: 0.95 }),
      makeTerm({ canonicalTerm: "Anthropic", confidence: 0.9 }),
      makeTerm({ canonicalTerm: "OpenType", confidence: 0.85 }),
    ]);

    expect(prompt).toBe(
      `${PROMPT_PREFIX}PayPal${PROMPT_SEPARATOR}Anthropic${PROMPT_SEPARATOR}OpenType${PROMPT_SUFFIX}`
    );
  });

  test("includes only canonical terms -- aliases never reach the prompt", () => {
    // Putting the alias in would coach Whisper toward the *wrong* spelling,
    // which is the exact outcome this bias is meant to prevent.
    const prompt = buildInitialPrompt([
      makeTerm({ canonicalTerm: "PayPal", aliases: ["呸泡", "peipal"] }),
    ]);

    expect(prompt).toContain("PayPal");
    expect(prompt).not.toContain("呸泡");
    expect(prompt).not.toContain("peipal");
  });

  test("excludes terms below the 0.6 confidence threshold and includes exactly 0.6", () => {
    const prompt = buildInitialPrompt([
      makeTerm({ canonicalTerm: "TooShaky", confidence: 0.59 }),
      makeTerm({ canonicalTerm: "JustEnough", confidence: 0.6 }),
      makeTerm({ canonicalTerm: "Solid", confidence: 0.95 }),
    ]);

    expect(termsInPrompt(prompt)).toEqual(["Solid", "JustEnough"]);
  });

  test("returns an empty string when every term is below the threshold", () => {
    const prompt = buildInitialPrompt([
      makeTerm({ canonicalTerm: "TooShaky", confidence: 0.1 }),
      makeTerm({ canonicalTerm: "AlsoShaky", confidence: 0.59 }),
    ]);

    expect(prompt).toBe("");
  });

  test("orders by confidence descending, then updatedAt descending", () => {
    const prompt = buildInitialPrompt([
      makeTerm({ canonicalTerm: "OldMedium", confidence: 0.7, updatedAt: 100 }),
      makeTerm({ canonicalTerm: "OldHigh", confidence: 0.9, updatedAt: 50 }),
      makeTerm({ canonicalTerm: "NewMedium", confidence: 0.7, updatedAt: 300 }),
      makeTerm({ canonicalTerm: "NewHigh", confidence: 0.9, updatedAt: 400 }),
    ]);

    expect(termsInPrompt(prompt)).toEqual([
      "NewHigh",
      "OldHigh",
      "NewMedium",
      "OldMedium",
    ]);
  });

  test("caps the prompt at 24 terms", () => {
    // 24 four-character terms stay well inside the 200-character cap, so this
    // isolates the term-count limit from the length limit.
    const terms = Array.from({ length: 30 }, (_, index) =>
      makeTerm({ canonicalTerm: `Tm${String(index).padStart(2, "0")}` })
    );

    const prompt = buildInitialPrompt(terms);

    expect(termsInPrompt(prompt)).toHaveLength(24);
    expect(prompt.length).toBeLessThanOrEqual(200);
  });

  test("caps the prompt at 200 characters, truncating only at a term boundary", () => {
    // 20 x 30-character terms is far past the length cap; whatever survives
    // must be whole terms -- a half-written proper noun in the prompt is worse
    // than no prompt at all, since Whisper is prone to echoing prompt text
    // straight into its output.
    const terms = Array.from({ length: 20 }, (_, index) =>
      makeTerm({ canonicalTerm: `Term${String(index).padStart(2, "0")}${"X".repeat(24)}` })
    );

    const prompt = buildInitialPrompt(terms);

    expect(prompt.length).toBeLessThanOrEqual(200);
    const included = termsInPrompt(prompt);
    const canonicalNames = terms.map((term) => term.canonicalTerm);
    for (const name of included) {
      expect(canonicalNames).toContain(name);
    }
    // The cap actually bit -- otherwise the boundary assertion above is vacuous.
    expect(included.length).toBeLessThan(terms.length);
    expect(included.length).toBeGreaterThan(0);
  });

  test("does NOT filter by origin: an untrusted high-confidence term is still included", () => {
    // Deliberate, per the spec's trust-boundary note: terms written by
    // `remember_fact` carry origin "untrusted" because they came through agent
    // context, but ASR biasing is a *correction* use, not an LLM prompt whose
    // instructions could be hijacked. The safety measures here are the length
    // cap and canonical-only rule, not an origin filter -- so filtering by
    // origin would silently break the main way users teach OpenType a name.
    const prompt = buildInitialPrompt([
      makeTerm({ canonicalTerm: "Zephyrus", origin: "untrusted", confidence: 0.9 }),
    ]);

    expect(termsInPrompt(prompt)).toEqual(["Zephyrus"]);
  });
});

/**
 * `replacements` is asserted in **text order** (left to right), which is what a
 * single left-to-right pass produces naturally. The spec only says the array
 * exists so a future UI can say "auto-corrected N things", but an unordered
 * result would be non-deterministic across dictionary orderings, so the order
 * is pinned here rather than left open.
 */
describe("applyAliasCorrections", () => {
  test("replaces every occurrence of a CJK alias with the canonical term", () => {
    const terms = [makeTerm({ canonicalTerm: "PayPal", aliases: ["呸泡"] })];

    const result = applyAliasCorrections("我用呸泡付款，呸泡很方便", terms);

    expect(result.text).toBe("我用PayPal付款，PayPal很方便");
    expect(result.replacements).toEqual([
      { alias: "呸泡", canonicalTerm: "PayPal" },
      { alias: "呸泡", canonicalTerm: "PayPal" },
    ]);
  });

  test("requires word boundaries for an ASCII alias", () => {
    const terms = [makeTerm({ canonicalTerm: "PayPal", aliases: ["paipal"] })];

    const result = applyAliasCorrections("paipal paipalx xpaipal", terms);

    expect(result.text).toBe("PayPal paipalx xpaipal");
    expect(result.replacements).toEqual([{ alias: "paipal", canonicalTerm: "PayPal" }]);
  });

  test("treats a CJK neighbour as a word boundary, an ASCII/digit neighbour as not", () => {
    // This is the decision that matters most in a Chinese-English mixed
    // dictation product: "用paipal付款" is the *normal* utterance, so an ASCII
    // alias hugged by Chinese characters MUST still match. JS's `\b` gives us
    // that for free (it is defined over [A-Za-z0-9_], so 用/付 are non-word and
    // therefore boundaries). An implementation that "improves" on `\b` with a
    // Unicode-aware guard such as /(?<![\p{L}\p{N}_])…(?![\p{L}\p{N}_])/u would
    // classify 用 as a letter, kill the match, and silently make the whole
    // ASCII-alias path dead for the most common kind of input we have.
    // The other half of the same decision: a digit still counts as a word
    // character, so an account handle like "paipal2024" is left alone.
    const terms = [makeTerm({ canonicalTerm: "PayPal", aliases: ["paipal"] })];

    const result = applyAliasCorrections("用paipal付款，账号是paipal2024", terms);

    expect(result.text).toBe("用PayPal付款，账号是paipal2024");
    expect(result.replacements).toEqual([{ alias: "paipal", canonicalTerm: "PayPal" }]);
  });

  test("matches an alias sitting at the very start and at the very end of the text", () => {
    // A boundary check that peeks at the character *after* a match runs off the
    // end of the string here, and one that peeks *before* a match runs off the
    // front; both edges have to behave as boundaries rather than as word
    // characters. The ASCII alias is deliberately the trailing one, since that
    // is the end `\b` has to synthesize.
    const terms = [makeTerm({ canonicalTerm: "PayPal", aliases: ["呸泡", "paipal"] })];

    const result = applyAliasCorrections("呸泡 和 paipal", terms);

    expect(result.text).toBe("PayPal 和 PayPal");
    expect(result.replacements).toEqual([
      { alias: "呸泡", canonicalTerm: "PayPal" },
      { alias: "paipal", canonicalTerm: "PayPal" },
    ]);
  });

  test("ignores terms that carry no aliases, and never rewrites a canonical term itself", () => {
    const terms = [
      makeTerm({ canonicalTerm: "Anthropic" }),
      makeTerm({ canonicalTerm: "PayPal", aliases: ["呸泡"] }),
    ];

    const result = applyAliasCorrections("Anthropic 和 呸泡", terms);

    expect(result.text).toBe("Anthropic 和 PayPal");
    expect(result.replacements).toEqual([{ alias: "呸泡", canonicalTerm: "PayPal" }]);
  });

  test("matches an ASCII alias case-insensitively and writes the canonical's own casing", () => {
    const terms = [makeTerm({ canonicalTerm: "Anthropic", aliases: ["anthropik"] })];

    const result = applyAliasCorrections("I use Anthropik and ANTHROPIK daily", terms);

    expect(result.text).toBe("I use Anthropic and Anthropic daily");
    expect(result.replacements).toHaveLength(2);
  });

  test("prefers the longer alias when two aliases overlap", () => {
    const terms = [
      makeTerm({ canonicalTerm: "OpenType", aliases: ["开放类型"] }),
      makeTerm({ canonicalTerm: "OpenType Studio", aliases: ["开放类型工作室"] }),
    ];

    const result = applyAliasCorrections("开放类型工作室很好用", terms);

    expect(result.text).toBe("OpenType Studio很好用");
    expect(result.replacements).toEqual([
      { alias: "开放类型工作室", canonicalTerm: "OpenType Studio" },
    ]);
  });

  test("skips aliases shorter than 2 characters", () => {
    const terms = [makeTerm({ canonicalTerm: "Anthropic", aliases: ["A", "阿"] })];

    const result = applyAliasCorrections("A 阿 big day", terms);

    expect(result.text).toBe("A 阿 big day");
    expect(result.replacements).toEqual([]);
  });

  test("skips an alias that equals its canonical term ignoring case", () => {
    const terms = [makeTerm({ canonicalTerm: "PayPal", aliases: ["paypal"] })];

    const result = applyAliasCorrections("paypal is fine", terms);

    expect(result.text).toBe("paypal is fine");
    expect(result.replacements).toEqual([]);
  });

  test("does not re-match text it just wrote (single pass, no cascade)", () => {
    // "欧梯工作室" -> "开放类型工作室" produces text containing the *other* term's
    // alias ("开放类型"). A naive repeated scan would then rewrite it to
    // "OpenType工作室很好" -- and with mutually-referencing terms, loop forever.
    const terms = [
      makeTerm({ canonicalTerm: "开放类型工作室", aliases: ["欧梯工作室"] }),
      makeTerm({ canonicalTerm: "OpenType", aliases: ["开放类型"] }),
    ];

    const result = applyAliasCorrections("欧梯工作室很好", terms);

    expect(result.text).toBe("开放类型工作室很好");
    expect(result.replacements).toEqual([
      { alias: "欧梯工作室", canonicalTerm: "开放类型工作室" },
    ]);
  });

  test("handles a mutually-referencing pair of terms without oscillating", () => {
    // The dictionary is written to automatically by P0-2 (every accepted
    // correction becomes an alias), so a user who once corrected 小蜜 -> 小米
    // and later, in another context, corrected 小米 -> 小蜜 produces exactly
    // this pair. It is the case that separates a real single scan from *any*
    // sequence of `String.replaceAll` calls: every ordering of the two
    // replacements collapses the sentence onto one term ("小蜜和小蜜" or
    // "小米和小米"), and iterating to a fixed point never terminates. Only a
    // single left-to-right pass whose output is not re-scanned swaps them.
    const terms = [
      makeTerm({ canonicalTerm: "小米", aliases: ["小蜜"] }),
      makeTerm({ canonicalTerm: "小蜜", aliases: ["小米"] }),
    ];

    const result = applyAliasCorrections("小蜜和小米", terms);

    expect(result.text).toBe("小米和小蜜");
    expect(result.replacements).toEqual([
      { alias: "小蜜", canonicalTerm: "小米" },
      { alias: "小米", canonicalTerm: "小蜜" },
    ]);
  });

  test("returns the text unchanged with no replacements when nothing matches", () => {
    const terms = [makeTerm({ canonicalTerm: "PayPal", aliases: ["呸泡"] })];

    const result = applyAliasCorrections("今天天气不错", terms);

    expect(result.text).toBe("今天天气不错");
    expect(result.replacements).toEqual([]);
  });

  test("returns the text unchanged when the dictionary is empty", () => {
    const result = applyAliasCorrections("今天天气不错", []);

    expect(result.text).toBe("今天天气不错");
    expect(result.replacements).toEqual([]);
  });
});
