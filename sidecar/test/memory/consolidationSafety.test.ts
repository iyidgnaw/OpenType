import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { rollbackRun, runConsolidation, type CallLLM } from "../../src/memory/consolidator";

/**
 * P1-14 (consolidation safety) — STAGE 1 RED tests.
 *
 * These pin the DESIRED corrected design (expected to FAIL against current
 * production code, which runs its multi-statement writes with NO transaction
 * and NO mutex):
 *
 *  (a) runConsolidation's write phase is ATOMIC — a failure partway through
 *      leaves NO partial rows; the pre-existing state is intact.
 *  (b) two overlapping runConsolidation calls are SERIALIZED (a module-level
 *      mutex), so they don't both read the same "before" snapshot and
 *      double-write the same term.
 *  (c) rollbackRun restores prior state ATOMICALLY — an interruption mid
 *      re-insert leaves entity_terms unchanged rather than half-restored.
 *
 * Failure/concurrency is injected deterministically via a spy on
 * `store.db.run` (a per-instance shadow of the method; each test uses a fresh
 * :memory: store so nothing leaks) and a gated `callLLM`.
 */

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
}

function candidatesResponse(candidates: unknown[]): string {
  return JSON.stringify({ candidates });
}

/**
 * Seeds `count` events consolidation may actually read. `"agent"`, not
 * `"transcribe"`: transcribe events are excluded from every pass as a privacy
 * contract (`CONSOLIDATION_EXCLUDED_MODES`), so seeding them here would make
 * these atomicity tests silently exercise an empty event set.
 */
function seedEvents(store: MemoryStore, count: number): number[] {
  const ids: number[] = [];
  for (let i = 0; i < count; i++) {
    ids.push(
      store.recordEpisodicEvent({
        mode: "agent",
        rawTranscript: `raw ${i}`,
        correctedTranscript: `corrected ${i}`,
        effectiveInput: null,
        selectedContext: null,
        result: null,
        applicationName: "TestApp",
      })
    );
  }
  return ids;
}

