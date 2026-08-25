import { describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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

function patch(path: string, body?: unknown): Request {
  if (body === undefined) {
    return new Request(`http://sidecar${path}`, { method: "PATCH" });
  }
  return new Request(`http://sidecar${path}`, {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
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

describe("PATCH /memory/owner-facts/:id", () => {
  test("promotes an untrusted fact to owner and returns it", async () => {
    const store = makeStore();
    const id = store.recordOwnerFact("团队周会固定在周一上午十点。", "untrusted");
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(patch(`/memory/owner-facts/${id}`));

    expect(response.status).toBe(200);
    const body = (await response.json()) as { ownerFact: Record<string, unknown> };
    expect(body.ownerFact).toMatchObject({ id, origin: "owner" });
    expect(body.ownerFact.content).toBe("团队周会固定在周一上午十点。");
  });

  test("the promotion is visible on the next GET /memory/owner-facts", async () => {
    const store = makeStore();
    const id = store.recordOwnerFact("Planted from a web page.", "untrusted");
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    await router(patch(`/memory/owner-facts/${id}`));

    const listed = await router(get("/memory/owner-facts"));
    const body = (await listed.json()) as { ownerFacts: Array<Record<string, unknown>> };
    expect(body.ownerFacts).toHaveLength(1);
    expect(body.ownerFacts[0]?.origin).toBe("owner");
  });

  test("an already-owner fact is a 200 no-op, not an error", async () => {
    const store = makeStore();
    const id = store.recordOwnerFact("The owner prefers formal English.", "owner");
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(patch(`/memory/owner-facts/${id}`));

    expect(response.status).toBe(200);
    const body = (await response.json()) as { ownerFact: Record<string, unknown> };
    expect(body.ownerFact.origin).toBe("owner");
  });

  test("promotes agent- and system-origin facts too", async () => {
    const store = makeStore();
    const agentId = store.recordOwnerFact("Written by the agent.", "agent");
    const systemId = store.recordOwnerFact("Auto-consolidated.", "system");
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    expect((await router(patch(`/memory/owner-facts/${agentId}`))).status).toBe(200);
    expect((await router(patch(`/memory/owner-facts/${systemId}`))).status).toBe(200);

    expect(store.allOwnerFacts().every((f) => f.origin === "owner")).toBe(true);
  });

  test("an unknown id is a 404", async () => {
    const store = makeStore();
    const id = store.recordOwnerFact("A real fact.", "untrusted");
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(patch(`/memory/owner-facts/${id + 999}`));

    expect(response.status).toBe(404);
    const body = (await response.json()) as { error: string };
    expect(body.error).toBe("owner_fact_not_found");
    expect(store.allOwnerFacts()[0]?.origin).toBe("untrusted");
  });

  test("a malformed id is a 400, matching the delete route", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(patch("/memory/owner-facts/not-an-id"));

    expect(response.status).toBe(400);
    const body = (await response.json()) as { error: string };
    expect(body.error).toBe("invalid_id");
  });

  test("an explicit { origin: 'owner' } body is accepted", async () => {
    const store = makeStore();
    const id = store.recordOwnerFact("Planted.", "untrusted");
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(patch(`/memory/owner-facts/${id}`, { origin: "owner" }));

    expect(response.status).toBe(200);
    expect(store.allOwnerFacts()[0]?.origin).toBe("owner");
  });

  test("refuses to demote: a body naming any other origin is a 400", async () => {
    // The one that matters. Provenance only means anything if it can move in
    // exactly one direction -- towards "the user personally vouched for this".
    // A route that accepted an arbitrary origin would let anything holding the
    // socket relabel its own writes as owner-authored, or quietly re-flag a
    // fact the user already cleared.
    const store = makeStore();
    const id = store.recordOwnerFact("The owner's name is Diyi.", "owner");
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    for (const origin of ["untrusted", "agent", "system"]) {
      const response = await router(patch(`/memory/owner-facts/${id}`, { origin }));

      expect(response.status).toBe(400);
      const body = (await response.json()) as { error: string };
      expect(body.error).toBe("origin_must_be_owner");
      expect(store.allOwnerFacts()[0]?.origin).toBe("owner");
    }
  });

  test("a rejected demotion does not touch an untrusted fact either", async () => {
    const store = makeStore();
    const id = store.recordOwnerFact("Planted.", "untrusted");
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(patch(`/memory/owner-facts/${id}`, { origin: "system" }));

    expect(response.status).toBe(400);
    expect(store.allOwnerFacts()[0]?.origin).toBe("untrusted");
  });

  test("confirming one fact leaves the others alone", async () => {
    const store = makeStore();
    const confirmed = store.recordOwnerFact("Confirm me.", "untrusted");
    store.recordOwnerFact("Leave me untrusted.", "untrusted");
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    await router(patch(`/memory/owner-facts/${confirmed}`));

    const byContent = new Map(store.allOwnerFacts().map((f) => [f.content, f.origin]));
    expect(byContent.get("Confirm me.")).toBe("owner");
    expect(byContent.get("Leave me untrusted.")).toBe("untrusted");
  });
});

describe("POST /memory/consolidation-runs/:id/rollback", () => {
  // `rollbackRun` (consolidator.ts) already exists and is fully implemented —
  // this route is the only thing missing to reach it from the Memory panel's
  // upcoming 回滚 button. The load-bearing assertion is a REAL round trip
  // through the store via the actual `/memory/consolidate-now` route (not a
  // hand-seeded run row): a route that only checked the response envelope
  // would pass against an implementation that never called `rollbackRun` at
  // all.
  test("rolls back a real consolidation run: restores entity_terms to its pre-run state and marks the run rolledBackAt", async () => {
    const store = makeStore();
    seedEvents(store, 5);
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

    expect(store.allTerms()).toHaveLength(0);

    const consolidateResponse = await router(post("/memory/consolidate-now"));
    const consolidateBody = (await consolidateResponse.json()) as {
      result: { ranRunId: number | null };
    };
    const runId = consolidateBody.result.ranRunId;
    expect(runId).not.toBeNull();
    // The run actually changed the store -- otherwise "restores" below would
    // trivially hold even if rollback did nothing.
    expect(store.allTerms()).toHaveLength(1);

    const response = await router(post(`/memory/consolidation-runs/${runId}/rollback`));

    expect(response.status).toBe(200);
    const body = (await response.json()) as { run: Record<string, unknown> };
    expect(body.run).toMatchObject({ id: runId });
    expect(body.run.rolledBackAt).not.toBeNull();

    // The store is back to its pre-run state.
    expect(store.allTerms()).toHaveLength(0);

    // The run row itself is stamped, which is what the panel's rolled-back
    // rendering (`MemoryViews.swift`'s 「已回滚」 badge) keys off of.
    const runRow = store.db
      .query("SELECT rolledBackAt FROM memory_consolidation_runs WHERE id = ?")
      .get(runId) as { rolledBackAt: number | null };
    expect(runRow.rolledBackAt).not.toBeNull();

    // GET /memory/consolidation-runs reflects it too -- that's the actual
    // response the panel re-renders from after the rollback button is used.
    const listResponse = await router(get("/memory/consolidation-runs"));
    const listBody = (await listResponse.json()) as {
      runs: Array<{ id: number; rolledBackAt: number | null }>;
    };
    expect(listBody.runs.find((r) => r.id === runId)?.rolledBackAt).not.toBeNull();
  });

  test("404 on an unknown run id, not a throw or a silent success", async () => {
    const store = makeStore();
    seedEvents(store, 5);
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const consolidateResponse = await router(post("/memory/consolidate-now"));
    const { result } = (await consolidateResponse.json()) as {
      result: { ranRunId: number | null };
    };
    const runId = result.ranRunId as number;
    // Roll back the real id first, so this test can only pass once the route
    // actually exists -- a *missing* route also answers 404, same reasoning
    // as the neighbouring 404 tests in this file.
    expect((await router(post(`/memory/consolidation-runs/${runId}/rollback`))).status).toBe(200);

    const response = await router(post(`/memory/consolidation-runs/${runId + 999}/rollback`));

    expect(response.status).toBe(404);
    const body = (await response.json()) as { error: string };
    expect(body.error).toBe("consolidation_run_not_found");
  });

  test("400 on a non-numeric run id, not a crash", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(post("/memory/consolidation-runs/not-an-id/rollback"));

    expect(response.status).toBe(400);
    const body = (await response.json()) as { error: string };
    expect(body.error).toBe("invalid_id");
  });

  test("rolling back an already-rolled-back run a second time is a no-op that does not touch the store or re-stamp the run", async () => {
    // Pins `rollbackRun`'s own guard (consolidator.ts:551): once
    // `rolledBackAt !== null` it returns immediately without repeating the
    // DELETE-then-reinsert restore. The route must not route around that
    // guard (e.g. by re-running the restore itself) -- a second rollback of
    // the same run has to be inert, not merely non-throwing.
    const store = makeStore();
    seedEvents(store, 5);
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

    const consolidateResponse = await router(post("/memory/consolidate-now"));
    const { result } = (await consolidateResponse.json()) as {
      result: { ranRunId: number | null };
    };
    const runId = result.ranRunId as number;

    const first = await router(post(`/memory/consolidation-runs/${runId}/rollback`));
    expect(first.status).toBe(200);
    const firstRolledBackAt = (
      store.db
        .query("SELECT rolledBackAt FROM memory_consolidation_runs WHERE id = ?")
        .get(runId) as { rolledBackAt: number }
    ).rolledBackAt;
    expect(firstRolledBackAt).not.toBeNull();

    // Add a term the first rollback's restored snapshot knows nothing about.
    // If a second rollback re-ran the restore (DELETE entity_terms + reinsert
    // the snapshot), this row would be silently wiped -- that's the
    // corruption this test exists to catch.
    const extraId = seedTerm(store, { canonicalTerm: "Manually Added After Rollback" });

    const second = await router(post(`/memory/consolidation-runs/${runId}/rollback`));

    expect(second.status).toBe(200);
    const secondRolledBackAt = (
      store.db
        .query("SELECT rolledBackAt FROM memory_consolidation_runs WHERE id = ?")
        .get(runId) as { rolledBackAt: number }
    ).rolledBackAt;
    // Unchanged -- the guard's early return means the second call never
    // re-stamps rolledBackAt with a new timestamp.
    expect(secondRolledBackAt).toBe(firstRolledBackAt);
    // The store is untouched by the second call.
    expect(store.allTerms().some((t) => t.id === extraId)).toBe(true);
  });
});

describe("POST /memory/consolidation-runs/:id/rollback -- reverse-order rule", () => {
  // `rollbackRun` (consolidator.ts) restores a FULL-TABLE snapshot taken
  // *before* the run being undone, not a diff. That's a sound undo *stack*
  // and an unsound undo *of an arbitrary element*: the snapshot for an
  // earlier run predates a later run's existence, so restoring it erases
  // whatever the later run added -- while the later run's own row is left
  // claiming `rolledBackAt: null`, i.e. the run log would lie. A probe
  // against the real (untouched) `rollbackRun`/`runConsolidation` confirmed
  // this concretely: rolling back an older run while a newer one is still
  // active wipes the newer run's term too, silently.
  //
  // The fix isn't to teach the snapshot to be a diff -- it's to only ever
  // pop the stack from the top. A run is eligible for rollback iff (1) it is
  // not already rolled back, and (2) every run that ran after it has already
  // been rolled back. That guard lives at the ROUTE (not inside
  // `rollbackRun`, which stays untouched), so it holds for any caller.
  //
  // Real row order, confirmed against `MemoryStore.listConsolidationRuns()`
  // (routes.ts / MemoryStore.ts): `ORDER BY ranAt DESC` -- newest run first.

  test("rolls back the newest run (top of the stack): 200, only that run is stamped, the older run's term survives", async () => {
    const store = makeStore();
    seedEvents(store, 3);
    let router = createRouter(
      buildMemoryRoutes(store, async () =>
        JSON.stringify({
          candidates: [
            { canonicalTerm: "Org A", aliases: [], category: "org", confidence: 0.95, supportingEventIds: [1] },
          ],
        })
      )
    );
    const runAId = (
      (await (await router(post("/memory/consolidate-now"))).json()) as {
        result: { ranRunId: number | null };
      }
    ).result.ranRunId as number;

    seedEvents(store, 3);
    router = createRouter(
      buildMemoryRoutes(store, async () =>
        JSON.stringify({
          candidates: [
            { canonicalTerm: "Org B", aliases: [], category: "org", confidence: 0.95, supportingEventIds: [2] },
          ],
        })
      )
    );
    const runBId = (
      (await (await router(post("/memory/consolidate-now"))).json()) as {
        result: { ranRunId: number | null };
      }
    ).result.ranRunId as number;

    expect(store.allTerms().map((t) => t.canonicalTerm).sort()).toEqual(["Org A", "Org B"]);

    router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    const response = await router(post(`/memory/consolidation-runs/${runBId}/rollback`));

    expect(response.status).toBe(200);
    expect(store.allTerms().map((t) => t.canonicalTerm)).toEqual(["Org A"]);

    const runARow = store.db
      .query("SELECT rolledBackAt FROM memory_consolidation_runs WHERE id = ?")
      .get(runAId) as { rolledBackAt: number | null };
    const runBRow = store.db
      .query("SELECT rolledBackAt FROM memory_consolidation_runs WHERE id = ?")
      .get(runBId) as { rolledBackAt: number | null };
    expect(runARow.rolledBackAt).toBeNull();
    expect(runBRow.rolledBackAt).not.toBeNull();
  });

  test("409 rollback_out_of_order when rolling back a run while a later run is still active, and the store is completely untouched", async () => {
    const store = makeStore();
    seedEvents(store, 3);
    let router = createRouter(
      buildMemoryRoutes(store, async () =>
        JSON.stringify({
          candidates: [
            { canonicalTerm: "Org A", aliases: [], category: "org", confidence: 0.95, supportingEventIds: [1] },
          ],
        })
      )
    );
    const runAId = (
      (await (await router(post("/memory/consolidate-now"))).json()) as {
        result: { ranRunId: number | null };
      }
    ).result.ranRunId as number;

    seedEvents(store, 3);
    router = createRouter(
      buildMemoryRoutes(store, async () =>
        JSON.stringify({
          candidates: [
            { canonicalTerm: "Org B", aliases: [], category: "org", confidence: 0.95, supportingEventIds: [2] },
          ],
        })
      )
    );
    const runBId = (
      (await (await router(post("/memory/consolidate-now"))).json()) as {
        result: { ranRunId: number | null };
      }
    ).result.ranRunId as number;

    const termsBefore = store.allTerms().map((t) => t.canonicalTerm).sort();
    expect(termsBefore).toEqual(["Org A", "Org B"]);

    router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    // A is not the top of the stack -- B ran after it and is still active.
    const response = await router(post(`/memory/consolidation-runs/${runAId}/rollback`));

    expect(response.status).toBe(409);
    const body = (await response.json()) as { error: string };
    expect(body.error).toBe("rollback_out_of_order");

    // The load-bearing half: a 409 that still mutated the table would be
    // worse than no guard at all.
    expect(store.allTerms().map((t) => t.canonicalTerm).sort()).toEqual(termsBefore);
    const runARow = store.db
      .query("SELECT rolledBackAt FROM memory_consolidation_runs WHERE id = ?")
      .get(runAId) as { rolledBackAt: number | null };
    const runBRow = store.db
      .query("SELECT rolledBackAt FROM memory_consolidation_runs WHERE id = ?")
      .get(runBId) as { rolledBackAt: number | null };
    expect(runARow.rolledBackAt).toBeNull();
    expect(runBRow.rolledBackAt).toBeNull();
  });

  test("walks the stack down rather than only ever allowing the newest row: three runs rolled back C, then B, then A each succeed and stamp only themselves", async () => {
    const store = makeStore();
    seedEvents(store, 3);
    let router = createRouter(
      buildMemoryRoutes(store, async () =>
        JSON.stringify({
          candidates: [
            { canonicalTerm: "Org A", aliases: [], category: "org", confidence: 0.95, supportingEventIds: [1] },
          ],
        })
      )
    );
    const runAId = (
      (await (await router(post("/memory/consolidate-now"))).json()) as {
        result: { ranRunId: number | null };
      }
    ).result.ranRunId as number;

    seedEvents(store, 3);
    router = createRouter(
      buildMemoryRoutes(store, async () =>
        JSON.stringify({
          candidates: [
            { canonicalTerm: "Org B", aliases: [], category: "org", confidence: 0.95, supportingEventIds: [2] },
          ],
        })
      )
    );
    const runBId = (
      (await (await router(post("/memory/consolidate-now"))).json()) as {
        result: { ranRunId: number | null };
      }
    ).result.ranRunId as number;

    seedEvents(store, 3);
    router = createRouter(
      buildMemoryRoutes(store, async () =>
        JSON.stringify({
          candidates: [
            { canonicalTerm: "Org C", aliases: [], category: "org", confidence: 0.95, supportingEventIds: [3] },
          ],
        })
      )
    );
    const runCId = (
      (await (await router(post("/memory/consolidate-now"))).json()) as {
        result: { ranRunId: number | null };
      }
    ).result.ranRunId as number;

    expect(store.allTerms().map((t) => t.canonicalTerm).sort()).toEqual(["Org A", "Org B", "Org C"]);

    router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    function rolledBackAt(runId: number): number | null {
      return (
        store.db
          .query("SELECT rolledBackAt FROM memory_consolidation_runs WHERE id = ?")
          .get(runId) as { rolledBackAt: number | null }
      ).rolledBackAt;
    }

    // Pop C -- the top of the stack. B and A are unaffected.
    const rollbackC = await router(post(`/memory/consolidation-runs/${runCId}/rollback`));
    expect(rollbackC.status).toBe(200);
    expect(store.allTerms().map((t) => t.canonicalTerm).sort()).toEqual(["Org A", "Org B"]);
    expect(rolledBackAt(runCId)).not.toBeNull();
    expect(rolledBackAt(runBId)).toBeNull();
    expect(rolledBackAt(runAId)).toBeNull();

    // Now B is the top of the (remaining active) stack -- not because it is
    // the physically newest ROW, but because C above it is already rolled
    // back. This is the case the "newest row only" hard-coding would miss.
    const rollbackB = await router(post(`/memory/consolidation-runs/${runBId}/rollback`));
    expect(rollbackB.status).toBe(200);
    expect(store.allTerms().map((t) => t.canonicalTerm)).toEqual(["Org A"]);
    expect(rolledBackAt(runBId)).not.toBeNull();
    expect(rolledBackAt(runAId)).toBeNull();

    // Finally A, now that both runs after it are rolled back.
    const rollbackA = await router(post(`/memory/consolidation-runs/${runAId}/rollback`));
    expect(rollbackA.status).toBe(200);
    expect(store.allTerms()).toHaveLength(0);
    expect(rolledBackAt(runAId)).not.toBeNull();
  });
});

// Closes docs/superpowers/specs/2026-08-09-current-system-state.md §11's
// "context-debug.log has no governance" gap, the "not cleared by the reset
// input history action" third. This route is the HTTP exit for
// `contextDebugLog.ts`'s `clearContextUsageLog` (see
// `test/oneshot/contextDebugLog.test.ts` for that primitive's own coverage).
//
// ASSUMPTION flagged for review: `buildMemoryRoutes` is assumed to grow a
// third, trailing *optional* parameter -- `contextLogPath?: string` -- so
// every pre-existing call in this file (`buildMemoryRoutes(store,
// noOpCallLLM())`, unchanged above) keeps compiling untouched. This mirrors
// the existing trailing-optional-parameter convention `buildApp` already
// uses for `spillRoot?`/`runLogRoot?` in `src/server.ts`. `main()`'s real
// wiring is expected to pass `env.contextLogPath` (see `src/env.ts`) as this
// third argument, the same way it already passes `env.dbPath` etc.
describe("DELETE /memory/context-log", () => {
  test("clears the context log file and its rotated generation, returning the shared delete envelope", async () => {
    const dir = mkdtempSync(join(tmpdir(), "opentype-context-log-route-"));
    const path = join(dir, "context-debug.log");
    try {
      writeFileSync(path, "some logged input\n");
      writeFileSync(`${path}.1`, "an older generation\n");
      const store = makeStore();
      const router = createRouter(buildMemoryRoutes(store, noOpCallLLM(), path));

      const response = await router(del("/memory/context-log"));

      expect(response.status).toBe(200);
      // Same envelope shape as the neighbouring DELETE /memory/terms/:id and
      // DELETE /memory/owner-facts/:id routes above.
      expect(await response.json()).toEqual({ deleted: true });
      expect(existsSync(path)).toBe(false);
      expect(existsSync(`${path}.1`)).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("is a 200 no-op success when there is nothing to delete, not a 404", async () => {
    const dir = mkdtempSync(join(tmpdir(), "opentype-context-log-route-"));
    const path = join(dir, "context-debug.log");
    try {
      const store = makeStore();
      const router = createRouter(buildMemoryRoutes(store, noOpCallLLM(), path));

      const response = await router(del("/memory/context-log"));

      // Unlike the id-addressed term/owner-fact deletes, this route has no
      // "unknown id" concept -- it clears a file that may or may not exist,
      // and idempotent-clear-of-nothing is success, matching
      // `clearContextUsageLog`'s own no-op contract.
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ deleted: true });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("does not touch entity terms or owner facts", async () => {
    const dir = mkdtempSync(join(tmpdir(), "opentype-context-log-route-"));
    const path = join(dir, "context-debug.log");
    try {
      writeFileSync(path, "some logged input\n");
      const store = makeStore();
      seedTerm(store);
      store.recordOwnerFact("Keep me.");
      const router = createRouter(buildMemoryRoutes(store, noOpCallLLM(), path));

      const response = await router(del("/memory/context-log"));

      // Without pinning the status here, this test passes vacuously against
      // a *missing* route too (a 404 fallthrough never touches the store
      // either) -- which would defeat the point of a dedicated "does not
      // touch" test. Asserting 200 ties these checks to a route that
      // actually ran.
      expect(response.status).toBe(200);
      expect(store.allTerms()).toHaveLength(1);
      expect(store.allOwnerFacts()).toHaveLength(1);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
