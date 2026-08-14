import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";

function makeStore() {
  const db = openDatabase(":memory:");
  return new MemoryStore(db);
}

describe("MemoryStore.recordEpisodicEvent", () => {
  test("inserts a row and returns its id", () => {
    const store = makeStore();
    const id = store.recordEpisodicEvent({
      mode: "transcribe",
      rawTranscript: "raw text",
      correctedTranscript: "corrected text",
      effectiveInput: null,
      selectedContext: null,
      result: "corrected text",
      applicationName: "TestApp",
    });
    expect(typeof id).toBe("number");
    expect(id).toBeGreaterThan(0);
  });

  test("defaults origin to 'owner' when not passed", () => {
    const store = makeStore();
    const id = store.recordEpisodicEvent({
      mode: "agent",
      rawTranscript: "raw",
      correctedTranscript: "corrected",
      effectiveInput: "do the thing",
      selectedContext: "some selection",
      result: null,
      applicationName: "Notes",
    });
    const row = store.db
      .query("SELECT * FROM episodic_events WHERE id = ?")
      .get(id) as Record<string, unknown>;
    expect(row.origin).toBe("owner");
    expect(row.mode).toBe("agent");
    expect(row.effectiveInput).toBe("do the thing");
    expect(row.selectedContext).toBe("some selection");
    expect(row.result).toBeNull();
    expect(row.consolidatedAt).toBeNull();
  });

  test("respects an explicit origin", () => {
    const store = makeStore();
    const id = store.recordEpisodicEvent({
      mode: "agent",
      rawTranscript: "raw",
      correctedTranscript: "corrected",
      effectiveInput: null,
      selectedContext: null,
      result: null,
      applicationName: "Notes",
      origin: "agent",
    });
    const row = store.db
      .query("SELECT * FROM episodic_events WHERE id = ?")
      .get(id) as Record<string, unknown>;
    expect(row.origin).toBe("agent");
  });
});

