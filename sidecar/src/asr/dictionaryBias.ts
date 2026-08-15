/**
 * Feeds the entity dictionary back into ASR, so remembered terms actually
 * change what comes out of recognition instead of sitting in SQLite unused.
 *
 * Two independent mechanisms live here, both pure so they are testable without
 * a whisper process:
 *  - `buildInitialPrompt` renders the dictionary as an `initial_prompt` for the
 *    local MLX-Whisper decoder (`mlx_whisper.transcribe(..., initial_prompt=...)`),
 *    biasing it toward the right spelling of proper nouns.
 *  - `applyAliasCorrections` deterministically rewrites known alias -> canonical
 *    after the fact, which is the only half a remote whisper provider can get
 *    (it never sees our prompt) and the only half that is guaranteed rather
 *    than probabilistic.
 *
 * **Trust boundary.** Terms written by the `remember_fact` tool carry
 * `origin: "untrusted"` because they arrived through agent context, but that
 * marking exists to gate *LLM prompt* use; ASR biasing is a correction use, not
 * an instruction channel, so terms are filtered by confidence only and never by
 * origin. Filtering by origin here would silently break the main way a user
 * teaches OpenType a name.
 *
 * The real risk in the prompt path is different: Whisper echoes
 * `initial_prompt` text straight into its output when the audio carries no
 * speech. This is not hypothetical -- measured 2026-08-14 against
 * whisper-small-mlx, two seconds of digital silence transcribes as `""` with no
 * prompt and as a garbled echo of the prompt's own terms with one.
 * `MAX_PROMPT_LENGTH` and the canonical-only rule are therefore safety
 * measures, not performance tuning: they bound how much leaks and guarantee
 * that what leaks is at least spelled correctly, whereas aliases (misheard
 * spellings, by definition) leaking through would be exactly the failure this
 * feature exists to prevent.
 *
 * Two things were checked and are worth not re-checking. Real microphone
 * capture does not trigger it -- at a realistic noise floor the prompt does not
 * echo, and Whisper's pre-existing near-silence hallucination ("Thank you.")
 * shows up identically with and without a prompt, so the leak needs genuinely
 * all-zero samples (a muted or dead input device) to appear. And
 * `condition_on_previous_text=False`, the obvious-looking knob, does **not**
 * suppress it: the echo happens inside the first decode window, which the
 * prompt always conditions. A real fix has to drop the segment on its
 * `no_speech_prob`/`avg_logprob`, which means retuning thresholds that also
 * govern quiet speech -- a product call, not a local one.
 */

import type { EntityTerm } from "../memory/MemoryStore";

/** Terms below this are too shaky to steer the decoder with. */
const MIN_CONFIDENCE = 0.6;
/** Whisper's prompt window is ~224 tokens; past that it starts evicting audio context. */
const MAX_PROMPT_LENGTH = 200;
const MAX_PROMPT_TERMS = 24;

/**
 * Reads as a sentence rather than a bare list on purpose: Whisper consumes
 * `initial_prompt` as if it were the *previous* transcript, so natural prose
 * conditions it better than a delimited list would.
 */
const PROMPT_PREFIX = "可能出现的专有名词：";
const PROMPT_SEPARATOR = "、";
const PROMPT_SUFFIX = "。";

/** Aliases shorter than this match too much noise to be worth rewriting. */
const MIN_ALIAS_LENGTH = 2;

export interface BuildInitialPromptOptions {
  /** Confidence floor, inclusive. Defaults to `MIN_CONFIDENCE`. */
  minConfidence?: number;
  /** Hard cap on term count. Defaults to `MAX_PROMPT_TERMS`. */
  maxTerms?: number;
  /** Hard cap on the length of the whole returned string. Defaults to `MAX_PROMPT_LENGTH`. */
  maxLength?: number;
}

/**
 * Renders the confidence-worthy part of the dictionary as a Whisper
 * `initial_prompt`. Only canonical terms go in -- an alias in the prompt would
 * coach the decoder toward the misspelling we are trying to correct.
 *
 * Returns `""` for an empty dictionary (or one where nothing clears the
 * confidence floor); callers must then pass no prompt at all rather than an
 * empty one.
 */
export function buildInitialPrompt(
  terms: EntityTerm[],
  options: BuildInitialPromptOptions = {}
): string {
  const minConfidence = options.minConfidence ?? MIN_CONFIDENCE;
  const maxTerms = options.maxTerms ?? MAX_PROMPT_TERMS;
  const maxLength = options.maxLength ?? MAX_PROMPT_LENGTH;

  const candidates = terms
    .filter((term) => term.confidence >= minConfidence && term.canonicalTerm.length > 0)
    // Confidence first, then recency: a term the owner touched today is more
    // likely to show up in the next utterance than one from months ago.
    .sort((a, b) => b.confidence - a.confidence || b.updatedAt - a.updatedAt)
    .slice(0, maxTerms)
    .map((term) => term.canonicalTerm);

  const included: string[] = [];
  // Grown one whole term at a time so the cap can only ever cut at a term
  // boundary -- a half-written proper noun is worse than none at all, given
  // prompt text can leak into the transcript.
  let length = PROMPT_PREFIX.length + PROMPT_SUFFIX.length;
  for (const canonical of candidates) {
    const cost = canonical.length + (included.length > 0 ? PROMPT_SEPARATOR.length : 0);
    if (length + cost > maxLength) break;
    included.push(canonical);
    length += cost;
  }

  if (included.length === 0) return "";
  return PROMPT_PREFIX + included.join(PROMPT_SEPARATOR) + PROMPT_SUFFIX;
}

