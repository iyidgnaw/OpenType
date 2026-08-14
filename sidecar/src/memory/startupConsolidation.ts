import { runConsolidation, shouldConsolidate, type CallLLM } from "./consolidator";
import type { MemoryStore } from "./MemoryStore";

/**
 * P1-7 (接): `shouldConsolidate` has been correct and fully unit-tested since
 * the memory-v1 batch and has had zero callers, so the only way a consolidation
 * pass ever ran was a human poking `POST /memory/consolidate`. This module is
 * the caller: one check, once, a while after startup.
 *
 * The policy lives here rather than in `server.ts`'s `main()` because `main()`
 * is not exported and never will be testable -- the same split `lifecycle.ts`
 * already uses (`decideSocketStartup`, `decideReadinessAction`): decisions in a
 * seam, `Bun.serve`/`setTimeout` in `main()`.
 */

/**
 * Long enough that a launch-time consolidation never competes with the user's
 * first dictation (MLX-Whisper is still loading its model in those first
 * seconds, and consolidation talks to the same LLM provider Ask/Agent do);
 * short enough that an ordinary working session still gets its one check.
 */
export const STARTUP_CONSOLIDATION_DELAY_MS = 5 * 60_000;

export type StartupConsolidationOutcome = "ran" | "skipped" | "failed" | "busy";

export interface StartupConsolidationOptions {
  /** Defaults to `STARTUP_CONSOLIDATION_DELAY_MS`. */
  delayMs?: number;
  /** Injected timer, so tests drive the callback directly instead of sleeping. */
  schedule?: (fn: () => Promise<void>, delayMs: number) => void;
  /** Defaults to the real `shouldConsolidate` gate. */
  shouldRun?: (store: MemoryStore) => boolean;
  /** Defaults to the real `runConsolidation`. */
  run?: (store: MemoryStore, callLLM: CallLLM) => Promise<unknown>;
}

/**
 * One-at-a-time guard. Two passes would each read the same "before" snapshot of
 * `entity_terms` and both propose the same terms; a second caller is refused
 * outright rather than queued, because by the time the first finishes its
 * material is already consolidated and the second has nothing left to do.
 * (`runConsolidation` has its own mutex for the same reason — this one keeps
 * the *decision* from being taken twice, not just the write.)
 */
let inFlight = false;

/**
 * Consults the gate and, if it opens, runs one consolidation pass. Never
 * rejects: a launch-time nicety must not be able to take the sidecar down, so
 * a throwing gate or a throwing run both resolve `"failed"`.
 *
 * `"ran"` means "the gate said yes and consolidation was invoked without
 * throwing". It deliberately does not reach into `ConsolidationResult` to
 * report whether that run aborted on a bad LLM response — the consolidator
 * already owns that semantics (it writes no run row on abort, precisely so the
 * next attempt retries the same material), and duplicating the interpretation
 * here would give two places to keep in sync.
 */
export async function maybeRunConsolidation(
  store: MemoryStore,
  callLLM: CallLLM,
  options: StartupConsolidationOptions = {}
): Promise<StartupConsolidationOutcome> {
  if (inFlight) {
    return "busy";
  }
  inFlight = true;
  try {
    const gate = options.shouldRun ?? shouldConsolidate;
    if (!gate(store)) {
      return "skipped";
    }
    const run = options.run ?? runConsolidation;
    await run(store, callLLM);
    return "ran";
  } catch (err) {
    console.error("[memory/startupConsolidation] launch-time consolidation failed.", err);
    return "failed";
  } finally {
    inFlight = false;
  }
}

function defaultSchedule(fn: () => Promise<void>, delayMs: number): void {
  setTimeout(() => {
    void fn();
  }, delayMs);
}

/**
 * Arms the single post-startup check. Returns immediately — nothing runs on the
 * startup path — and never re-arms itself: the spec is one check per launch,
 * not a polling timer.
 */
export function scheduleStartupConsolidation(
  store: MemoryStore,
  callLLM: CallLLM,
  options: StartupConsolidationOptions = {}
): void {
  const schedule = options.schedule ?? defaultSchedule;
  schedule(async () => {
    await maybeRunConsolidation(store, callLLM, options);
  }, options.delayMs ?? STARTUP_CONSOLIDATION_DELAY_MS);
}
