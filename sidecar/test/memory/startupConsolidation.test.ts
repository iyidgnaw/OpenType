/**
 * P1-7 (接): the consolidation gate finally gets a caller.
 *
 * `shouldConsolidate` (`memory/consolidator.ts`) has been correct and fully
 * unit-tested since the memory-v1 batch, and has had **zero callers anywhere**
 * — which means `runConsolidation` has only ever run when a human poked
 * `POST /memory/consolidate` by hand. The entity dictionary therefore never
 * improved on its own, no matter how much dictation piled up.
 *
 * ## The contract stage 3 must implement
 *
 * A new module `src/memory/startupConsolidation.ts`:
 *
 *   export const STARTUP_CONSOLIDATION_DELAY_MS: number;
 *
 *   export type StartupConsolidationOutcome = "ran" | "skipped" | "failed" | "busy";
 *
 *   export interface StartupConsolidationOptions {
 *     delayMs?: number;
 *     // Injected timer. Default: setTimeout(() => { void fn(); }, delayMs).
 *     schedule?: (fn: () => Promise<void>, delayMs: number) => void;
 *     // Default: (store) => shouldConsolidate(store)
 *     shouldRun?: (store: MemoryStore) => boolean;
 *     // Default: (store, callLLM) => runConsolidation(store, callLLM)
 *     run?: (store: MemoryStore, callLLM: CallLLM) => Promise<unknown>;
 *   }
 *
 *   export function maybeRunConsolidation(
 *     store: MemoryStore, callLLM: CallLLM, options?: StartupConsolidationOptions
 *   ): Promise<StartupConsolidationOutcome>;
 *
 *   export function scheduleStartupConsolidation(
 *     store: MemoryStore, callLLM: CallLLM, options?: StartupConsolidationOptions
 *   ): void;
 *
 * and one line in `server.ts`'s `main()` calling
 * `scheduleStartupConsolidation(store, callLLM)` after the server is listening.
 *
 * ### Why this shape
 *
 * `main()` is not exported and never will be testable, so the decision +
 * execution has to live in a seam of its own — the same split
 * `src/lifecycle.ts` already uses (`decideSocketStartup`,
 * `decideReadinessAction`): policy here, `Bun.serve`/`setTimeout` in `main()`.
 * The seam defaults `shouldRun`/`run` to the real `shouldConsolidate` /
 * `runConsolidation`, so `main()`'s call site is a single argument-free line
 * and nothing about the gate is re-implemented here.
 *
 * `schedule` is injected so **no test in this file sleeps**: the fake captures
 * the callback and the test awaits it directly.
 *
 * ### What "ran" does and does not claim
 *
 * `"ran"` means "the gate said yes and consolidation was invoked without
 * throwing". It deliberately does NOT reach inside `ConsolidationResult` to
 * report whether that run aborted on a bad LLM response — the consolidator
 * already owns that semantics (it writes no `memory_consolidation_runs` row on
 * abort, precisely so the next attempt retries the same material). Duplicating
 * that interpretation in the scheduler would give two places to keep in sync.
 *
 * ### Once, not a polling timer
 *
 * The spec is explicit: check once after startup on a delay, no polling. So
 * `schedule` must be called exactly once, and the module must never re-arm
 * itself.
 */
import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import type { CallLLM } from "../../src/memory/consolidator";
import {
  maybeRunConsolidation,
  scheduleStartupConsolidation,
  STARTUP_CONSOLIDATION_DELAY_MS,
} from "../../src/memory/startupConsolidation";

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
}

/**
 * Seeds `count` events the gate is allowed to count and a pass is allowed to
 * read. `"agent"`, not `"transcribe"`: dictation is excluded from
 * consolidation as a privacy contract (`CONSOLIDATION_EXCLUDED_MODES`), so
 * seeding transcribe here would mean these tests asserted a gate that never
 * opens. `seedDictation` below is the deliberate opposite.
 */
