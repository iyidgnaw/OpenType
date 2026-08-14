import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { buildMemoryRoutes } from "../../src/memory/routes";
import { createRouter } from "../../src/router";
import type { CallLLM } from "../../src/memory/consolidator";

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
}

function get(path: string): Request {
  return new Request(`http://sidecar${path}`, { method: "GET" });
}

function post(path: string, body?: unknown): Request {
  if (body === undefined) {
    return new Request(`http://sidecar${path}`, { method: "POST" });
  }
  return new Request(`http://sidecar${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

function put(path: string, body: unknown): Request {
  return new Request(`http://sidecar${path}`, {
    method: "PUT",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

function del(path: string): Request {
  return new Request(`http://sidecar${path}`, { method: "DELETE" });
}

function seedTerm(
  store: MemoryStore,
  overrides: Partial<{
    canonicalTerm: string;
    aliases: string[];
    category: string;
    confidence: number;
    origin: string;
  }> = {}
): number {
  const now = Date.now();
  const values = {
    canonicalTerm: "PayPal",
    aliases: ["贝宝"],
    category: "org",
    confidence: 0.8,
    origin: "system",
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
      "[]",
      now,
      now,
      null,
    ]
  );
  return Number(result.lastInsertRowid);
}

function noOpCallLLM(): CallLLM {
  return async () => JSON.stringify({ candidates: [] });
}

function seedEvents(store: MemoryStore, count: number): void {
  for (let i = 0; i < count; i++) {
    store.recordEpisodicEvent({
      mode: "transcribe",
      rawTranscript: `raw ${i}`,
      correctedTranscript: `corrected ${i}`,
      effectiveInput: null,
      selectedContext: null,
      result: null,
      applicationName: "TestApp",
    });
  }
}

describe("GET /memory/terms", () => {
  test("returns an empty list when there are no terms", async () => {
    const router = createRouter(buildMemoryRoutes(makeStore(), noOpCallLLM()));

    const response = await router(get("/memory/terms"));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ terms: [] });
  });

  test("returns every entity term, parsed", async () => {
    const store = makeStore();
    const now = Date.now();
    store.db.run(
      `INSERT INTO entity_terms
        (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ["Diyi Wang", JSON.stringify(["Diyi", "DW"]), "person", 0.9, "owner", "[3]", now, now, null]
    );
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(get("/memory/terms"));

    expect(response.status).toBe(200);
    const body = (await response.json()) as { terms: unknown[] };
    expect(body.terms).toHaveLength(1);
    expect(body.terms[0]).toMatchObject({
      canonicalTerm: "Diyi Wang",
      aliases: ["Diyi", "DW"],
      category: "person",
      confidence: 0.9,
    });
  });

  test("carries id and origin for every term so the panel can show provenance and address a row", async () => {
    const store = makeStore();
    const ownerId = seedTerm(store, { canonicalTerm: "天润", origin: "owner" });
    const untrustedId = seedTerm(store, { canonicalTerm: "PayPal", origin: "untrusted" });
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(get("/memory/terms"));

    const body = (await response.json()) as { terms: Array<Record<string, unknown>> };
    const byTerm = new Map(body.terms.map((t) => [t.canonicalTerm as string, t]));
    // origin must survive: "untrusted" is precisely what P1-12 wants a user to
    // be able to see (and then edit or delete) in the dictionary panel.
    expect(byTerm.get("天润")).toMatchObject({ id: ownerId, origin: "owner" });
    expect(byTerm.get("PayPal")).toMatchObject({ id: untrustedId, origin: "untrusted" });
  });
});

describe("POST /memory/terms", () => {
  test("creates a term at origin 'owner' and confidence 1.0", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(
      post("/memory/terms", { canonicalTerm: "Anthropic", aliases: ["安思罗匹克"] })
    );

    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      term: Record<string, unknown>;
      merged: boolean;
    };
    expect(body.merged).toBe(false);
    expect(body.term).toMatchObject({
      canonicalTerm: "Anthropic",
      aliases: ["安思罗匹克"],
      // The user typed this themselves -- strictly more trusted than the
      // agent's remember_fact path, which deliberately writes "untrusted".
      origin: "owner",
      confidence: 1,
    });

    const stored = store.allTerms();
    expect(stored).toHaveLength(1);
    expect(stored[0]).toMatchObject({
      canonicalTerm: "Anthropic",
      aliases: ["安思罗匹克"],
      origin: "owner",
      confidence: 1,
    });
  });

  test("merges into an existing term whose alias matches instead of duplicating it", async () => {
    const store = makeStore();
    // Existing term arrived via consolidation: canonical "PayPal", alias "贝宝".
    const existingId = seedTerm(store, {
      canonicalTerm: "PayPal",
      aliases: ["贝宝"],
      confidence: 0.8,
    });
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    // The user types a new term that shares the "贝宝" alias. Going through
    // upsertEntityTerm is the whole point: a plain INSERT would leave two rows
    // fighting over the same alias.
    const response = await router(
      post("/memory/terms", { canonicalTerm: "PayPal Inc", aliases: ["贝宝", "拍拍宝"] })
    );

    expect(response.status).toBe(200);
    const body = (await response.json()) as { term: Record<string, unknown>; merged: boolean };
    expect(body.merged).toBe(true);
    // What comes back is the *surviving* row, not the shape that was posted:
    // its pre-existing id and its pre-existing canonicalTerm. The panel needs
    // this to be true, because on `merged` it has to replace a row it already
    // renders rather than append the "new" term it thought it was creating.
    expect(body.term).toMatchObject({
      id: existingId,
      canonicalTerm: "PayPal",
      aliases: ["贝宝", "拍拍宝"],
      confidence: 1,
    });

    const stored = store.allTerms();
    expect(stored).toHaveLength(1);
    expect(stored[0]?.canonicalTerm).toBe("PayPal");
    expect(stored[0]?.aliases).toEqual(["贝宝", "拍拍宝"]);
    // Merge keeps the higher confidence, which for an owner-typed term is 1.0.
    expect(stored[0]?.confidence).toBe(1);
  });

  test("merging into an untrusted term promotes it to origin 'owner'", async () => {
    const store = makeStore();
    // Written by the agent's `remember_fact`: usable, but flagged untrusted
    // because the agent loop may have picked it up out of hostile context.
    const id = seedTerm(store, {
      canonicalTerm: "PayPal",
      aliases: ["贝宝"],
      confidence: 1,
      origin: "untrusted",
    });
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    // The user now types the same term into the dictionary panel by hand.
    const response = await router(
      post("/memory/terms", { canonicalTerm: "PayPal", aliases: ["拍拍宝"] })
    );

    expect(response.status).toBe(200);
    const body = (await response.json()) as { term: Record<string, unknown>; merged: boolean };
    expect(body.merged).toBe(true);
    // The owner just vouched for this term in person. Leaving the "untrusted"
    // badge lit afterwards teaches the user to ignore the badge -- see the
    // "origin 的单向提升" rule, which lives in `upsertEntityTerm`.
    expect(body.term).toMatchObject({ id, origin: "owner" });
    expect(store.allTerms().find((t) => t.id === id)?.origin).toBe("owner");
  });

  test("merges when the new canonicalTerm matches an existing term's canonicalTerm", async () => {
    const store = makeStore();
    seedTerm(store, { canonicalTerm: "天润", aliases: ["tianrun"] });
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(
      post("/memory/terms", { canonicalTerm: "天润", aliases: ["添润"] })
    );

    expect(((await response.json()) as { merged: boolean }).merged).toBe(true);
    const stored = store.allTerms();
    expect(stored).toHaveLength(1);
    expect(stored[0]?.aliases).toEqual(["tianrun", "添润"]);
  });

  test("defaults aliases to an empty list and category to 'term'", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(post("/memory/terms", { canonicalTerm: "OpenType" }));

    expect(response.status).toBe(200);
    expect(store.allTerms()[0]).toMatchObject({
      canonicalTerm: "OpenType",
      aliases: [],
      category: "term",
    });
  });

  test("honors an explicit valid category", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    await router(post("/memory/terms", { canonicalTerm: "Diyi Wang", category: "person" }));

    expect(store.allTerms()[0]?.category).toBe("person");
  });

  test("ignores a client-supplied confidence or origin rather than trusting it", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(
      post("/memory/terms", {
        canonicalTerm: "OpenType",
        confidence: 0.1,
        origin: "system",
      })
    );

    // Confidence and origin are the sidecar's to decide -- this endpoint means
    // "the owner typed this", so it pins 1.0/"owner" and drops whatever the
    // body claimed. Threading the body's values through would make provenance
    // (the whole point of P1-12's origin field) a client-asserted value.
    expect(response.status).toBe(200);
    expect(store.allTerms()[0]).toMatchObject({ confidence: 1, origin: "owner" });
  });

  test("400 when canonicalTerm is missing", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(post("/memory/terms", { aliases: ["x"] }));

    expect(response.status).toBe(400);
    expect(store.allTerms()).toHaveLength(0);
  });

  test("400 when canonicalTerm is empty or whitespace-only", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    expect((await router(post("/memory/terms", { canonicalTerm: "" }))).status).toBe(400);
    expect((await router(post("/memory/terms", { canonicalTerm: "   " }))).status).toBe(400);
    expect(store.allTerms()).toHaveLength(0);
  });

  test("400 when aliases is not an array", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(
      post("/memory/terms", { canonicalTerm: "PayPal", aliases: "贝宝" })
    );

    expect(response.status).toBe(400);
    expect(store.allTerms()).toHaveLength(0);
  });

  test("400 when aliases contains a non-string", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(
      post("/memory/terms", { canonicalTerm: "PayPal", aliases: ["贝宝", 42] })
    );

    expect(response.status).toBe(400);
    expect(store.allTerms()).toHaveLength(0);
  });

  test("400 on a category outside the allowed set", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(
      post("/memory/terms", { canonicalTerm: "PayPal", category: "bogus" })
    );

    expect(response.status).toBe(400);
    expect(store.allTerms()).toHaveLength(0);
  });
});

describe("PUT /memory/terms/:id", () => {
  test("updates canonicalTerm, aliases and confidence and returns the updated term", async () => {
    const store = makeStore();
    const id = seedTerm(store, { canonicalTerm: "PayPal", aliases: ["贝宝"], confidence: 0.8 });
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(
      put(`/memory/terms/${id}`, {
        canonicalTerm: "PayPal Inc",
        aliases: ["贝宝", "拍拍宝"],
        confidence: 0.5,
      })
    );

    expect(response.status).toBe(200);
    const body = (await response.json()) as { term: Record<string, unknown> };
    expect(body.term).toMatchObject({
      id,
      canonicalTerm: "PayPal Inc",
      aliases: ["贝宝", "拍拍宝"],
      confidence: 0.5,
    });
    expect(store.allTerms()[0]).toMatchObject({
      canonicalTerm: "PayPal Inc",
      aliases: ["贝宝", "拍拍宝"],
      confidence: 0.5,
    });
  });

  test("applies a partial patch, leaving the other fields alone", async () => {
    const store = makeStore();
    const id = seedTerm(store, { canonicalTerm: "天润", aliases: ["tianrun"], confidence: 0.8 });
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(put(`/memory/terms/${id}`, { aliases: ["tianrun", "添润"] }));

    expect(response.status).toBe(200);
    expect(store.allTerms()[0]).toMatchObject({
      canonicalTerm: "天润",
      aliases: ["tianrun", "添润"],
      confidence: 0.8,
    });
  });

  test("404 on an unknown id", async () => {
    const store = makeStore();
    const id = seedTerm(store);
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    // Update a real id first, so this test can only pass once the route
    // actually exists -- a *missing* route also answers 404.
    const known = await router(put(`/memory/terms/${id}`, { canonicalTerm: "PayPal Inc" }));
    expect(known.status).toBe(200);

    const response = await router(put(`/memory/terms/${id + 999}`, { canonicalTerm: "Nope" }));

    expect(response.status).toBe(404);
    expect(store.allTerms()[0]?.canonicalTerm).toBe("PayPal Inc");
  });

  test("400 on a non-numeric id", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(put("/memory/terms/not-an-id", { canonicalTerm: "X" }));

    expect(response.status).toBe(400);
  });

  test("400 when canonicalTerm is present but empty", async () => {
    const store = makeStore();
    const id = seedTerm(store);
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(put(`/memory/terms/${id}`, { canonicalTerm: "  " }));

    expect(response.status).toBe(400);
    expect(store.allTerms()[0]?.canonicalTerm).toBe("PayPal");
  });

  test("400 when aliases is not an array of strings", async () => {
    const store = makeStore();
    const id = seedTerm(store);
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    expect((await router(put(`/memory/terms/${id}`, { aliases: "贝宝" }))).status).toBe(400);
    expect((await router(put(`/memory/terms/${id}`, { aliases: [1, 2] }))).status).toBe(400);
    expect(store.allTerms()[0]?.aliases).toEqual(["贝宝"]);
  });

  test("400 on a confidence outside 0..1, without clamping it", async () => {
    const store = makeStore();
    const id = seedTerm(store, { confidence: 0.8 });
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    expect((await router(put(`/memory/terms/${id}`, { confidence: 1.5 }))).status).toBe(400);
    expect((await router(put(`/memory/terms/${id}`, { confidence: -0.1 }))).status).toBe(400);
    expect((await router(put(`/memory/terms/${id}`, { confidence: "high" }))).status).toBe(400);
    expect(store.allTerms()[0]?.confidence).toBe(0.8);
  });
});

describe("DELETE /memory/terms/:id", () => {
  test("deletes the term", async () => {
    const store = makeStore();
    const id = seedTerm(store);
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(del(`/memory/terms/${id}`));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ deleted: true });
    expect(store.allTerms()).toHaveLength(0);
  });

  test("404 on an unknown id", async () => {
    const store = makeStore();
    const id = seedTerm(store);
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    // Delete a real id first, so this test can only pass once the route
    // actually exists -- a *missing* route also answers 404.
    expect((await router(del(`/memory/terms/${id}`))).status).toBe(200);

    const response = await router(del(`/memory/terms/${id}`));

    expect(response.status).toBe(404);
  });

  test("400 on a non-numeric id", async () => {
    const store = makeStore();
    const id = seedTerm(store);
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    // Same distinction PUT makes: a malformed id is a bad request, not a
    // missing row. `Number("not-an-id")` is NaN, which must not be allowed to
    // reach the store and read as "no such id" (404).
    const response = await router(del("/memory/terms/not-an-id"));

    expect(response.status).toBe(400);
    expect(store.allTerms().find((t) => t.id === id)).toBeDefined();
  });

  test("leaves owner facts alone (the two DELETE routes must not collide)", async () => {
    const store = makeStore();
    const id = seedTerm(store);
    store.recordOwnerFact("The owner's name is Diyi.");
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    await router(del(`/memory/terms/${id}`));

    expect(store.allTerms()).toHaveLength(0);
    expect(store.allOwnerFacts()).toHaveLength(1);
  });
});

describe("GET /memory/consolidation-runs", () => {
  test("returns an empty list when no runs have happened", async () => {
    const router = createRouter(buildMemoryRoutes(makeStore(), noOpCallLLM()));

    const response = await router(get("/memory/consolidation-runs"));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ runs: [] });
  });

  test("returns run summaries ordered by ranAt DESC, excluding snapshotBeforeJSON", async () => {
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
      [later, 20, 4, 3, "second run", '[{"huge":"snapshot2"}]', null]
    );
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(get("/memory/consolidation-runs"));

    expect(response.status).toBe(200);
    const body = (await response.json()) as { runs: Array<Record<string, unknown>> };
    expect(body.runs).toHaveLength(2);
    expect(body.runs[0]?.summary).toBe("second run");
    expect(body.runs[1]?.summary).toBe("first run");
    for (const run of body.runs) {
      expect(run).not.toHaveProperty("snapshotBeforeJSON");
    }
  });
});

describe("POST /memory/consolidate-now", () => {
  test("runs consolidation immediately, bypassing the normal shouldConsolidate time/count gate", async () => {
    const store = makeStore();
    seedEvents(store, 2); // fewer than the normal 5-event minimum
    const callLLM: CallLLM = async () =>
      JSON.stringify({
        candidates: [
          {
            canonicalTerm: "Test Org",
            aliases: [],
            category: "org",
            confidence: 0.95,
            supportingEventIds: [1],
          },
        ],
      });
    const router = createRouter(buildMemoryRoutes(store, callLLM));

    const response = await router(post("/memory/consolidate-now"));

    expect(response.status).toBe(200);
    const runs = store.db.query("SELECT * FROM memory_consolidation_runs").all();
    expect(runs).toHaveLength(1); // ran despite only 2 unconsolidated events
    expect(store.allTerms()).toHaveLength(1);
  });

  test("returns a body reflecting the result even when the run aborts", async () => {
    const store = makeStore();
    seedEvents(store, 3);
    const callLLM: CallLLM = async () => "not json";
    const router = createRouter(buildMemoryRoutes(store, callLLM));

    const response = await router(post("/memory/consolidate-now"));

    expect(response.status).toBe(200);
    const body = (await response.json()) as { result: { aborted: boolean } };
    expect(body.result.aborted).toBe(true);
    const runs = store.db.query("SELECT * FROM memory_consolidation_runs").all();
    expect(runs).toHaveLength(0);
  });
});
