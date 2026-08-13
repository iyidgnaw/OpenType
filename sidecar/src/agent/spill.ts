/**
 * Oversized tool results go to disk instead of into the bin (T2 of
 * docs/superpowers/specs/2026-08-13-dsh-borrowings-plan.md §7).
 *
 * The previous behavior truncated and discarded: the model was told its
 * result was cut off and given no way at all to reach the rest. Spilling
 * keeps the full text and hands back a preview plus a path -- and the
 * retrieval path already exists, because `opentype__read_file` and
 * `opentype__grep` are in the agent's own toolset.
 *
 * Borrowed from dsh's spill seam, including its two load-bearing rules:
 * the locator is accompanied by an explicit retrieval hint (the model should
 * not have to infer what a path affords), and saving is BEST-EFFORT -- a
 * storage failure keeps the inline (truncated) result rather than turning a
 * successful tool call into an error.
 *
 * MODEL EXPERIENCE: `renderSpilledResult`'s output reaches the model as the
 * tool result. See `docs/model-context-inventory.md` §3.6.
 */
import { mkdir, open } from "node:fs/promises";
import { join, resolve } from "node:path";

/**
 * Pure size cap for a tool result. Returns `text` unchanged when it already
 * fits within `maxLen`; otherwise truncates to `maxLen` and appends a short
 * marker (so the total stays close to `maxLen`) carrying a visible truncation
 * indicator, so the model can tell content was cut rather than silently
 * receiving a partial blob.
 *
 * Lives here rather than in `loop.ts` so that module can depend on this one
 * without a cycle: truncation is now the FALLBACK of the spill path, not an
 * independent policy.
 */
export function clampToolResult(text: string, maxLen: number): string {
  if (text.length <= maxLen) {
    return text;
  }
  return `${text.slice(0, maxLen)}\n...[truncated]`;
}

/** Head and tail retained inline; enough to see shape without paying for size. */
const PREVIEW_HEAD_CHARS = 2_000;
const PREVIEW_TAIL_CHARS = 1_000;

/** Bucket for artifacts produced outside a tracked run. */
const UNTRACKED_RUN_BUCKET = "untracked";

/** Which tool produced the artifact, and under which run to file it. */
export interface SpillSource {
  toolName: string;
  /** Groups artifacts per agent run; absent files them under a shared bucket. */
  runId?: string;
}

/**
 * Reduce caller-supplied text to one safe path segment.
 *
 * Applied to BOTH the tool name and the run id, because both cross into a
 * filesystem path and neither is validated anywhere upstream: a tool name
 * arrives from a merged tool set that includes user-configured MCP servers.
 *
 * The allowlist excludes `.` entirely. Dots without separators cannot
 * traverse, so this is not the escape defense -- collapsing every separator
 * to `_` is. It is so a hostile name cannot leave a `..` sitting in a path an
 * operator later reads, greps, or pastes into a command. The `.txt` extension
 * is appended by this module, so a caller's dots buy nothing.
 */
function safeSegment(raw: string): string {
  const cleaned = raw.replace(/[^A-Za-z0-9_-]/g, "_");
  return cleaned.length > 0 ? cleaned.slice(0, 64) : "unnamed";
}

/**
 * Persist `text` under `root`, returning the artifact path, or `null` when it
 * could not be stored.
 *
 * `null` rather than a rejection is the contract: every caller's correct
 * response to a storage failure is to keep the inline result, so making it an
 * exception would push identical try/catch into each of them.
 *
 * @param text - the full text to keep.
 * @param source - producing tool and run, used only for naming and grouping.
 * @param root - spill root directory; created (0700) if absent.
 * @returns the artifact's absolute path, or `null` on any storage failure.
 */
export async function saveSpill(
  text: string,
  source: SpillSource,
  root: string
): Promise<string | null> {
  const directory = join(resolve(root), safeSegment(source.runId ?? UNTRACKED_RUN_BUCKET));
  const name = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}-${safeSegment(source.toolName)}.txt`;
  const path = join(directory, name);

  try {
    await mkdir(directory, { recursive: true, mode: 0o700 });
    // Exclusive create ('wx'), owner-only: a pre-planted symlink at this path
    // cannot redirect the write, and a name collision fails instead of
    // silently overwriting another result.
    const handle = await open(path, "wx", 0o600);
    try {
      await handle.writeFile(text, "utf8");
    } finally {
      await handle.close();
    }
    return path;
  } catch {
    // Deliberately silent: the caller degrades to an inline truncated result,
    // and a failure to store a debugging convenience must not surface to the
    // model as if the tool itself had failed.
    return null;
  }
}

/**
 * The model-facing replacement for a spilled result: head, an accounting
 * line, tail, and an explicit retrieval instruction naming real tools.
 *
 * @param text - the complete original text.
 * @param path - the artifact locator returned by {@link saveSpill}.
 * @returns the inline text to hand the model.
 */
export function renderSpilledResult(text: string, path: string): string {
  const head = text.slice(0, PREVIEW_HEAD_CHARS);
  const tail = text.slice(-PREVIEW_TAIL_CHARS);
  return [
    head,
    `\n...[${text.length} chars total; full output saved to ${path}]...\n`,
    tail,
    `\nUse opentype__read_file or opentype__grep on ${path} to read the rest.`,
  ].join("");
}

/** Options for {@link spillOrClamp}. */
export interface SpillOrClampOptions {
  /** Inline budget; a result at or under this passes through untouched. */
  maxInline: number;
  /** Storage attempt; omitted or failing degrades to truncation. */
  save?: () => Promise<string | null>;
}

/**
 * Bound one tool result for the model, preferring a retrievable artifact over
 * a discarded tail.
 *
 * @param text - the tool's full output.
 * @param options - inline budget and the optional storage attempt.
 * @returns the text to hand the model; never rejects.
 */
export async function spillOrClamp(
  text: string,
  options: SpillOrClampOptions
): Promise<string> {
  if (text.length <= options.maxInline) {
    return text;
  }
  if (options.save) {
    try {
      const path = await options.save();
      if (path !== null) {
        return renderSpilledResult(text, path);
      }
    } catch {
      // Same reasoning as saveSpill's catch: fall through to truncation.
    }
  }
  return clampToolResult(text, options.maxInline);
}