function seedEvents(store: MemoryStore, count: number): void {
  for (let i = 0; i < count; i++) {
    store.recordEpisodicEvent({
      mode: "agent",
      rawTranscript: `帮我把这段整理一下 ${i}`,
      correctedTranscript: `帮我把这段整理一下 ${i}`,
      effectiveInput: `帮我把这段整理一下 ${i}`,
      selectedContext: null,
      result: `done ${i}`,
      applicationName: "OpenType Agent",
      origin: "agent",
    });
  }
}

/** Plain dictation: recorded, but never eligible for a consolidation pass. */
function seedDictation(store: MemoryStore, count: number): void {
  for (let i = 0; i < count; i++) {
    store.recordEpisodicEvent({
      mode: "transcribe",
      rawTranscript: `我用呸泡付款 ${i}`,
      correctedTranscript: `我用 PayPal 付款 ${i}`,
      effectiveInput: null,
      selectedContext: null,
      result: null,
      applicationName: "OpenType Transcribe",
    });
  }
}

const unusedCallLLM: CallLLM = async () => {
  throw new Error("callLLM should not have been reached");
};

function deferred<T>(): { promise: Promise<T>; resolve: (value: T) => void; reject: (err: unknown) => void } {
  let resolve!: (value: T) => void;
  let reject!: (err: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

describe("maybeRunConsolidation: the gate decides", () => {
  test("does not run when the gate says no", async () => {
    let runCalls = 0;
    const outcome = await maybeRunConsolidation(makeStore(), unusedCallLLM, {
      shouldRun: () => false,
      run: async () => {
        runCalls++;
      },
    });

    expect(outcome).toBe("skipped");
    expect(runCalls).toBe(0);
  });

  test("runs exactly once when the gate says yes", async () => {
    let runCalls = 0;
    const outcome = await maybeRunConsolidation(makeStore(), unusedCallLLM, {
      shouldRun: () => true,
      run: async () => {
        runCalls++;
      },
    });

    expect(outcome).toBe("ran");
    expect(runCalls).toBe(1);
  });

  test("passes the store and callLLM straight through to the run", async () => {
    const store = makeStore();
    const callLLM: CallLLM = async () => "{}";
    let seen: { store?: MemoryStore; callLLM?: CallLLM } = {};
    await maybeRunConsolidation(store, callLLM, {
      shouldRun: () => true,
      run: async (s, c) => {
        seen = { store: s, callLLM: c };
      },
    });

    expect(seen.store).toBe(store);
    expect(seen.callLLM).toBe(callLLM);
  });

  test("defaults the gate to the real shouldConsolidate: 4 events is not enough", async () => {
    const store = makeStore();
    seedEvents(store, 4);
    let runCalls = 0;

    const outcome = await maybeRunConsolidation(store, unusedCallLLM, {
      run: async () => {
        runCalls++;
      },
    });

    expect(outcome).toBe("skipped");
    expect(runCalls).toBe(0);
  });

  test("defaults the gate to the real shouldConsolidate: 5 events is", async () => {
    const store = makeStore();
    seedEvents(store, 5);
    let runCalls = 0;

    const outcome = await maybeRunConsolidation(store, unusedCallLLM, {
      run: async () => {
        runCalls++;
      },
    });

    expect(outcome).toBe("ran");
    expect(runCalls).toBe(1);
  });

  test("defaults the gate to the real shouldConsolidate: a recent run blocks it", async () => {
    const store = makeStore();
    seedEvents(store, 10);
    store.db.run(
      `INSERT INTO memory_consolidation_runs
        (ranAt, eventsConsidered, candidatesProposed, candidatesAccepted, summary, snapshotBeforeJSON, rolledBackAt)
       VALUES (?, 0, 0, 0, 'earlier today', '[]', NULL)`,
      [Date.now() - 60 * 60 * 1000]
    );
    let runCalls = 0;

    const outcome = await maybeRunConsolidation(store, unusedCallLLM, {
      run: async () => {
        runCalls++;
      },
    });

    expect(outcome).toBe("skipped");
    expect(runCalls).toBe(0);
  });
});

describe("maybeRunConsolidation: the default run really is runConsolidation", () => {
  test("with the gate open, a real consolidation pass happens end to end", async () => {
    const store = makeStore();
    seedEvents(store, 5);
    const callLLM: CallLLM = async () =>
      JSON.stringify({
        candidates: [
          {
            canonicalTerm: "PayPal",
            aliases: ["呸泡"],
            category: "term",
            confidence: 0.95,
            supportingEventIds: [1, 2],
          },
        ],
      });

    const outcome = await maybeRunConsolidation(store, callLLM);

    expect(outcome).toBe("ran");
    // A run row exists...
    expect(store.listConsolidationRuns()).toHaveLength(1);
    // ...the accepted candidate landed in the dictionary...
    expect(store.allTerms().map((t) => t.canonicalTerm)).toEqual(["PayPal"]);
    // ...and the events it considered are no longer unconsolidated, so a
    // second launch-time check would decline.
    expect(store.unconsolidatedEventCount()).toBe(0);
  });

  test("an aborted consolidation is still 'ran' — the consolidator owns abort semantics", async () => {
    const store = makeStore();
    seedEvents(store, 5);
    const callLLM: CallLLM = async () => "not json at all";

    const outcome = await maybeRunConsolidation(store, callLLM);

    expect(outcome).toBe("ran");
    // No run row, so the same material is retried next time — the consolidator's
    // documented behaviour, which the scheduler must not paper over.
    expect(store.listConsolidationRuns()).toEqual([]);
    expect(store.unconsolidatedEventCount()).toBe(5);
  });
});

describe("maybeRunConsolidation: a failure is swallowed, never fatal", () => {
  test("a run that throws synchronously resolves 'failed' instead of rejecting", async () => {
    const outcome = await maybeRunConsolidation(makeStore(), unusedCallLLM, {
      shouldRun: () => true,
      run: () => {
        throw new Error("sqlite is locked");
      },
    });

    expect(outcome).toBe("failed");
  });

  test("a run that rejects resolves 'failed' instead of rejecting", async () => {
    const outcome = await maybeRunConsolidation(makeStore(), unusedCallLLM, {
      shouldRun: () => true,
      run: async () => {
        throw new Error("provider is down");
      },
    });

    expect(outcome).toBe("failed");
  });

  test("a gate that throws is swallowed too, and never reaches the run", async () => {
    // The real gate reads sqlite twice; a corrupt or locked DB throws there,
    // before consolidation is even considered.
    let runCalls = 0;
    const outcome = await maybeRunConsolidation(makeStore(), unusedCallLLM, {
      shouldRun: () => {
        throw new Error("no such table: episodic_events");
      },
      run: async () => {
        runCalls++;
      },
    });

    expect(outcome).toBe("failed");
    expect(runCalls).toBe(0);
  });

  test("a failed attempt does not wedge the seam: a later attempt still runs", async () => {
    const store = makeStore();
    await maybeRunConsolidation(store, unusedCallLLM, {
      shouldRun: () => true,
      run: async () => {
        throw new Error("transient");
      },
    });

    let runCalls = 0;
    const outcome = await maybeRunConsolidation(store, unusedCallLLM, {
      shouldRun: () => true,
      run: async () => {
        runCalls++;
      },
    });

    expect(outcome).toBe("ran");
    expect(runCalls).toBe(1);
  });
});

describe("maybeRunConsolidation: never two at once", () => {
  test("a second call while one is in flight is refused, not queued", async () => {
    const store = makeStore();
    const gate = deferred<void>();
    let runCalls = 0;
    const options = {
      shouldRun: () => true,
      run: async () => {
        runCalls++;
        await gate.promise;
      },
    };

    const first = maybeRunConsolidation(store, unusedCallLLM, options);
    const second = await maybeRunConsolidation(store, unusedCallLLM, options);

    expect(second).toBe("busy");
    // Refused outright: the second call must not consolidate at all, neither now
    // nor after the first finishes. Two passes read the same "before" snapshot
    // of entity_terms and would both propose the same terms.
    expect(runCalls).toBe(1);

    gate.resolve();
    expect(await first).toBe("ran");
    expect(runCalls).toBe(1);
  });

  test("the busy guard clears once the in-flight run settles", async () => {
    const store = makeStore();
    const gate = deferred<void>();
    let runCalls = 0;
    const options = {
      shouldRun: () => true,
      run: async () => {
        runCalls++;
        await gate.promise;
      },
    };

    const first = maybeRunConsolidation(store, unusedCallLLM, options);
    gate.resolve();
    await first;

    const later = await maybeRunConsolidation(store, unusedCallLLM, {
      shouldRun: () => true,
      run: async () => {
        runCalls++;
      },
    });

    expect(later).toBe("ran");
    expect(runCalls).toBe(2);
  });

  test("the busy guard clears even when the in-flight run fails", async () => {
    const store = makeStore();
    const gate = deferred<void>();
    const first = maybeRunConsolidation(store, unusedCallLLM, {
      shouldRun: () => true,
      run: async () => {
        await gate.promise;
      },
    });
    gate.reject(new Error("boom"));
    expect(await first).toBe("failed");

    let runCalls = 0;
    const later = await maybeRunConsolidation(store, unusedCallLLM, {
      shouldRun: () => true,
      run: async () => {
        runCalls++;
      },
    });

    expect(later).toBe("ran");
    expect(runCalls).toBe(1);
  });
});

describe("scheduleStartupConsolidation: once, on a delay, off the startup path", () => {
  test("schedules exactly one check and runs nothing synchronously", () => {
    const calls: number[] = [];
    let runCalls = 0;

    scheduleStartupConsolidation(makeStore(), unusedCallLLM, {
      schedule: (_fn, delayMs) => {
        calls.push(delayMs);
      },
      shouldRun: () => true,
      run: async () => {
        runCalls++;
      },
    });

    expect(calls).toHaveLength(1);
    expect(runCalls).toBe(0);
  });

  test("uses the module's default delay when none is given", () => {
    let seenDelay = -1;
    scheduleStartupConsolidation(makeStore(), unusedCallLLM, {
      schedule: (_fn, delayMs) => {
        seenDelay = delayMs;
      },
      shouldRun: () => false,
    });

    expect(seenDelay).toBe(STARTUP_CONSOLIDATION_DELAY_MS);
  });

  test("an explicit delay overrides the default", () => {
    let seenDelay = -1;
    scheduleStartupConsolidation(makeStore(), unusedCallLLM, {
      delayMs: 1234,
      schedule: (_fn, delayMs) => {
        seenDelay = delayMs;
      },
      shouldRun: () => false,
    });

    expect(seenDelay).toBe(1234);
  });

  test("the default delay is a real delay, but not so long a session misses it", () => {
    // Long enough that a launch-time consolidation never competes with the
    // user's first dictation (MLX-Whisper is still loading its model in those
    // first seconds); short enough that an ordinary working session still gets
    // its one check.
    expect(STARTUP_CONSOLIDATION_DELAY_MS).toBeGreaterThanOrEqual(60_000);
    expect(STARTUP_CONSOLIDATION_DELAY_MS).toBeLessThanOrEqual(30 * 60_000);
  });

  test("when the scheduled callback fires, the gate is consulted and consolidation runs", async () => {
    let fired: (() => Promise<void>) | undefined;
    let runCalls = 0;

    scheduleStartupConsolidation(makeStore(), unusedCallLLM, {
      schedule: (fn) => {
        fired = fn;
      },
      shouldRun: () => true,
      run: async () => {
        runCalls++;
      },
    });

    expect(fired).toBeDefined();
    await fired!();

    expect(runCalls).toBe(1);
  });

  test("the scheduled callback does not re-arm the timer (no polling)", async () => {
    const scheduleCalls: number[] = [];
    let fired: (() => Promise<void>) | undefined;

    scheduleStartupConsolidation(makeStore(), unusedCallLLM, {
      schedule: (fn, delayMs) => {
        scheduleCalls.push(delayMs);
        fired = fn;
      },
      shouldRun: () => true,
      run: async () => {},
    });
    await fired!();

    expect(scheduleCalls).toHaveLength(1);
  });

  test("a failing scheduled check never rejects out of the timer callback", async () => {
    let fired: (() => Promise<void>) | undefined;

    scheduleStartupConsolidation(makeStore(), unusedCallLLM, {
      schedule: (fn) => {
        fired = fn;
      },
      shouldRun: () => true,
      run: async () => {
        throw new Error("sqlite is locked");
      },
    });

    // An unhandled rejection inside a bare setTimeout callback is a crashed
    // sidecar under Bun. It must resolve.
    await expect(fired!()).resolves.toBeUndefined();
  });
});

/**
 * The launch-time half of the privacy contract pinned in
 * `consolidator.test.ts`'s "transcribe events are never consolidated" block.
 *
 * That block proves dictation never reaches the model *within* a pass. This one
 * proves the automatic caller never starts a pass over dictation in the first
 * place — which matters because this is the only model call in the product that
 * happens with no user action at all. If the gate ever counted dictation, a
 * user who only ever dictates would have an LLM call fire on their behalf, on
 * their credit, five minutes after every launch, forever — and send nothing
 * useful, because the pass would then find no eligible events to send.
 *
 * `unusedCallLLM` throws, so "nothing was sent" is enforced rather than merely
 * inspected: any test here that accidentally reaches the provider fails loudly.
 */
describe("dictation never triggers a launch-time pass", () => {
  test("a launch with only dictation recorded runs no pass at all", async () => {
    const store = makeStore();
    seedDictation(store, 20);

    // Real gate, real run function — nothing stubbed out. The only thing
    // standing between 20 events and a live provider call is the mode filter.
    const outcome = await maybeRunConsolidation(store, unusedCallLLM);

    expect(outcome).toBe("skipped");
    expect(store.listConsolidationRuns()).toEqual([]);
  });

  test("dictation alongside eligible events does not inflate the gate", async () => {
    const store = makeStore();
    seedDictation(store, 10);
    // One short of the threshold on its own; ten dictations must not top it up.
    seedEvents(store, 4);

    expect(await maybeRunConsolidation(store, unusedCallLLM)).toBe("skipped");

    // The fifth eligible event is what opens it — not the eleventh dictation.
    seedEvents(store, 1);
    let sent = 0;
    const outcome = await maybeRunConsolidation(store, async () => {
      sent++;
      return JSON.stringify({ candidates: [] });
    });

    expect(outcome).toBe("ran");
    expect(sent).toBe(1);
  });

  test("leftover dictation does not make the next launch fire on nothing", async () => {
    const store = makeStore();
    seedDictation(store, 30);
    seedEvents(store, 5);

    // Launch one: consumes the eligible events, leaves all 30 dictations.
    expect(
      await maybeRunConsolidation(store, async () => JSON.stringify({ candidates: [] }))
    ).toBe("ran");
    expect(store.unconsolidatedEventCount()).toBe(30);

    // Move the run well past the 12-hour window so the timer is no longer what
    // is holding the gate shut — otherwise this test would pass for the wrong
    // reason and stop protecting anything.
    store.db.run("UPDATE memory_consolidation_runs SET ranAt = ?", [
      Date.now() - 13 * 60 * 60 * 1000,
    ]);

    // Launch two: 30 rows are still unconsolidated, but none are eligible, so
    // the gate stays shut and `unusedCallLLM` is never reached.
    expect(await maybeRunConsolidation(store, unusedCallLLM)).toBe("skipped");
    expect(store.listConsolidationRuns()).toHaveLength(1);
  });

  test("the scheduled callback is subject to the same exclusion", async () => {
    const store = makeStore();
    seedDictation(store, 20);
    let fired: (() => Promise<void>) | undefined;
    // Counted rather than merely throwing: an aborted run leaves no
    // `memory_consolidation_runs` row either, so asserting on the run log alone
    // could not tell "the gate refused" apart from "a pass started, shipped
    // these transcripts to the provider, and then failed". The number that has
    // to be zero is the number of times the provider was called.
    let providerCalls = 0;
    const countingCallLLM: CallLLM = async () => {
      providerCalls++;
      throw new Error("callLLM should not have been reached");
    };

    // Drives the real armed callback rather than calling maybeRunConsolidation
    // directly, so the wiring `main()` uses is covered too.
    scheduleStartupConsolidation(store, countingCallLLM, {
      schedule: (fn) => {
        fired = fn;
      },
    });
    await fired!();

    expect(providerCalls).toBe(0);
    expect(store.listConsolidationRuns()).toEqual([]);
  });
});
