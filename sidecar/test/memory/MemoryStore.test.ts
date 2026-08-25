import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore, type RecordEpisodicEventInput } from "../../src/memory/MemoryStore";

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

describe("MemoryStore.confirmOwnerFact", () => {
  test("promotes an untrusted fact to owner and returns the updated row", () => {
    const store = makeStore();
    const id = store.recordOwnerFact("团队周会固定在周一上午十点。", "untrusted");

    const fact = store.confirmOwnerFact(id);

    expect(fact).not.toBeNull();
    expect(fact?.id).toBe(id);
    expect(fact?.origin).toBe("owner");
    expect(store.allOwnerFacts()[0]?.origin).toBe("owner");
  });

  test("returns null for an unknown id", () => {
    const store = makeStore();
    const id = store.recordOwnerFact("A real fact.", "untrusted");

    expect(store.confirmOwnerFact(id + 999)).toBeNull();
    // The real row is untouched by the miss.
    expect(store.allOwnerFacts()[0]?.origin).toBe("untrusted");
  });

  test("is a no-op on a fact that is already owner, not an error", () => {
    const store = makeStore();
    const id = store.recordOwnerFact("The owner prefers formal English.", "owner");
    const before = store.allOwnerFacts()[0];

    const fact = store.confirmOwnerFact(id);

    expect(fact).not.toBeNull();
    expect(fact?.origin).toBe("owner");
    expect(fact?.content).toBe(before?.content);
    expect(fact?.createdAt).toBe(before?.createdAt);
  });

  test("promotes agent- and system-origin facts too", () => {
    // The sidebar's "needs attention" dot lights for every origin that is not
    // "owner", so every one of them has to be clearable from the panel --
    // otherwise the dot is permanent and stops meaning anything.
    const store = makeStore();
    const agentId = store.recordOwnerFact("Written by the agent.", "agent");
    const systemId = store.recordOwnerFact("Auto-consolidated.", "system");

    expect(store.confirmOwnerFact(agentId)?.origin).toBe("owner");
    expect(store.confirmOwnerFact(systemId)?.origin).toBe("owner");
  });

  test("is one-way: confirming again keeps it owner, never demotes", () => {
    const store = makeStore();
    const id = store.recordOwnerFact("团队周会固定在周一上午十点。", "untrusted");

    store.confirmOwnerFact(id);
    store.confirmOwnerFact(id);
    store.confirmOwnerFact(id);

    expect(store.allOwnerFacts()[0]?.origin).toBe("owner");
  });

  test("leaves content and createdAt exactly as they were", () => {
    const store = makeStore();
    const id = store.recordOwnerFact("主力机是 M3 Max 的 MacBook Pro。", "untrusted");
    const before = store.allOwnerFacts()[0];

    store.confirmOwnerFact(id);

    const after = store.allOwnerFacts()[0];
    expect(after?.content).toBe("主力机是 M3 Max 的 MacBook Pro。");
    expect(after?.createdAt).toBe(before?.createdAt);
  });

  test("confirming one fact leaves every other fact's origin alone", () => {
    const store = makeStore();
    const confirmed = store.recordOwnerFact("Confirm me.", "untrusted");
    store.recordOwnerFact("Leave me untrusted.", "untrusted");
    store.recordOwnerFact("Leave me agent.", "agent");

    store.confirmOwnerFact(confirmed);

    const byContent = new Map(store.allOwnerFacts().map((f) => [f.content, f.origin]));
    expect(byContent.get("Confirm me.")).toBe("owner");
    expect(byContent.get("Leave me untrusted.")).toBe("untrusted");
    expect(byContent.get("Leave me agent.")).toBe("agent");
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

describe("MemoryStore.recentEvents", () => {
  function episodicInput(
    patch: Partial<RecordEpisodicEventInput> & { conversationId?: number | null }
  ): RecordEpisodicEventInput {
    return {
      mode: "ask",
      rawTranscript: "r",
      correctedTranscript: "c",
      effectiveInput: null,
      selectedContext: null,
      result: null,
      applicationName: "App",
      ...patch,
    };
  }

  /**
   * Records via the real write path, then pins `createdAt` to an explicit
   * value with a direct UPDATE. Two `recordEpisodicEvent` calls back-to-back
   * inside a test can land in the same millisecond (Date.now() has only
   * millisecond resolution), which would make an ordering assertion pass or
   * fail depending on wall-clock luck rather than on `recentEvents`'
   * behaviour. Pinning `createdAt` explicitly removes that luck; the
   * dedicated tie-break test below additionally proves the ORDER BY's `id
   * DESC` secondary key, by giving two rows the *same* pinned `createdAt` on
   * purpose.
   */
  function recordAt(
    store: MemoryStore,
    patch: Partial<RecordEpisodicEventInput> & { conversationId?: number | null },
    createdAt: number
  ): number {
    const id = store.recordEpisodicEvent(episodicInput(patch));
    store.db.run("UPDATE episodic_events SET createdAt = ? WHERE id = ?", [createdAt, id]);
    return id;
  }

  test("returns rows oldest-first, and by default excludes no mode", () => {
    const store = makeStore();
    recordAt(store, { mode: "transcribe", rawTranscript: "一" }, 1000);
    recordAt(store, { mode: "ask", rawTranscript: "二" }, 2000);
    recordAt(store, { mode: "agent", rawTranscript: "三" }, 3000);

    const rows = store.recentEvents(10);

    expect(rows.map((r) => r.rawTranscript)).toEqual(["一", "二", "三"]);
    expect(rows.map((r) => r.mode)).toEqual(["transcribe", "ask", "agent"]);
  });

  test("ties in createdAt are broken by insertion order (id), not left ambiguous", () => {
    const store = makeStore();
    const first = recordAt(store, { rawTranscript: "先" }, 5000);
    const second = recordAt(store, { rawTranscript: "后" }, 5000);
    expect(first).toBeLessThan(second);

    const rows = store.recentEvents(10);

    expect(rows.map((r) => r.rawTranscript)).toEqual(["先", "后"]);
  });

  test("returns only the most recent `limit` rows, not the first ones recorded", () => {
    const store = makeStore();
    recordAt(store, { rawTranscript: "一" }, 1000);
    recordAt(store, { rawTranscript: "二" }, 2000);
    recordAt(store, { rawTranscript: "三" }, 3000);
    recordAt(store, { rawTranscript: "四" }, 4000);

    expect(store.recentEvents(2).map((r) => r.rawTranscript)).toEqual(["三", "四"]);
  });

  test("opts.excludeModes filters out the named modes; the default is to exclude nothing", () => {
    const store = makeStore();
    recordAt(store, { mode: "transcribe", rawTranscript: "一" }, 1000);
    recordAt(store, { mode: "ask", rawTranscript: "二" }, 2000);
    recordAt(store, { mode: "agent", rawTranscript: "三" }, 3000);

    const rows = store.recentEvents(10, { excludeModes: ["transcribe", "agent"] });

    expect(rows.map((r) => r.rawTranscript)).toEqual(["二"]);
  });

  test("excludeModes is applied before limit, not after -- excluded rows must not consume the limit budget", () => {
    const store = makeStore();
    // Oldest to newest: ask, ask, transcribe, transcribe, transcribe. The two
    // most recent rows are both transcribe. A filter-after-limit
    // implementation (LIMIT 2, then drop excluded modes in a subquery or in
    // JS) would take those two transcribe rows, filter them both out, and
    // return []  -- silently reporting no data when two matching rows exist.
    // Filtering in the WHERE clause before LIMIT is applied is the only way
    // to get the two ask rows back.
    recordAt(store, { mode: "ask", rawTranscript: "问一" }, 1000);
    recordAt(store, { mode: "ask", rawTranscript: "问二" }, 2000);
    recordAt(store, { mode: "transcribe", rawTranscript: "听一" }, 3000);
    recordAt(store, { mode: "transcribe", rawTranscript: "听二" }, 4000);
    recordAt(store, { mode: "transcribe", rawTranscript: "听三" }, 5000);

    const rows = store.recentEvents(2, { excludeModes: ["transcribe"] });

    expect(rows.map((r) => r.rawTranscript)).toEqual(["问一", "问二"]);
  });

  test("conversationId round-trips through recordEpisodicEvent and recentEvents; unset comes back null", () => {
    const store = makeStore();
    recordAt(store, { mode: "ask", rawTranscript: "有会话", conversationId: 17 }, 1000);
    recordAt(store, { mode: "transcribe", rawTranscript: "无会话" }, 2000);

    const rows = store.recentEvents(10);

    expect(rows[0]?.conversationId).toBe(17);
    expect(rows[1]?.conversationId).toBeNull();
  });

  test("is unaffected by consolidatedAt -- a fully-consolidated store still returns every row", () => {
    const store = makeStore();
    recordAt(store, { mode: "transcribe", rawTranscript: "听写" }, 1000);
    recordAt(store, { mode: "ask", rawTranscript: "问答" }, 2000);

    // Mark every row consolidated. If recentEvents were built on top of
    // consolidationCandidates (or shared its predicate), this would empty it
    // out -- that is exactly the merge spec §3.4 forbids.
    store.db.run("UPDATE episodic_events SET consolidatedAt = ?", [Date.now()]);

    expect(store.recentEvents(10).map((r) => r.rawTranscript)).toEqual(["听写", "问答"]);
    expect(store.consolidationCandidates(10)).toHaveLength(0);
  });

  test("on a fresh, unconsolidated store, consolidationCandidates still omits transcribe while recentEvents includes it", () => {
    const store = makeStore();
    recordAt(store, { mode: "transcribe", rawTranscript: "听写" }, 1000);
    recordAt(store, { mode: "ask", rawTranscript: "问答" }, 2000);

    const recent = store.recentEvents(10).map((r) => r.rawTranscript);
    const candidates = store.consolidationCandidates(10) as Array<{ rawTranscript: string }>;

    expect(recent).toEqual(["听写", "问答"]);
    expect(candidates.map((c) => c.rawTranscript)).toEqual(["问答"]);
  });
});
