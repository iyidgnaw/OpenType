/**
 * Durable per-run step log (T7 of
 * docs/superpowers/specs/2026-08-13-dsh-borrowings-plan.md §11).
 *
 * Steps used to exist only as two parallel in-memory representations -- the
 * `/agent/run` response's `steps` and the display registry's bounded copy --
 * and neither survived a sidecar restart. For a product that runs shell
 * commands with no sandbox and no pre-execution confirmation, being able to
 * see afterwards what an agent actually did is close to a required
 * compensating control.
 *
 * Borrowed from dsh's "one durable stream, many projections" rule. Ownership
 * differs deliberately: dsh keeps its log with the session, and here the log
 * belongs to the SIDECAR rather than Swift's `ImmutableAuditStore`, because
 * that store is per-REQUEST while steps happen inside the sidecar. Shipping
 * every step across the Unix socket purely to persist it would invert the
 * cost. Swift's request-level audit is untouched.
 *
 * MODEL EXPERIENCE: nothing here reaches a model request; this records what
 * already happened.
 */
import { appendFile, mkdir, readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import type { AgentProgressEvent } from "./loop";

/** One durable record. `detail` is the FULL text, unlike the display feed. */
export interface RunLogEntry {
  runId: string;
  /** Zero-based position within this run, assigned on append. */
  seq: number;
  /** Unix epoch milliseconds. */
  time: number;
  type: string;
  detail: string;
}

export interface RunLog {
  /**
   * Record one event. Never rejects: failing to write a step must not fail
   * the run that produced it (the same best-effort stance as spill).
   */
  append(runId: string, event: AgentProgressEvent): Promise<void>;
}

/** Flatten caller text to one safe path segment; see `spill.ts` for the rationale. */
function safeSegment(raw: string): string {
  const cleaned = raw.replace(/[^A-Za-z0-9_-]/g, "_");
  return cleaned.length > 0 ? cleaned.slice(0, 64) : "unnamed";
}

function fileFor(root: string, runId: string): string {
  return join(resolve(root), `${safeSegment(runId)}.jsonl`);
}

/**
 * Open a log rooted at `root`.
 *
 * Sequence numbers are per-process and per-run: appends for one run are
 * ordered by the counter rather than by write completion, so a burst of
 * concurrent appends cannot interleave into a misleading order.
 *
 * @param root - directory for `<runId>.jsonl` files; created 0700 on demand.
 */
export function createRunLog(root: string): RunLog {
  const nextSeq = new Map<string, number>();

  return {
    async append(runId, event) {
      const seq = nextSeq.get(runId) ?? 0;
      nextSeq.set(runId, seq + 1);
      const entry: RunLogEntry = {
        runId,
        seq,
        time: Date.now(),
        type: event.type,
        detail: event.detail,
      };
      try {
        await mkdir(resolve(root), { recursive: true, mode: 0o700 });
        // JSON.stringify escapes newlines, which is what keeps the
        // one-record-per-line invariant true for tool output.
        await appendFile(fileFor(root, runId), `${JSON.stringify(entry)}\n`, {
          encoding: "utf8",
          mode: 0o600,
        });
      } catch {
        // Deliberately silent: an audit convenience must never take down the
        // run it is recording.
      }
    },
  };
}

/**
 * Read one run's durable log.
 *
 * @returns the entries in append order; an unknown run reads as empty rather
 *   than throwing, matching how an unknown run id is treated everywhere else.
 */
export async function readRunLog(root: string, runId: string): Promise<RunLogEntry[]> {
  const raw = await readFile(fileFor(root, runId), "utf8").catch(() => "");
  return raw
    .split("\n")
    .filter((line) => line.length > 0)
    .flatMap((line) => {
      try {
        return [JSON.parse(line) as RunLogEntry];
      } catch {
        // A torn final line (killed mid-append) must not hide the records
        // that were written completely.
        return [];
      }
    });
}
