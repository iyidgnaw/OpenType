import {
  appendFileSync,
  chmodSync,
  mkdirSync,
  renameSync,
  statSync,
  unlinkSync,
} from "node:fs";
import { dirname } from "node:path";
import type { EntityTerm } from "../memory/MemoryStore";

/**
 * Product-owner-visible proof that stored context is actually fetched and
 * injected into the Ask/Agent calls, not just architecturally present. A
 * GUI-launched macOS app's stdout isn't visible anywhere normal (see the
 * git history around "Fix two bugs that made the packaged app never
 * actually work" for why file-based logging, not console output, is the
 * only reliable way to observe a launched app's sidecar), so this appends a
 * human-readable line to a persistent log file on every request that goes
 * through `buildKnownTermsContext`.
 */

export interface ContextUsageLogEntry {
  /** Which sidecar endpoint ran the lookup. */
  endpoint: "ask" | "agent";
  /** The input text the lookup was run against (question or task). */
  inputText: string;
  /** The entity terms `findKnownTerms` matched, in match order. */
  matchedTerms: EntityTerm[];
  /**
   * How many `owner_facts` rows (`memory/MemoryStore.ts`'s
   * `allOwnerFacts()`) were included in this request's context, per
   * `oneshot/memoryContext.ts`'s `buildOwnerFactsContext` -- all of them are
   * always included (see that function's doc comment), so this is really
   * just `allOwnerFacts().length` at request time, logged the same way
   * entity-term matches already are so owner-fact injection is provable
   * from this log, not just trusted.
   */
  ownerFactsCount: number;
}

/** Injectable sink for a single formatted log line — the DI seam that keeps
 * `logContextUsage` unit-testable without touching the real filesystem, the
 * same pattern already used throughout this codebase (e.g. `MemoryStore`
 * taking an injected `Database`, `SidecarClient.swift`'s env-var-driven
 * paths). */
export type ContextUsageLogWriter = (line: string) => void;

const MAX_LOGGED_INPUT_LENGTH = 200;

function truncate(text: string): string {
  const normalized = text.replace(/\s+/g, " ").trim();
  return normalized.length > MAX_LOGGED_INPUT_LENGTH
    ? `${normalized.slice(0, MAX_LOGGED_INPUT_LENGTH)}…`
    : normalized;
}

/**
 * Formats one log line. Pure/exported separately from `logContextUsage` so
 * the exact line shape is directly unit-testable without needing a writer
 * or the filesystem at all.
 */
export function formatContextUsageLogLine(
  entry: ContextUsageLogEntry,
  now: Date = new Date()
): string {
  const termsSummary =
    entry.matchedTerms.length > 0
      ? `${entry.matchedTerms.length} known term(s): ${entry.matchedTerms
          .map((term) => term.canonicalTerm)
          .join(", ")}`
      : "no context matched";

  const ownerFactsSummary =
    entry.ownerFactsCount > 0
      ? `${entry.ownerFactsCount} owner fact(s) included`
      : "no owner facts";

  return `${now.toISOString()} [${entry.endpoint}] input="${truncate(entry.inputText)}" ${termsSummary}; ${ownerFactsSummary}\n`;
}

/** Appends the formatted line via `writer`. */
export function logContextUsage(
  entry: ContextUsageLogEntry,
  writer: ContextUsageLogWriter
): void {
  writer(formatContextUsageLogLine(entry));
}

/**
 * Rotation cap, in bytes. Chosen for a human-readable *debug* log, not a
 * durable record: at this format's typical line length (a timestamp, mode
 * tag, ~200-char truncated input, and a one-line term/fact summary --
 * roughly 250-350 bytes/line) 5 MB holds on the order of 15,000-20,000
 * requests, which is comfortably more than a single debugging session needs
 * while still bounding the file to something a text editor opens instantly.
 * Combined with the single retained `.1` generation below, total on-disk
 * footprint for this log is capped at ~2x this constant.
 */
export const CONTEXT_LOG_MAX_BYTES = 5 * 1024 * 1024;

