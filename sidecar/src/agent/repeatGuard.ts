/**
 * Advisory loop-breaker for the agent loop (T3 of
 * docs/superpowers/specs/2026-08-13-dsh-borrowings-plan.md §8).
 *
 * The only protection against a degenerate model was the 10-iteration cap: a
 * model re-running the identical grep burned every step and returned "ran out
 * of steps before reaching a final answer". This counts runs of consecutive
 * identical calls and, at configured run lengths, hands back one escalating
 * reminder.
 *
 * Ported from dsh's `repeat-tool-reminder`, whose README documents each of
 * these judgements as the answer to a specific trap; the ones that are not
 * obvious are commented at their implementation below.
 *
 * It is NOT a model-facing tool, it never appears in a tool list, and it
 * never blocks: a legitimately repeated call is delayed by nothing. The
 * decision -- retry differently, gather more evidence, or finish -- stays
 * entirely with the model.
 *
 * MODEL EXPERIENCE: a returned reminder is appended to the conversation as a
 * plugin-sourced user message. See `docs/model-context-inventory.md` §3.7.
 */

/** Consecutive-run lengths that produce a reminder. */
const DEFAULT_THRESHOLDS = [3, 5, 8];

/** Cap on the arguments quoted back in a detailed reminder. */
const DEFAULT_ARGUMENTS_PREVIEW_CHARS = 500;

/** Bookkeeping tools that must not participate in the chain. */
const DEFAULT_EXCLUDE = ["opentype__remember_fact", "opentype__consolidate_memory_now"];

const FIRST_REMINDER =
  "You are repeating the exact same tool call with identical arguments. Carefully analyze the " +
  "previous result before calling again: if the task is not complete, try a different approach " +
  "or different arguments instead of repeating the call.";

export interface RepeatGuardConfig {
  /** Ascending consecutive-run lengths; each must be an integer >= 2. */
  thresholds?: number[];
  /** Tool names transparent to the chain; defaults to the memory tools. */
  exclude?: string[];
  /** Cap on quoted arguments in a detailed reminder; integer >= 1. */
  argumentsPreviewChars?: number;
}

export interface RepeatGuard {
  /**
   * Record one tool call and report whether it warrants a reminder.
   *
   * @param toolName - the tool as the model named it.
   * @param rawArguments - the model's raw arguments JSON, unparsed.
   * @returns reminder text when this call lands exactly on a threshold.
   */
  observe(toolName: string, rawArguments: string): string | undefined;
}

/** Recursively sort object keys so key order cannot make two calls differ. */
function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(canonicalize);
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value as Record<string, unknown>)
        .sort()
        .map((key) => [key, canonicalize((value as Record<string, unknown>)[key])])
    );
  }
  return value;
}

/**
 * The chain key for one call. Unparseable arguments fall back to the raw
 * string rather than throwing: a model emitting the same malformed arguments
 * over and over is exactly the loop worth breaking, so it must still chain.
 */
function chainKey(toolName: string, rawArguments: string): string {
  try {
    return `${toolName}:${JSON.stringify(canonicalize(JSON.parse(rawArguments)))}`;
  } catch {
    return `${toolName}:raw:${rawArguments}`;
  }
}

function validate(config: RepeatGuardConfig): {
  thresholds: number[];
  exclude: Set<string>;
  previewChars: number;
} {
  const thresholds = config.thresholds ?? DEFAULT_THRESHOLDS;
  // Fail loud rather than silently substituting defaults: a typo'd config
  // that quietly disables the guard is worse than having no guard, because it
  // looks configured.
  if (thresholds.length === 0) {
    throw new Error("repeatGuard: thresholds must not be empty");
  }
  for (const threshold of thresholds) {
    if (!Number.isInteger(threshold) || threshold < 2) {
      throw new Error(`repeatGuard: threshold ${threshold} must be an integer >= 2`);
    }
  }
  if (new Set(thresholds).size !== thresholds.length) {
    throw new Error("repeatGuard: thresholds must not contain duplicates");
  }
  const previewChars = config.argumentsPreviewChars ?? DEFAULT_ARGUMENTS_PREVIEW_CHARS;
  if (!Number.isInteger(previewChars) || previewChars < 1) {
    throw new Error("repeatGuard: argumentsPreviewChars must be an integer >= 1");
  }
  return {
    thresholds: [...thresholds].sort((left, right) => left - right),
    exclude: new Set(config.exclude ?? DEFAULT_EXCLUDE),
    previewChars,
  };
}

/**
 * Create one guard. State is per-instance and in memory only: the guard is a
 * heuristic nudge, not a logged invariant, so a resumed conversation starting
 * a fresh chain is an accepted cost rather than a bug.
 *
 * @param config - thresholds, exclusions, and the arguments preview cap.
 * @returns the guard; `observe` is its whole surface.
 * @throws when the configuration is nonsensical.
 */
export function createRepeatGuard(config: RepeatGuardConfig = {}): RepeatGuard {
  const { thresholds, exclude, previewChars } = validate(config);
  let currentKey: string | undefined;
  let count = 0;

  return {
    observe(toolName, rawArguments) {
      // Excluded tools are TRANSPARENT: they neither advance nor reset the
      // chain. Resetting would let a bookkeeping call interleaved into a loop
      // launder it, which is precisely what exclusion must not buy.
      if (exclude.has(toolName)) {
        return undefined;
      }

      const key = chainKey(toolName, rawArguments);
      if (key === currentKey) {
        count += 1;
      } else {
        currentKey = key;
        count = 1;
      }

      if (!thresholds.includes(count)) {
        return undefined;
      }
      if (count === thresholds[0]) {
        return FIRST_REMINDER;
      }

      const canonicalArguments = key.slice(key.indexOf(":") + 1);
      const preview =
        canonicalArguments.length > previewChars
          ? `${canonicalArguments.slice(0, previewChars)}… (+${canonicalArguments.length - previewChars} more chars, truncated)`
          : canonicalArguments;
      return [
        "Repeated tool call detected:",
        `- tool: ${toolName}`,
        `- consecutive_calls: ${count}`,
        `- arguments: ${preview}`,
        "The repeated calls are not making progress. Do not call this tool with these exact " +
          "arguments again. Inspect the latest result and choose a different action, different " +
          "arguments, or finish the task if enough evidence has been gathered.",
      ].join("\n");
    },
  };
}
