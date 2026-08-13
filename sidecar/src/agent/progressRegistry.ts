import type { AgentProgressEvent } from "./loop";

/**
 * In-memory registry of live agent-run progress, backing
 * `GET /agent/progress/:runId` (spec:
 * docs/superpowers/specs/2026-08-13-agent-progress-panel-design.md §2).
 *
 * This is a DISPLAY feed only — a truncated, bounded copy of the loop's
 * progress events for the floating progress panel to poll while a run is in
 * flight. The durable, untruncated step log stays exactly where it was: the
 * blocking `/agent/run` response's `steps` array. Nothing here is persisted;
 * a sidecar restart forgets every run, which is fine for a live feed.
 *
 * Bounds (all enforced here, not by callers):
 * - per-event `detail` is truncated on append to at most
 *   `MAX_DETAIL_CHARS` chars of original content plus a visible
 *   "truncated" marker (total ≤ 450);
 * - at most `MAX_EVENTS_PER_RUN` events are kept per run, dropping the
 *   OLDEST first (keep-newest — the final `done`/`error` event must survive);
 * - at most `MAX_FINISHED_RUNS` finished runs are retained, evicting the
 *   oldest-finished first. Runs still `"running"` are never evicted.
 */

export type AgentProgressRunStatus = "running" | "done" | "failed";
export type AgentProgressStatus = AgentProgressRunStatus | "unknown";

export interface AgentProgressEventSnapshot {
  type: string;
  detail: string;
}

export interface AgentProgressSnapshot {
  status: AgentProgressStatus;
  events: AgentProgressEventSnapshot[];
}

export interface AgentProgressRegistry {
  /** Starts tracking `runId` as `"running"` with no events. */
  register(runId: string): void;
  /**
   * Appends one progress event to a registered run (detail truncated for
   * display). Safe no-op for unknown/evicted ids — it never creates a run.
   */
  append(runId: string, event: AgentProgressEvent): void;
  /**
   * Flips a registered run's status to `"done"`/`"failed"`, keeping its
   * events, and makes it eligible for finished-run eviction. Safe no-op for
   * unknown/evicted ids.
   */
  finish(runId: string, status: "done" | "failed"): void;
  /** Snapshot for display; unknown ids read as `{ status: "unknown", events: [] }`. */
  get(runId: string): AgentProgressSnapshot;
}

const MAX_DETAIL_CHARS = 400;
const TRUNCATION_MARKER = "\n...[truncated]";
const MAX_EVENTS_PER_RUN = 200;
const MAX_FINISHED_RUNS = 20;

function truncateDetail(detail: string): string {
  if (detail.length <= MAX_DETAIL_CHARS) {
    return detail;
  }
  return `${detail.slice(0, MAX_DETAIL_CHARS)}${TRUNCATION_MARKER}`;
}

interface RunEntry {
  status: AgentProgressRunStatus;
  events: AgentProgressEventSnapshot[];
}

export function createAgentProgressRegistry(): AgentProgressRegistry {
  const runs = new Map<string, RunEntry>();
  /** Finished run ids in finish order (oldest first) — the eviction queue. */
  const finishedOrder: string[] = [];

  return {
    register(runId: string): void {
      runs.set(runId, { status: "running", events: [] });
      // A re-registered id is a fresh run again: drop any stale
      // finished-queue membership so it can't be evicted while running.
      const stale = finishedOrder.indexOf(runId);
      if (stale !== -1) {
        finishedOrder.splice(stale, 1);
      }
    },

    append(runId: string, event: AgentProgressEvent): void {
      const entry = runs.get(runId);
      if (!entry) {
        return;
      }
      entry.events.push({ type: event.type, detail: truncateDetail(event.detail) });
      if (entry.events.length > MAX_EVENTS_PER_RUN) {
        entry.events.splice(0, entry.events.length - MAX_EVENTS_PER_RUN);
      }
    },

    finish(runId: string, status: "done" | "failed"): void {
      const entry = runs.get(runId);
      if (!entry) {
        return;
      }
      const wasRunning = entry.status === "running";
      entry.status = status;
      if (!wasRunning) {
        // Already finished (and already queued for eviction) — don't enqueue
        // it a second time.
        return;
      }
      finishedOrder.push(runId);
      while (finishedOrder.length > MAX_FINISHED_RUNS) {
        const evicted = finishedOrder.shift();
        if (evicted !== undefined) {
          runs.delete(evicted);
        }
      }
    },

    get(runId: string): AgentProgressSnapshot {
      const entry = runs.get(runId);
      if (!entry) {
        return { status: "unknown", events: [] };
      }
      return { status: entry.status, events: entry.events.map((event) => ({ ...event })) };
    },
  };
}