function insertTerm(store: MemoryStore, canonicalTerm: string): void {
  const now = Date.now();
  store.db.run(
    `INSERT INTO entity_terms
      (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [canonicalTerm, "[]", "term", 0.8, "owner", "[]", now, now, null]
  );
}

/**
 * Replaces store.db.run with a wrapper that throws the first time it sees a
 * statement matching `throwOn`. Returns a restore fn. The original method is
 * invoked via .apply so `this` stays the Database.
 */
function spyThrowOn(
  store: MemoryStore,
  throwOn: (sql: string, callIndexForMatch: number) => boolean
): () => void {
  const original = store.db.run;
  let matchCount = 0;
  (store.db as unknown as { run: unknown }).run = function (this: unknown, sql: unknown, ...rest: unknown[]) {
    if (typeof sql === "string" && throwOn(sql, ++matchCount)) {
      throw new Error("injected mid-write failure");
    }
    return (original as (...a: unknown[]) => unknown).apply(store.db, [sql, ...rest]);
  };
  return () => {
    (store.db as unknown as { run: unknown }).run = original;
  };
}

// ---------------------------------------------------------------------------
// (a) runConsolidation atomicity
// ---------------------------------------------------------------------------

describe("P1-14 (a): runConsolidation writes are atomic", () => {
  test("a failure partway through the write phase persists NO partial rows", async () => {
    const store = makeStore();
    const ids = seedEvents(store, 5);
    insertTerm(store, "Existing"); // pre-existing state that must survive intact

    const callLLM: CallLLM = async () =>
      candidatesResponse([
        {
          canonicalTerm: "Zephyrus",
          aliases: [],
          category: "project",
          confidence: 0.95,
          supportingEventIds: [ids[0]],
        },
      ]);

    // Fail AFTER the entity_terms insert (which happens first) but during the
    // episodic_events consolidatedAt update — a true "partway" injection.
    const restore = spyThrowOn(store, (sql) => sql.includes("UPDATE episodic_events"));
    try {
      await runConsolidation(store, callLLM);
    } catch {
      // Desired impl may rethrow or swallow; either is fine for this assertion.
    } finally {
      restore();
    }

    // The accepted candidate's entity_terms insert must have rolled back:
    // only the pre-existing term remains.
    expect(store.allTerms().map((t) => t.canonicalTerm)).toEqual(["Existing"]);
    // No event may be left marked consolidated.
    expect(store.unconsolidatedEventCount()).toBe(5);
    // No consolidation-run row may have been recorded.
    const runCount = store.db
      .query("SELECT COUNT(*) as c FROM memory_consolidation_runs")
      .get() as { c: number };
    expect(runCount.c).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// (b) mutual exclusion of overlapping runs
// ---------------------------------------------------------------------------

describe("P1-14 (b): overlapping runConsolidation calls are serialized", () => {
  test("two concurrent runs do not double-write the same term", async () => {
    const store = makeStore();
    const ids = seedEvents(store, 5);

    const sameCandidate = {
      canonicalTerm: "Acme",
      aliases: [],
      category: "org" as const,
      confidence: 0.95,
      supportingEventIds: [ids[0]],
    };

    // Gate the FIRST callLLM so the two runs are forced to overlap in time.
    // Without a mutex, both read an empty "before" snapshot and each INSERTs
    // "Acme" -> two rows. With a mutex serializing the whole run, the second
    // sees the first's row and merges -> one row.
    let releaseFirst!: () => void;
    const gate = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    let calls = 0;
    const callLLM: CallLLM = async () => {
      calls += 1;
      if (calls === 1) {
        await gate;
      }
      return candidatesResponse([sameCandidate]);
    };

    const p1 = runConsolidation(store, callLLM);
    const p2 = runConsolidation(store, callLLM);
    releaseFirst();
    await Promise.all([p1, p2]);

    const acme = store.allTerms().filter((t) => t.canonicalTerm === "Acme");
    expect(acme).toHaveLength(1);
  });
});

// ---------------------------------------------------------------------------
// (c) rollbackRun atomicity
// ---------------------------------------------------------------------------

describe("P1-14 (c): rollbackRun restores prior state atomically", () => {
  test("an interruption mid re-insert leaves entity_terms unchanged, run not marked rolled back", () => {
    const store = makeStore();
    const now = Date.now();

    // Current live state that rollback would replace.
    insertTerm(store, "CURRENT-A");
    insertTerm(store, "CURRENT-B");

    // A run whose snapshot restores a DIFFERENT prior state (two rows), so the
    // re-insert loop runs more than once and can be interrupted on the second.
    const snapshot = JSON.stringify([
      {
        id: 10,
        canonicalTerm: "PRIOR-A",
        aliases: "[]",
        category: "term",
        confidence: 0.5,
        origin: "owner",
        sourceEventIds: "[]",
        createdAt: now,
        updatedAt: now,
        supersedes: null,
      },
      {
        id: 11,
        canonicalTerm: "PRIOR-B",
        aliases: "[]",
        category: "term",
        confidence: 0.5,
        origin: "owner",
        sourceEventIds: "[]",
        createdAt: now,
        updatedAt: now,
        supersedes: null,
      },
    ]);
    const runInsert = store.db.run(
      `INSERT INTO memory_consolidation_runs
        (ranAt, eventsConsidered, candidatesProposed, candidatesAccepted, summary, snapshotBeforeJSON, rolledBackAt)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [now, 5, 2, 2, "run", snapshot, null]
    );
    const runId = Number(runInsert.lastInsertRowid);

    expect(store.allTerms().map((t) => t.canonicalTerm).sort()).toEqual([
      "CURRENT-A",
      "CURRENT-B",
    ]);

    // Throw on the SECOND entity_terms re-insert during rollback (after the
    // DELETE and the first re-insert have already run).
    const restore = spyThrowOn(
      store,
      (sql, matchIndex) => /INSERT INTO\s+entity_terms/i.test(sql) && matchIndex === 2
    );
    try {
      rollbackRun(store, runId);
    } catch {
      // Desired impl may rethrow or swallow; either is fine for this assertion.
    } finally {
      restore();
    }

    // Atomic: since rollback couldn't finish, entity_terms must be UNCHANGED
    // (still the CURRENT state) rather than a half-deleted / half-restored mess.
    expect(store.allTerms().map((t) => t.canonicalTerm).sort()).toEqual([
      "CURRENT-A",
      "CURRENT-B",
    ]);
    // The run must NOT be marked rolled back, since the rollback did not commit.
    const runRow = store.db
      .query("SELECT rolledBackAt FROM memory_consolidation_runs WHERE id = ?")
      .get(runId) as { rolledBackAt: number | null };
    expect(runRow.rolledBackAt).toBeNull();
  });
});