/**
 * Builds a `ContextUsageLogWriter` that appends to a real file at `path`,
 * creating its parent directory if needed. This is the only place in this
 * module that touches the filesystem — everything above it is pure/testable
 * with an injected writer.
 *
 * Also owns this log's governance, since nothing else in the codebase does
 * (docs/superpowers/specs/2026-08-09-current-system-state.md §11): every
 * call
 *  - rotates the file to `<path>.1` (replacing any prior `.1`, so exactly
 *    one generation is ever retained) once it has reached
 *    `CONTEXT_LOG_MAX_BYTES`, before writing the new line into a fresh file;
 *  - ensures both the active file and, when written this call, the rotated
 *    file end up mode 0600 -- tightening a pre-existing world-readable file
 *    left over from before this fix, not just files this writer creates.
 */
export function createFileContextUsageLogWriter(path: string): ContextUsageLogWriter {
  const rotatedPath = `${path}.1`;
  return (line: string) => {
    mkdirSync(dirname(path), { recursive: true });

    // Stat freshly on every call rather than tracking size in a closure
    // variable. `clearContextUsageLog` -- and the `DELETE /memory/context-log`
    // route built on it -- can delete this file out from under a writer
    // instance that stays alive across many calls (the whole point of that
    // route is "reset input history" clearing a log the sidecar process
    // never restarts for), so a size cached at construction or update time
    // would drift from what is actually on disk: it could fail to rotate a
    // file that grew some other way, or, worse, spuriously rotate a tiny
    // freshly-cleared file because the cached count still remembered being
    // near the cap. One `statSync` answers both the rotation check and the
    // permission check below, so there's no need for a second syscall to
    // re-derive mode separately.
    let currentSize = 0;
    let currentMode: number | null = null;
    try {
      const stat = statSync(path);
      currentSize = stat.size;
      currentMode = stat.mode & 0o777;
    } catch {
      currentSize = 0; // no file yet (first write, or written out from under us)
      currentMode = null;
    }

    if (currentSize >= CONTEXT_LOG_MAX_BYTES) {
      // Whole-file rotation, not append-then-trim: renameSync overwrites an
      // existing destination on POSIX, so this alone keeps exactly one
      // retained generation no matter how many rotations have already
      // happened -- there is never a `.2`.
      renameSync(path, rotatedPath);
      chmodSync(rotatedPath, 0o600);
      // The live path no longer exists post-rotation -- the append below
      // creates it fresh, so there's nothing left to chmod against.
      currentMode = null;
    }

    // `mode` here only takes effect when this call is the one creating the
    // file; an existing file (left over from before this fix, or simply
    // continuing across earlier append calls) keeps whatever permissions it
    // already had.
    appendFileSync(path, line, { mode: 0o600 });
    // 0600 has no group or other bits, so umask can never widen it back --
    // a file `appendFileSync` itself just created (no prior file, or the
    // fresh file right after a rotation) is already exactly 0600. The only
    // case left needing a chmod is a file that existed before this call
    // with looser permissions (e.g. a log left over from before this
    // governance fix shipped, still 0644), which `currentMode` already
    // told us about for free -- so only pay for the syscall then.
    if (currentMode !== null && currentMode !== 0o600) {
      chmodSync(path, 0o600);
    }
  };
}

/**
 * Deletes the context-debug log and its rotated generation, idempotently.
 * The primitive behind `DELETE /memory/context-log` (`memory/routes.ts`),
 * which `AppModel.resetHistory()` (`Sources/OpenType/AppModel.swift`) calls
 * so 「重置输入历史」 actually clears this log instead of leaving it as the one
 * thing a reset doesn't touch. A caller that only checked "does the main
 * file exist" would leave the `.1` generation behind, still readable, so
 * this always attempts both paths.
 */
export function clearContextUsageLog(path: string): void {
  for (const candidate of [path, `${path}.1`]) {
    try {
      unlinkSync(candidate);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        throw error;
      }
      // Absent is the expected steady state after a clear (or before the
      // log has ever been written) -- a no-op, not a failure.
    }
  }
}
