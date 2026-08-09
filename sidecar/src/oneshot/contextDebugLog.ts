import { appendFileSync, mkdirSync } from "node:fs";
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

  return `${now.toISOString()} [${entry.endpoint}] input="${truncate(entry.inputText)}" ${termsSummary}\n`;
}

/** Appends the formatted line via `writer`. */
export function logContextUsage(
  entry: ContextUsageLogEntry,
  writer: ContextUsageLogWriter
): void {
  writer(formatContextUsageLogLine(entry));
}

/**
 * Builds a `ContextUsageLogWriter` that appends to a real file at `path`,
 * creating its parent directory if needed. This is the only place in this
 * module that touches the filesystem — everything above it is pure/testable
 * with an injected writer.
 */
export function createFileContextUsageLogWriter(path: string): ContextUsageLogWriter {
  return (line: string) => {
    mkdirSync(dirname(path), { recursive: true });
    appendFileSync(path, line);
  };
}
