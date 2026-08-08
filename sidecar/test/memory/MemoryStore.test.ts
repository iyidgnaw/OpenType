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