export interface AliasReplacement {
  alias: string;
  canonicalTerm: string;
}

export interface AliasCorrectionResult {
  text: string;
  /** In text order, left to right, so a future "auto-corrected N things" UI is deterministic. */
  replacements: AliasReplacement[];
}

/** An alias comes from user speech, so it can contain regex metacharacters. */
function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

const WORD_CHARACTER = /[A-Za-z0-9_]/;

interface AliasPattern {
  alias: string;
  canonicalTerm: string;
  pattern: RegExp;
  /** Carried purely to break ties between two terms claiming the same alias. */
  confidence: number;
  updatedAt: number;
}

/**
 * Total order over alias patterns, evaluated at every scan position.
 *
 * Length first is the rule the spec names: a short alias must not eat the
 * prefix of a longer one. The rest exists because *equal* aliases on different
 * terms are reachable -- the dictionary is written automatically, so correcting
 * 呸泡 -> PayPal once and 呸泡 -> 贝宝 later leaves both terms claiming 呸泡, and
 * exactly one of them gets to win. `allTerms()` is `SELECT * FROM entity_terms`
 * with no `ORDER BY`, so ranking on arrival order would hand that decision to
 * SQLite's row order: the same sentence could transcribe differently after an
 * unrelated write, with nothing in the UI to explain it. Confidence then
 * recency mirrors `buildInitialPrompt`, and the canonical spelling is the final
 * tiebreak so the order is total rather than merely usually-decided.
 */
function compareAliasPatterns(a: AliasPattern, b: AliasPattern): number {
  return (
    b.alias.length - a.alias.length ||
    b.confidence - a.confidence ||
    b.updatedAt - a.updatedAt ||
    (a.canonicalTerm < b.canonicalTerm ? -1 : a.canonicalTerm > b.canonicalTerm ? 1 : 0)
  );
}

/**
 * Builds the sticky matcher for one alias.
 *
 * The word-boundary rule uses JS's own `\b` semantics deliberately. `\b` is
 * defined over `[A-Za-z0-9_]`, which means a CJK neighbour counts as a
 * boundary -- so `用paipal付款`, the *normal* utterance in this
 * Chinese-English mixed product, still matches, while an account handle like
 * `paipal2024` is left alone because a digit is a word character. A
 * Unicode-aware guard such as `(?<![\p{L}\p{N}_])` looks stricter but
 * classifies 用 as a letter and would kill the ASCII-alias path for the most
 * common input we see.
 *
 * The guards are attached per end rather than per alias so a CJK alias (no word
 * characters at either end) falls back to plain substring matching, which is
 * what "word boundary" means for a script that has none.
 */
function buildAliasPattern(alias: string): RegExp {
  const leading = WORD_CHARACTER.test(alias[0]!) ? "\\b" : "";
  const trailing = WORD_CHARACTER.test(alias[alias.length - 1]!) ? "\\b" : "";
  // `y` pins each attempt to the exact scan position; `i` makes ASCII aliases
  // case-insensitive (a no-op for CJK), with the canonical's own casing written
  // back regardless of how it was heard.
  return new RegExp(leading + escapeRegExp(alias) + trailing, "iy");
}

/**
 * Rewrites known aliases to their canonical spelling in a single left-to-right
 * pass. Applies to every transcription path, local or remote.
 *
 * The single pass is load-bearing, not an optimization. The dictionary is
 * written automatically (every accepted correction becomes an alias), so
 * mutually-referencing pairs -- 小蜜 -> 小米 alongside 小米 -> 小蜜 -- occur
 * naturally. Any sequence of `String.replaceAll` collapses that sentence onto
 * one term, and iterating to a fixed point never terminates. Scanning once and
 * never re-reading our own output swaps them correctly and always halts.
 */
export function applyAliasCorrections(
  text: string,
  terms: EntityTerm[]
): AliasCorrectionResult {
  const patterns: AliasPattern[] = [];
  for (const term of terms) {
    if (term.canonicalTerm.length === 0) continue;
    for (const alias of term.aliases) {
      if (alias.length < MIN_ALIAS_LENGTH) continue;
      // Rewriting a term to itself is churn, and would report a replacement
      // the user can't see.
      if (alias.toLowerCase() === term.canonicalTerm.toLowerCase()) continue;
      patterns.push({
        alias,
        canonicalTerm: term.canonicalTerm,
        pattern: buildAliasPattern(alias),
        confidence: term.confidence,
        updatedAt: term.updatedAt,
      });
    }
  }
  if (patterns.length === 0) return { text, replacements: [] };

  patterns.sort(compareAliasPatterns);

  const replacements: AliasReplacement[] = [];
  let out = "";
  let index = 0;
  while (index < text.length) {
    let matched: { pattern: AliasPattern; length: number } | null = null;
    for (const candidate of patterns) {
      candidate.pattern.lastIndex = index;
      const match = candidate.pattern.exec(text);
      if (match) {
        matched = { pattern: candidate, length: match[0].length };
        break;
      }
    }
    if (matched && matched.length > 0) {
      out += matched.pattern.canonicalTerm;
      replacements.push({
        alias: matched.pattern.alias,
        canonicalTerm: matched.pattern.canonicalTerm,
      });
      index += matched.length;
    } else {
      out += text[index];
      index += 1;
    }
  }

  return { text: out, replacements };
}