describe("MemoryStore.allTerms / search", () => {
  function seedTerms(store: MemoryStore) {
    const now = Date.now();
    store.db.run(
      `INSERT INTO entity_terms
        (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ["天润", JSON.stringify(["tianrun", "添润"]), "org", 0.8, "owner", "[1,2]", now, now, null]
    );
    store.db.run(
      `INSERT INTO entity_terms
        (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ["Diyi Wang", JSON.stringify(["Diyi", "DW"]), "person", 0.9, "owner", "[3]", now, now, null]
    );
  }

  test("allTerms returns every row, parsed", () => {
    const store = makeStore();
    seedTerms(store);
    const terms = store.allTerms();
    expect(terms).toHaveLength(2);
    const tianrun = terms.find((t) => t.canonicalTerm === "天润");
    expect(tianrun?.aliases).toEqual(["tianrun", "添润"]);
    expect(tianrun?.sourceEventIds).toEqual([1, 2]);
  });

  test("search matches canonicalTerm case-insensitively", () => {
    const store = makeStore();
    seedTerms(store);
    const results = store.search("diyi wang");
    expect(results).toHaveLength(1);
    expect(results[0]?.canonicalTerm).toBe("Diyi Wang");
  });

  test("search matches an alias case-insensitively (substring)", () => {
    const store = makeStore();
    seedTerms(store);
    const results = store.search("TIANRUN");
    expect(results).toHaveLength(1);
    expect(results[0]?.canonicalTerm).toBe("天润");
  });

  test("search returns no results for unmatched text", () => {
    const store = makeStore();
    seedTerms(store);
    expect(store.search("nonexistent")).toHaveLength(0);
  });
});

describe("MemoryStore.updateEntityTerm", () => {
  const ONE_HOUR_AGO = Date.now() - 60 * 60 * 1000;

  function seedTerm(
    store: MemoryStore,
    overrides: Partial<{
      canonicalTerm: string;
      aliases: string[];
      category: string;
      confidence: number;
      origin: string;
      sourceEventIds: string;
      createdAt: number;
      updatedAt: number;
    }> = {}
  ): number {
    const values = {
      canonicalTerm: "PayPal",
      aliases: ["贝宝"],
      category: "org",
      confidence: 0.8,
      origin: "system",
      sourceEventIds: "[1]",
      createdAt: ONE_HOUR_AGO,
      updatedAt: ONE_HOUR_AGO,
      ...overrides,
    };
    const result = store.db.run(
      `INSERT INTO entity_terms
        (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        values.canonicalTerm,
        JSON.stringify(values.aliases),
        values.category,
        values.confidence,
        values.origin,
        values.sourceEventIds,
        values.createdAt,
        values.updatedAt,
        null,
      ]
    );
    return Number(result.lastInsertRowid);
  }

  test("updates canonicalTerm, aliases and confidence together and bumps updatedAt", () => {
    const store = makeStore();
    const id = seedTerm(store);

    const updated = store.updateEntityTerm(id, {
      canonicalTerm: "PayPal Inc",
      aliases: ["贝宝", "拍拍宝"],
      confidence: 0.95,
    });

    expect(updated).not.toBeNull();
    expect(updated?.canonicalTerm).toBe("PayPal Inc");
    expect(updated?.aliases).toEqual(["贝宝", "拍拍宝"]);
    expect(updated?.confidence).toBe(0.95);
    expect(updated?.updatedAt as number).toBeGreaterThan(ONE_HOUR_AGO);
    // createdAt is never rewritten by an edit.
    expect(updated?.createdAt).toBe(ONE_HOUR_AGO);

    const persisted = store.allTerms().find((t) => t.id === id);
    expect(persisted).toEqual(updated as NonNullable<typeof updated>);
  });

  test("a partial patch leaves unspecified fields untouched", () => {
    const store = makeStore();
    const id = seedTerm(store, { canonicalTerm: "天润", aliases: ["tianrun"], confidence: 0.7 });

    const updated = store.updateEntityTerm(id, { confidence: 0.42 });

    expect(updated?.confidence).toBe(0.42);
    expect(updated?.canonicalTerm).toBe("天润");
    expect(updated?.aliases).toEqual(["tianrun"]);
    // Fields the patch shape does not cover at all stay exactly as seeded.
    expect(updated?.category).toBe("org");
    expect(updated?.origin).toBe("system");
    expect(updated?.sourceEventIds).toEqual([1]);
  });

  test("returns null and changes nothing for an unknown id", () => {
    const store = makeStore();
    const id = seedTerm(store);
    const before = store.allTerms();

    const updated = store.updateEntityTerm(id + 999, { canonicalTerm: "Nope" });

    expect(updated).toBeNull();
    expect(store.allTerms()).toEqual(before);
  });

  test("round-trips CJK aliases through the JSON column", () => {
    const store = makeStore();
    const id = seedTerm(store);

    store.updateEntityTerm(id, { aliases: ["贝宝", "拍拍宝", "PayPal 支付"] });

    const persisted = store.allTerms().find((t) => t.id === id);
    expect(persisted?.aliases).toEqual(["贝宝", "拍拍宝", "PayPal 支付"]);
  });

  test("round-trips an empty alias array (clearing every alias)", () => {
    const store = makeStore();
    const id = seedTerm(store, { aliases: ["贝宝", "拍拍宝"] });

    const updated = store.updateEntityTerm(id, { aliases: [] });

    expect(updated?.aliases).toEqual([]);
    expect(store.allTerms().find((t) => t.id === id)?.aliases).toEqual([]);
  });

  test("rejects a confidence above 1 rather than clamping it", () => {
    const store = makeStore();
    const id = seedTerm(store, { confidence: 0.8 });

    // RangeError specifically, not a bare Error: a `TypeError` (e.g. the
    // method not existing yet) must not satisfy this assertion.
    expect(() => store.updateEntityTerm(id, { confidence: 1.5 })).toThrow(RangeError);
    // Rejected, not clamped to 1.0: the row is untouched.
    expect(store.allTerms().find((t) => t.id === id)?.confidence).toBe(0.8);
  });

  test("rejects a negative confidence rather than clamping it", () => {
    const store = makeStore();
    const id = seedTerm(store, { confidence: 0.8 });

    expect(() => store.updateEntityTerm(id, { confidence: -0.5 })).toThrow(RangeError);
    expect(store.allTerms().find((t) => t.id === id)?.confidence).toBe(0.8);
  });

  test("accepts the 0 and 1 boundaries", () => {
    const store = makeStore();
    const id = seedTerm(store);

    expect(store.updateEntityTerm(id, { confidence: 0 })?.confidence).toBe(0);
    expect(store.updateEntityTerm(id, { confidence: 1 })?.confidence).toBe(1);
  });
});

describe("MemoryStore.deleteEntityTerm", () => {
  function seedTerm(store: MemoryStore, canonicalTerm: string): number {
    const now = Date.now();
    const result = store.db.run(
      `INSERT INTO entity_terms
        (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [canonicalTerm, "[]", "term", 0.9, "owner", "[]", now, now, null]
    );
    return Number(result.lastInsertRowid);
  }

  test("deletes the row and returns true", () => {
    const store = makeStore();
    const id = seedTerm(store, "PayPal");

    expect(store.deleteEntityTerm(id)).toBe(true);
    expect(store.allTerms()).toHaveLength(0);
  });

  test("returns false for an unknown id", () => {
    const store = makeStore();
    const id = seedTerm(store, "PayPal");

    expect(store.deleteEntityTerm(id + 999)).toBe(false);
    expect(store.allTerms()).toHaveLength(1);
  });

  test("deleting one term leaves the others intact", () => {
    const store = makeStore();
    const keepA = seedTerm(store, "天润");
    const remove = seedTerm(store, "PayPal");
    const keepB = seedTerm(store, "Anthropic");

    expect(store.deleteEntityTerm(remove)).toBe(true);

    const remaining = store.allTerms();
    expect(remaining.map((t) => t.id).sort()).toEqual([keepA, keepB].sort());
    expect(remaining.map((t) => t.canonicalTerm).sort()).toEqual(["Anthropic", "天润"].sort());
  });
});

describe("MemoryStore consolidation trigger helpers", () => {
  test("unconsolidatedEventCount counts only events with a null consolidatedAt", () => {
    const store = makeStore();
    store.recordEpisodicEvent({
      mode: "transcribe",
      rawTranscript: "a",
      correctedTranscript: "a",
      effectiveInput: null,
      selectedContext: null,
      result: null,
      applicationName: "App",
    });
    const id2 = store.recordEpisodicEvent({
      mode: "transcribe",
      rawTranscript: "b",
      correctedTranscript: "b",
      effectiveInput: null,
      selectedContext: null,
      result: null,
      applicationName: "App",
    });
    store.db.run("UPDATE episodic_events SET consolidatedAt = ? WHERE id = ?", [Date.now(), id2]);
    expect(store.unconsolidatedEventCount()).toBe(1);
  });

  test("hoursSinceLastConsolidation is null when no run has happened", () => {
    const store = makeStore();
    expect(store.hoursSinceLastConsolidation()).toBeNull();
  });

  test("hoursSinceLastConsolidation reflects the most recent run", () => {
    const store = makeStore();
    const twoHoursAgo = Date.now() - 2 * 60 * 60 * 1000;
    store.db.run(
      `INSERT INTO memory_consolidation_runs
        (ranAt, eventsConsidered, candidatesProposed, candidatesAccepted, summary, snapshotBeforeJSON, rolledBackAt)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [twoHoursAgo, 5, 1, 1, "summary", "[]", null]
    );
    const hours = store.hoursSinceLastConsolidation();
    expect(hours).not.toBeNull();
    expect(hours as number).toBeGreaterThanOrEqual(1.9);
    expect(hours as number).toBeLessThanOrEqual(2.1);
  });
});

describe("MemoryStore.recordOwnerFact / allOwnerFacts", () => {
  test("recordOwnerFact inserts a row and returns its id", () => {
    const store = makeStore();
    const id = store.recordOwnerFact("The owner's name is Diyi.");
    expect(typeof id).toBe("number");
    expect(id).toBeGreaterThan(0);
  });

  test("defaults origin to 'owner' when not passed", () => {
    const store = makeStore();
    const id = store.recordOwnerFact("The owner prefers formal English.");
    const row = store.db
      .query("SELECT * FROM owner_facts WHERE id = ?")
      .get(id) as Record<string, unknown>;
    expect(row.origin).toBe("owner");
    expect(row.content).toBe("The owner prefers formal English.");
    expect(typeof row.createdAt).toBe("number");
  });

  test("respects an explicit origin", () => {
    const store = makeStore();
    const id = store.recordOwnerFact("Learned via consolidation.", "agent");
    const row = store.db
      .query("SELECT * FROM owner_facts WHERE id = ?")
      .get(id) as Record<string, unknown>;
    expect(row.origin).toBe("agent");
  });

  test("allOwnerFacts returns an empty array when none recorded", () => {
    const store = makeStore();
    expect(store.allOwnerFacts()).toEqual([]);
  });

  test("allOwnerFacts returns every recorded fact, parsed", () => {
    const store = makeStore();
    store.recordOwnerFact("The owner's name is Diyi.");
    store.recordOwnerFact("The owner prefers formal English.", "owner");
    const facts = store.allOwnerFacts();
    expect(facts).toHaveLength(2);
    expect(facts.map((f) => f.content).sort()).toEqual(
      ["The owner's name is Diyi.", "The owner prefers formal English."].sort()
    );
    expect(facts[0]).toMatchObject({
      id: expect.any(Number),
      content: expect.any(String),
      createdAt: expect.any(Number),
      origin: expect.any(String),
    });
  });
});

describe("MemoryStore.listConsolidationRuns", () => {
  test("returns an empty array when no runs have happened", () => {
    const store = makeStore();
    expect(store.listConsolidationRuns()).toEqual([]);
  });

  test("returns run summaries ordered by ranAt DESC, excluding snapshotBeforeJSON", () => {
    const store = makeStore();
    const earlier = Date.now() - 60 * 60 * 1000;
    const later = Date.now();
    store.db.run(
      `INSERT INTO memory_consolidation_runs
        (ranAt, eventsConsidered, candidatesProposed, candidatesAccepted, summary, snapshotBeforeJSON, rolledBackAt)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [earlier, 10, 2, 1, "first run", '[{"huge":"snapshot"}]', null]
    );
    store.db.run(
      `INSERT INTO memory_consolidation_runs
        (ranAt, eventsConsidered, candidatesProposed, candidatesAccepted, summary, snapshotBeforeJSON, rolledBackAt)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [later, 20, 4, 3, "second run", '[{"huge":"snapshot2"}]', later + 1000]
    );

    const runs = store.listConsolidationRuns();

    expect(runs).toHaveLength(2);
    expect(runs[0]).toEqual({
      id: expect.any(Number),
      ranAt: later,
      eventsConsidered: 20,
      candidatesProposed: 4,
      candidatesAccepted: 3,
      summary: "second run",
      rolledBackAt: later + 1000,
    });
    expect(runs[1]).toEqual({
      id: expect.any(Number),
      ranAt: earlier,
      eventsConsidered: 10,
      candidatesProposed: 2,
      candidatesAccepted: 1,
      summary: "first run",
      rolledBackAt: null,
    });
    for (const run of runs) {
      expect(run).not.toHaveProperty("snapshotBeforeJSON");
    }
  });
});
