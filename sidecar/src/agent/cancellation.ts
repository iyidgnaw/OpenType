/**
 * Cancellation for agent runs (T1 of
 * docs/superpowers/specs/2026-08-13-dsh-borrowings-plan.md §5).
 *
 * Before this, `AbortSignal` appeared zero times under `src/agent`: the Swift
 * side could kill its curl child, but that only orphaned the request -- the
 * sidecar loop kept going, still spending tokens and still executing bash
 * with no sandbox. A misfired voice-triggered agent could not be stopped.
 *
 * Borrowed from dsh's cancellation model, including the two properties that
 * make it trustworthy: one signal threads the whole run (loop, model call,
 * every tool, every subprocess), and the CAUSE is typed rather than inferred
 * from a bare abort.
 */

/** Why an agent run stopped early. */
export type AgentCancelCause = "user" | "budget";

/**
 * Carried as an `AbortSignal`'s reason so the cause survives the boundary.
 *
 * dsh keeps a typed cause for exactly this reason: an abort alone cannot say
 * whether the human changed their mind or the harness gave up, and reporting
 * a budget expiry as "you cancelled this" would be a lie to the user.
 */
export class AgentCancelledError extends Error {
  /** Overrides `Error.cause` deliberately: this IS the cause we care about. */
  readonly cause: AgentCancelCause;

  constructor(cause: AgentCancelCause) {
    super(
      cause === "user"
        ? "The agent run was cancelled."
        : "The agent run exceeded its time budget."
    );
    this.name = "AgentCancelledError";
    this.cause = cause;
  }
}

/** Default wall-clock ceiling for one run: 10 iterations x 60s tools would otherwise block for ~10 minutes. */
export const DEFAULT_RUN_BUDGET_MS = 5 * 60_000;

/**
 * Fuse the caller's cancellation with this run's wall-clock budget.
 *
 * The caller's abort is forwarded verbatim so its cause survives; only a
 * budget expiry mints a `budget` cause. A caller that has already aborted
 * produces an already-aborted signal rather than starting a timer.
 *
 * @param caller - the user-facing cancellation, when there is one.
 * @param budgetMs - wall-clock ceiling for the whole run.
 * @returns one signal that aborts on whichever happens first.
 */
export function runBudgetSignal(
  caller: AbortSignal | undefined,
  budgetMs: number = DEFAULT_RUN_BUDGET_MS
): AbortSignal {
  const controller = new AbortController();

  if (caller?.aborted) {
    controller.abort(caller.reason ?? new AgentCancelledError("user"));
    return controller.signal;
  }

  const timer = setTimeout(() => {
    controller.abort(new AgentCancelledError("budget"));
  }, budgetMs);
  // Never hold the process open for a budget that will be cleared on settle.
  timer.unref?.();

  caller?.addEventListener(
    "abort",
    () => {
      clearTimeout(timer);
      controller.abort(caller.reason ?? new AgentCancelledError("user"));
    },
    { once: true }
  );
  controller.signal.addEventListener("abort", () => clearTimeout(timer), { once: true });

  return controller.signal;
}

/** Process-local map of in-flight runs to their cancellation handles. */
export interface CancellationRegistry {
  /** Start tracking `runId`; returns the signal to thread through its run. */
  register(runId: string): AbortSignal;
  /**
   * Cancel a tracked run.
   * @returns whether there was a live run to cancel. An unknown id is not an
   *   error -- the same "unknown is nothing to show" precedent
   *   `GET /agent/progress/:runId` already set.
   */
  cancel(runId: string): boolean;
  /** Stop tracking a settled run. Safe for unknown ids. */
  release(runId: string): void;
}

/**
 * Create a registry.
 *
 * Deliberately NOT folded into `progressRegistry`: that module's own doc
 * declares it a display feed, and mixing control authority into it would
 * break a boundary it states explicitly.
 */
export function createCancellationRegistry(): CancellationRegistry {
  const controllers = new Map<string, AbortController>();

  return {
    register(runId) {
      const controller = new AbortController();
      controllers.set(runId, controller);
      return controller.signal;
    },
    cancel(runId) {
      const controller = controllers.get(runId);
      if (!controller) {
        return false;
      }
      controllers.delete(runId);
      controller.abort(new AgentCancelledError("user"));
      return true;
    },
    release(runId) {
      controllers.delete(runId);
    },
  };
}
