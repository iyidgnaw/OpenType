import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore, type EntityTerm } from "../../src/memory/MemoryStore";
import {
  rollbackRun,
  runConsolidation,
  shouldConsolidate,
  upsertEntityTerm,
} from "../../src/memory/consolidator";

function makeStore() {
  const db = openDatabase(":memory:");
  return new MemoryStore(db);
}

function seedEvents(store: MemoryStore, count: number): number[] {
  const ids: number[] = [];
  for (let i = 0; i < count; i++) {
    ids.push(
      store.recordEpisodicEvent({
        mode: "transcribe",
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

function candidatesResponse(candidates: unknown[]): string {
  return JSON.stringify({ candidates });
}

describe("shouldConsolidate", () => {
  test("false when there are no unconsolidated events at all", () => {
    const store = makeStore();
    expect(shouldConsolidate(store)).toBe(false);
  });

  test("false when there are events but fewer than 5", () => {
    const store = makeStore();
    seedEvents(store, 4);
    expect(shouldConsolidate(store)).toBe(false);
  });

  test("true when never run before and >= 5 unconsolidated events exist", () => {
    const store = makeStore();
    seedEvents(store, 5);
    expect(shouldConsolidate(store)).toBe(true);
  });

  test("false when a run happened less than 12 hours ago, even with enough events", () => {
    const store = makeStore();
    seedEvents(store, 10);
    const oneHourAgo = Date.now() - 60 * 60 * 1000;
    store.db.run(
      `INSERT INTO memory_consolidation_runs
        (ranAt, eventsConsidered, candidatesProposed, candidatesAccepted, summary, snapshotBeforeJSON, rolledBackAt)
       VALUES (?, 1, 0, 0, 'x', '[]', NULL)`,
      [oneHourAgo]
    );
    expect(shouldConsolidate(store)).toBe(false);
  });

  test("true when the last run was >= 12 hours ago and enough events exist", () => {
    const store = makeStore();
    seedEvents(store, 10);
    const thirteenHoursAgo = Date.now() - 13 * 60 * 60 * 1000;
    store.db.run(
      `INSERT INTO memory_consolidation_runs
        (ranAt, eventsConsidered, candidatesProposed, candidatesAccepted, summary, snapshotBeforeJSON, rolledBackAt)
       VALUES (?, 1, 0, 0, 'x', '[]', NULL)`,
      [thirteenHoursAgo]
    );
    expect(shouldConsolidate(store)).toBe(true);
  });
});

describe("runConsolidation", () => {
  test("accepts a candidate with confidence >= 0.6 and >= 2 supporting events", async () => {
    const store = makeStore();
    const ids = seedEvents(store, 3);
    const callLLM = async () =>
      candidatesResponse([
        {
          canonicalTerm: "天润",
          aliases: ["tianrun", "添润"],
          category: "org",
          confidence: 0.65,
          supportingEventIds: [ids[0], ids[1]],
        },
      ]);

    const result = await runConsolidation(store, callLLM);

    expect(result.aborted).toBe(false);
    expect(result.candidatesProposed).toBe(1);
    expect(result.candidatesAccepted).toBe(1);

    const terms = store.allTerms();
    expect(terms).toHaveLength(1);
    expect(terms[0]?.canonicalTerm).toBe("天润");
    expect(terms[0]?.aliases.sort()).toEqual(["tianrun", "添润"].sort());

    // all fetched events (not just supporting ones) are marked processed
    const rows = store.db.query("SELECT id, consolidatedAt FROM episodic_events").all() as Array<{
      id: number;
      consolidatedAt: number | null;
    }>;
    expect(rows.every((r) => r.consolidatedAt !== null)).toBe(true);
    expect(store.unconsolidatedEventCount()).toBe(0);

    const runs = store.db.query("SELECT * FROM memory_consolidation_runs").all() as Array<Record<string, unknown>>;
    expect(runs).toHaveLength(1);
    expect(runs[0]?.candidatesAccepted).toBe(1);
    expect(runs[0]?.eventsConsidered).toBe(3);
  });

  test("accepts a candidate with confidence >= 0.9 from a single supporting event", async () => {
    const store = makeStore();
    const ids = seedEvents(store, 5);
    const callLLM = async () =>
      candidatesResponse([
        {
          canonicalTerm: "Diyi Wang",
          aliases: ["Diyi"],
          category: "person",
          confidence: 0.95,
          supportingEventIds: [ids[0]],
        },
      ]);

    const result = await runConsolidation(store, callLLM);
    expect(result.candidatesAccepted).toBe(1);
    expect(store.allTerms()).toHaveLength(1);
  });

  test("rejects a candidate with only 1 event and confidence below 0.9", async () => {
    const store = makeStore();
    const ids = seedEvents(store, 5);
    const callLLM = async () =>
      candidatesResponse([
        {
          canonicalTerm: "Maybe Person",
          aliases: [],
          category: "person",
          confidence: 0.5,
          supportingEventIds: [ids[0]],
        },
      ]);

    const result = await runConsolidation(store, callLLM);

    expect(result.aborted).toBe(false);
    expect(result.candidatesProposed).toBe(1);
    expect(result.candidatesAccepted).toBe(0);
    expect(store.allTerms()).toHaveLength(0);

    // the run still processed (considered) the events even though nothing was accepted
    expect(store.unconsolidatedEventCount()).toBe(0);
  });

  test("merges a candidate that collides with an existing entity by alias, unioning aliases and keeping the higher confidence", async () => {
    const store = makeStore();
    const ids = seedEvents(store, 5);
    const now = Date.now();
    store.db.run(
      `INSERT INTO entity_terms
        (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ["天润", JSON.stringify(["tianrun"]), "org", 0.9, "owner", JSON.stringify([9999]), now, now, null]
    );

    const callLLM = async () =>
      candidatesResponse([
        {
          canonicalTerm: "天润",
          aliases: ["添润"],
          category: "org",
          confidence: 0.7, // lower than existing 0.9 -> must not decrease it
          supportingEventIds: [ids[0], ids[1]],
        },
      ]);

    const result = await runConsolidation(store, callLLM);
    expect(result.candidatesAccepted).toBe(1);

    const terms = store.allTerms();
    expect(terms).toHaveLength(1); // merged, not duplicated
    const merged = terms[0] as EntityTerm;
    expect(merged.confidence).toBe(0.9); // kept the higher confidence
    expect(merged.aliases.sort()).toEqual(["tianrun", "添润"].sort());
    expect(merged.sourceEventIds.sort()).toEqual([9999, ids[0], ids[1]].sort());
  });

  test("merging can raise confidence when the candidate is more confident than the existing entry", async () => {
    const store = makeStore();
    const ids = seedEvents(store, 5);
    const now = Date.now();
    store.db.run(
      `INSERT INTO entity_terms
        (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ["Diyi Wang", JSON.stringify(["Diyi"]), "person", 0.6, "owner", JSON.stringify([]), now, now, null]
    );

    const callLLM = async () =>
      candidatesResponse([
        {
          canonicalTerm: "Diyi Wang",
          aliases: ["DW"],
          category: "person",
          confidence: 0.95,
          supportingEventIds: [ids[0]],
        },
      ]);

    await runConsolidation(store, callLLM);
    const terms = store.allTerms();
    expect(terms).toHaveLength(1);
    expect(terms[0]?.confidence).toBe(0.95);
  });

  test("is a no-op when the LLM returns unparseable garbage: no events consolidated, no entity_terms change", async () => {
    const store = makeStore();
    seedEvents(store, 5);
    const callLLM = async () => "this is not json at all {{{";

    const result = await runConsolidation(store, callLLM);

    expect(result.aborted).toBe(true);
    expect(store.allTerms()).toHaveLength(0);
    expect(store.unconsolidatedEventCount()).toBe(5);

    const runs = store.db.query("SELECT * FROM memory_consolidation_runs").all();
    expect(runs).toHaveLength(0);
  });

  test("is a no-op when the LLM returns valid JSON that doesn't match the expected shape", async () => {
    const store = makeStore();
    seedEvents(store, 5);
    const callLLM = async () => JSON.stringify({ unexpected: "shape" });

    const result = await runConsolidation(store, callLLM);

    expect(result.aborted).toBe(true);
    expect(store.allTerms()).toHaveLength(0);
    expect(store.unconsolidatedEventCount()).toBe(5);
  });
});

describe("upsertEntityTerm", () => {
  test("inserts a brand-new term when nothing matches", () => {
    const store = makeStore();
    const { term, merged } = upsertEntityTerm(store, [], {
      canonicalTerm: "PayPal",
      aliases: ["paypal", "pay pal"],
      category: "term",
      confidence: 1.0,
      sourceEventIds: [],
    });

    expect(merged).toBe(false);
    expect(term.canonicalTerm).toBe("PayPal");
    expect(term.aliases.sort()).toEqual(["pay pal", "paypal"].sort());
    expect(term.confidence).toBe(1.0);
    expect(term.origin).toBe("owner");

    const stored = store.allTerms();
    expect(stored).toHaveLength(1);
    expect(stored[0]?.canonicalTerm).toBe("PayPal");
  });

  test("merges into an existing term matched by alias, unioning aliases and keeping the higher confidence", () => {
    const store = makeStore();
    const now = Date.now();
    store.db.run(
      `INSERT INTO entity_terms
        (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ["PayPal", JSON.stringify(["paypal"]), "term", 0.6, "owner", "[]", now, now, null]
    );
    const existing = store.allTerms();

    const { term, merged } = upsertEntityTerm(store, existing, {
      canonicalTerm: "PayPal",
      aliases: ["pay pal"],
      category: "term",
      confidence: 1.0,
      sourceEventIds: [],
    });

    expect(merged).toBe(true);
    expect(term.aliases.sort()).toEqual(["pay pal", "paypal"].sort());
    expect(term.confidence).toBe(1.0);

    const stored = store.allTerms();
    expect(stored).toHaveLength(1); // merged, not duplicated
  });

  test("does not lower confidence when the new input is less confident than the existing entry", () => {
    const store = makeStore();
    const now = Date.now();
    store.db.run(
      `INSERT INTO entity_terms
        (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ["Diyi Wang", JSON.stringify(["Diyi"]), "person", 0.9, "owner", "[]", now, now, null]
    );
    const existing = store.allTerms();

    const { term } = upsertEntityTerm(store, existing, {
      canonicalTerm: "Diyi Wang",
      aliases: [],
      category: "person",
      confidence: 0.5,
      sourceEventIds: [],
    });

    expect(term.confidence).toBe(0.9);
  });
});

/**
 * origin is promoted one way only, and the rule lives in `upsertEntityTerm`
 * because that is the single shared merge path (2026-08-14 batch plan, P0-4
 * "origin 的单向提升").
 *
 * Before this batch the merge branch left `origin` alone entirely. That was
 * harmless while every write came from a machine path, but the batch adds two
 * paths where the *user personally vouches* for the term — typing it into the
 * dictionary panel (P0-4) and voice-correcting into it (P0-2). Merging either
 * of those into a row the agent's `remember_fact` wrote as "untrusted" would
 * leave that row flagged untrusted forever, right after the owner endorsed it.
 * A provenance flag exists to make the user review something; one that stays
 * lit after review is noise, and users learn to ignore noise.
 *
 * Both P0-2's correction path and P0-4's POST route depend on this, so it is
 * pinned here rather than in either caller's tests.
 */
describe("upsertEntityTerm origin promotion", () => {
  function seedTerm(
    store: MemoryStore,
    values: {
      canonicalTerm: string;
      aliases: string[];
      confidence: number;
      origin: string;
    }
  ): number {
    const now = Date.now();
    const result = store.db.run(
      `INSERT INTO entity_terms
        (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        values.canonicalTerm,
        JSON.stringify(values.aliases),
        "term",
        values.confidence,
        values.origin,
        "[]",
        now,
        now,
        null,
      ]
    );
    return Number(result.lastInsertRowid);
  }

  test("an owner-origin upsert promotes a merged untrusted term to owner", () => {
    const store = makeStore();
    // How `remember_fact` writes a term: full confidence, but provenance
    // "untrusted" because the agent loop may have read it out of hostile
    // context (P1-12).
    const id = seedTerm(store, {
      canonicalTerm: "PayPal",
      aliases: ["贝宝"],
      confidence: 1.0,
      origin: "untrusted",
    });

    const { term, merged } = upsertEntityTerm(store, store.allTerms(), {
      canonicalTerm: "PayPal",
      aliases: ["拍拍宝"],
      category: "term",
      confidence: 0.8,
      sourceEventIds: [],
      origin: "owner",
    });

    expect(merged).toBe(true);
    expect(term.origin).toBe("owner");
    // Promotion must be written, not merely reflected in the returned object:
    // the next reader of the dictionary is a fresh SELECT, not this value.
    const persisted = store.allTerms().find((t) => t.id === id);
    expect(persisted?.origin).toBe("owner");
    // ...and the rest of the merge is unchanged by the promotion.
    expect(persisted?.confidence).toBe(1.0);
    expect(persisted?.aliases.sort()).toEqual(["拍拍宝", "贝宝"].sort());
  });

  test("an untrusted upsert never downgrades an existing owner term", () => {
    const store = makeStore();
    const id = seedTerm(store, {
      canonicalTerm: "PayPal",
      aliases: ["贝宝"],
      confidence: 0.8,
      origin: "owner",
    });

    // `remember_fact` touching a term the owner already confirmed.
    const { term, merged } = upsertEntityTerm(store, store.allTerms(), {
      canonicalTerm: "PayPal",
      aliases: ["拍拍宝"],
      category: "term",
      confidence: 1.0,
      sourceEventIds: [],
      origin: "untrusted",
    });

    expect(merged).toBe(true);
    expect(term.origin).toBe("owner");
    const persisted = store.allTerms().find((t) => t.id === id);
    expect(persisted?.origin).toBe("owner");
    // Guard against a vacuous pass: the merge really did happen, it just
    // didn't touch origin.
    expect(persisted?.aliases).toContain("拍拍宝");
    expect(persisted?.confidence).toBe(1.0);
  });

  test("a non-owner upsert leaves a non-owner origin exactly as it was", () => {
    const store = makeStore();
    // Consolidation ("system") merging into a remember_fact row ("untrusted"):
    // neither side is the owner, so nothing is promoted in either direction.
    const id = seedTerm(store, {
      canonicalTerm: "天润",
      aliases: ["tianrun"],
      confidence: 0.7,
      origin: "untrusted",
    });

    const { term } = upsertEntityTerm(store, store.allTerms(), {
      canonicalTerm: "天润",
      aliases: ["添润"],
      category: "org",
      confidence: 0.9,
      sourceEventIds: [],
      origin: "system",
    });

    expect(term.origin).toBe("untrusted");
    expect(store.allTerms().find((t) => t.id === id)?.origin).toBe("untrusted");
  });

  test("an upsert with no origin promotes too, matching the insert branch's 'owner' default", () => {
    const store = makeStore();
    // `origin` is optional on the input, and the insert branch already reads an
    // omitted one as "owner". The merge branch has to read it the same way, or
    // one function would mean two different things by "no origin given".
    const id = seedTerm(store, {
      canonicalTerm: "Anthropic",
      aliases: ["安思罗匹克"],
      confidence: 0.6,
      origin: "untrusted",
    });

    const { term } = upsertEntityTerm(store, store.allTerms(), {
      canonicalTerm: "Anthropic",
      aliases: [],
      category: "term",
      confidence: 0.6,
      sourceEventIds: [],
    });

    expect(term.origin).toBe("owner");
    expect(store.allTerms().find((t) => t.id === id)?.origin).toBe("owner");
  });
});

describe("rollbackRun", () => {
  test("restores entity_terms to the pre-run snapshot and un-consolidates only that run's events", async () => {
    const store = makeStore();
    const firstIds = seedEvents(store, 3);

    // First run: establishes a baseline entity.
    await runConsolidation(store, async () =>
      candidatesResponse([
        {
          canonicalTerm: "天润",
          aliases: ["tianrun"],
          category: "org",
          confidence: 0.7,
          supportingEventIds: [firstIds[0], firstIds[1]],
        },
      ])
    );
    const afterFirstRun = store.allTerms();
    expect(afterFirstRun).toHaveLength(1);

    const secondIds = seedEvents(store, 5);

    // Second run: adds a second entity and touches the first entity's aliases.
    const secondResult = await runConsolidation(store, async () =>
      candidatesResponse([
        {
          canonicalTerm: "天润",
          aliases: ["添润"],
          category: "org",
          confidence: 0.9,
          supportingEventIds: [secondIds[0], secondIds[1]],
        },
        {
          canonicalTerm: "New Project",
          aliases: [],
          category: "project",
          confidence: 0.95,
          supportingEventIds: [secondIds[2]],
        },
      ])
    );
    expect(secondResult.aborted).toBe(false);
    expect(store.allTerms()).toHaveLength(2);
    expect(secondResult.ranRunId).not.toBeNull();

    rollbackRun(store, secondResult.ranRunId as number);

    // entity_terms back to exactly the post-first-run state
    const restored = store.allTerms();
    expect(restored).toHaveLength(1);
    expect(restored[0]?.aliases).toEqual(afterFirstRun[0]?.aliases);
    expect(restored[0]?.confidence).toEqual(afterFirstRun[0]?.confidence);
    expect(restored[0]?.id).toEqual(afterFirstRun[0]?.id);

    // second run's events are un-consolidated again
    const secondRows = store.db
      .query(`SELECT id, consolidatedAt FROM episodic_events WHERE id IN (${secondIds.map(() => "?").join(",")})`)
      .all(...secondIds) as Array<{ id: number; consolidatedAt: number | null }>;
    expect(secondRows.every((r) => r.consolidatedAt === null)).toBe(true);

    // first run's events remain consolidated
    const firstRows = store.db
      .query(`SELECT id, consolidatedAt FROM episodic_events WHERE id IN (${firstIds.map(() => "?").join(",")})`)
      .all(...firstIds) as Array<{ id: number; consolidatedAt: number | null }>;
    expect(firstRows.every((r) => r.consolidatedAt !== null)).toBe(true);

    // the run row itself is marked rolled back
    const runRow = store.db
      .query("SELECT rolledBackAt FROM memory_consolidation_runs WHERE id = ?")
      .get(secondResult.ranRunId) as { rolledBackAt: number | null };
    expect(runRow.rolledBackAt).not.toBeNull();
  });
});
