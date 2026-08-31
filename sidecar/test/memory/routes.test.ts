import { describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { ConversationStore } from "../../src/memory/conversations";
import { buildRecentActivityContext } from "../../src/memory/recentActivity";
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

/**
 * Single-row counterpart to `seedEvents` above, for the GET/DELETE
 * `/memory/events` tests below, which need to control mode/applicationName/
 * transcript per row (ordering and mode-filter assertions read the exact
 * values back) rather than the fixed transcribe/"TestApp" shape `seedEvents`
 * bakes in. Returns the new row's id.
 */
function seedEvent(
  store: MemoryStore,
  overrides: Partial<{
    mode: string;
    rawTranscript: string;
    correctedTranscript: string;
    applicationName: string;
  }> = {}
): number {
  const values = {
    mode: "transcribe",
    rawTranscript: "raw",
    correctedTranscript: "corrected",
    applicationName: "TestApp",
    ...overrides,
  };
  return store.recordEpisodicEvent({
    mode: values.mode,
    rawTranscript: values.rawTranscript,
    correctedTranscript: values.correctedTranscript,
    effectiveInput: null,
    selectedContext: null,
    result: null,
    applicationName: values.applicationName,
  });
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

/**
 * Design §3.2 / plan Task 3: the single write path into `episodic_events`,
 * replacing the three sidecar-side writers (`/asr/transcribe`,
 * `/oneshot/ask`, `/agent/run`) that each knew only part of the truth.
 * Swift calls this at delivery time, when it actually knows the mode, the
 * frontmost app, the final delivered text, and the right `origin` -- so this
 * route's whole job is to accept exactly what the caller sends and store it
 * unchanged, not to infer or default away any of the facts that motivated
 * the move (see `test/memory/episodicWiring.test.ts` for the other half:
 * proving the three old writers no longer write).
 */
describe("POST /memory/events", () => {
  test("records exactly one row and returns the new row's eventId", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(
      post("/memory/events", {
        mode: "transcribe",
        rawTranscript: "原文",
        correctedTranscript: "改写后",
        effectiveInput: null,
        selectedContext: null,
        result: "交付出去的文本",
        applicationName: "WeChat",
        origin: "owner",
      })
    );

    expect(response.status).toBe(200);
    const body = (await response.json()) as { eventId: number };
    expect(body.eventId).toBeGreaterThan(0);

    // Read back through the same read path the recent-activity injection
    // uses, not a raw SELECT -- this is what proves the caller's facts
    // arrived intact, which is the entire point of this endpoint existing.
    const rows = store.recentEvents(10);
    expect(rows).toHaveLength(1);
    expect(rows[0]!.id).toBe(body.eventId);
    expect(rows[0]!.applicationName).toBe("WeChat");
    expect(rows[0]!.mode).toBe("transcribe");
    // rawTranscript/correctedTranscript are deliberately given DIFFERENT
    // values here and both asserted: this is the field-mapping rule that
    // used to live in test/asr/episodicEvent.test.ts ("rawTranscript is the
    // pre-correction ASR text, correctedTranscript the delivered text") --
    // the endpoint must keep the pair distinct, never collapse or overwrite
    // one with the other.
    expect(rows[0]!.rawTranscript).toBe("原文");
    expect(rows[0]!.correctedTranscript).toBe("改写后");
    expect(rows[0]!.result).toBe("交付出去的文本");
    expect(rows[0]!.conversationId).toBeNull();
  });

  test("every field the caller sends round-trips independently, including non-null effectiveInput and selectedContext", async () => {
    // Moves the field-mapping rule pinned by test/agent/routes.test.ts's now-
    // removed "records an episodic event with origin 'agent'" test: an
    // agent-shaped payload carries a non-null effectiveInput (the task as fed
    // to the model) and a non-null selectedContext (what was selected on
    // screen), and both must survive unchanged, not just the headline
    // mode/result/applicationName fields already covered above.
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(
      post("/memory/events", {
        mode: "agent",
        rawTranscript: "summarize my notes",
        correctedTranscript: "summarize my notes",
        effectiveInput: "summarize my notes",
        selectedContext: "note text here",
        result: "done",
        applicationName: "Notes",
        origin: "agent",
      })
    );

    expect(response.status).toBe(200);
    const row = store.recentEvents(10)[0]!;
    expect(row.mode).toBe("agent");
    expect(row.rawTranscript).toBe("summarize my notes");
    expect(row.correctedTranscript).toBe("summarize my notes");
    expect(row.effectiveInput).toBe("summarize my notes");
    expect(row.selectedContext).toBe("note text here");
    expect(row.result).toBe("done");
    expect(row.applicationName).toBe("Notes");
    expect(row.origin).toBe("agent");
  });

  // Moves the field-mapping rule pinned by test/agent/routes.test.ts's now-
  // removed "records selectedContext as null when no context is provided"
  // test: transcribe (and any mode with no LLM stage) sends `null` for both
  // `effectiveInput` and `selectedContext`, and the endpoint must store real
  // SQL NULL, not silently coerce it into `""` or a stringified `"null"`.
  // The earlier round-trip test above only sends non-null values for these
  // two fields, so without this nothing would catch an implementation doing
  // e.g. `effectiveInput: body.effectiveInput ?? ""`.
  test("null effectiveInput and selectedContext round-trip as null, not coerced to empty string or 'null'", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    await router(
      post("/memory/events", {
        mode: "transcribe",
        rawTranscript: "hello world",
        correctedTranscript: "hello world",
        effectiveInput: null,
        selectedContext: null,
        result: "hello world",
        applicationName: "TextEdit",
        origin: "owner",
      })
    );

    const row = store.recentEvents(10)[0]!;
    expect(row.effectiveInput).toBeNull();
    expect(row.selectedContext).toBeNull();
  });

  // Pins the reference handler's three defaults (design §3.2's step-3 sketch:
  // `applicationName ?? "Unknown"`, `correctedTranscript ?? rawTranscript`,
  // `origin ?? "owner"`), each of which no existing test exercises while
  // still supplying the two required fields (`mode`, `rawTranscript`).
  // Omitting a field here must default it, not 400 -- only `mode` and
  // `rawTranscript` are required (see the "missing X returns 400" tests
  // above).
  test("omitting applicationName, correctedTranscript, and origin fills in the documented defaults", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(
      post("/memory/events", {
        mode: "transcribe",
        rawTranscript: "hello world",
        effectiveInput: null,
        selectedContext: null,
        result: null,
      })
    );

    expect(response.status).toBe(200);
    const row = store.recentEvents(10)[0]!;
    expect(row.applicationName).toBe("Unknown");
    // Defaults to the rawTranscript itself, not to an empty string or null --
    // an omitted correction means "nothing was rewritten", which the
    // caller expresses by leaving the field out rather than repeating it.
    expect(row.correctedTranscript).toBe("hello world");
    expect(row.origin).toBe("owner");
  });

  test("omitted conversationId stores NULL", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    await router(
      post("/memory/events", {
        mode: "ask",
        rawTranscript: "what is 2+2",
        correctedTranscript: "what is 2+2",
        effectiveInput: "what is 2+2",
        selectedContext: null,
        result: "Four.",
        applicationName: "OpenType",
        origin: "agent",
      })
    );

    const rows = store.recentEvents(10);
    expect(rows).toHaveLength(1);
    expect(rows[0]!.conversationId).toBeNull();
  });

  test("a supplied conversationId is stored as sent", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    await router(
      post("/memory/events", {
        mode: "agent",
        rawTranscript: "summarize my notes",
        correctedTranscript: "summarize my notes",
        effectiveInput: "summarize my notes",
        selectedContext: "note text",
        result: "done",
        applicationName: "OpenType",
        origin: "agent",
        conversationId: 42,
      })
    );

    const rows = store.recentEvents(10);
    expect(rows[0]!.conversationId).toBe(42);
  });

  test("origin 'agent' is honoured as sent -- ask/agent turns need it to gate consolidation's owner-facts source", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    await router(
      post("/memory/events", {
        mode: "ask",
        rawTranscript: "what is 2+2",
        correctedTranscript: "what is 2+2",
        effectiveInput: "what is 2+2",
        selectedContext: null,
        result: "Four.",
        applicationName: "OpenType",
        origin: "agent",
      })
    );

    expect(store.recentEvents(10)[0]!.origin).toBe("agent");
  });

  test("origin 'owner' is honoured as sent -- a dictation turn is the owner's own words, no model in the loop", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    await router(
      post("/memory/events", {
        mode: "transcribe",
        rawTranscript: "hello world",
        correctedTranscript: "hello world",
        effectiveInput: null,
        selectedContext: null,
        result: "hello world",
        applicationName: "TextEdit",
        origin: "owner",
      })
    );

    expect(store.recentEvents(10)[0]!.origin).toBe("owner");
  });

  test("missing mode returns 400 and writes nothing", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(
      post("/memory/events", {
        rawTranscript: "hello world",
        correctedTranscript: "hello world",
        effectiveInput: null,
        selectedContext: null,
        result: "hello world",
        applicationName: "TextEdit",
        origin: "owner",
      })
    );

    expect(response.status).toBe(400);
    expect(store.recentEvents(10)).toEqual([]);
  });

  // This is now the one choke point every memory write passes through, which
  // is exactly why a boundary check here actually holds: a typo or a future
  // Swift-side refactor that sends a wrong mode string would otherwise write
  // silently, and the mismatch would only surface downstream (the JSONL
  // recent-activity renderer, or a consolidation pass) with no link back to
  // the write that caused it. Mirrors the `ENTITY_CATEGORIES` /
  // `invalid_category` guard already in this file for entity terms.
  test("an unknown mode string returns 400 and writes nothing", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(
      post("/memory/events", {
        mode: "polish",
        rawTranscript: "hello world",
        correctedTranscript: "hello world",
        effectiveInput: null,
        selectedContext: null,
        result: "hello world",
        applicationName: "TextEdit",
        origin: "owner",
      })
    );

    expect(response.status).toBe(400);
    expect(store.recentEvents(10)).toEqual([]);
  });

  // The failure mode a guard can introduce is worse than the one it
  // prevents: a check that accidentally rejects a real mode would silently
  // stop recording one whole mode's history, and nothing downstream would
  // report it (the caller is best-effort and swallows the failure). All
  // three of today's actual modes must keep passing.
  test.each(["transcribe", "ask", "agent"] as const)(
    "mode %p is accepted, not rejected by the mode guard",
    async (mode) => {
      const store = makeStore();
      const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

      const response = await router(
        post("/memory/events", {
          mode,
          rawTranscript: "hello world",
          correctedTranscript: "hello world",
          effectiveInput: null,
          selectedContext: null,
          result: "hello world",
          applicationName: "TextEdit",
          origin: "owner",
        })
      );

      expect(response.status).toBe(200);
      expect(store.recentEvents(10)).toHaveLength(1);
    }
  );

  test("missing rawTranscript returns 400 and writes nothing", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(
      post("/memory/events", {
        mode: "transcribe",
        correctedTranscript: "hello world",
        effectiveInput: null,
        selectedContext: null,
        result: "hello world",
        applicationName: "TextEdit",
        origin: "owner",
      })
    );

    expect(response.status).toBe(400);
    expect(store.recentEvents(10)).toEqual([]);
  });

  test("an entirely empty body returns 400 and writes nothing", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(post("/memory/events", {}));

    expect(response.status).toBe(400);
    expect(store.recentEvents(10)).toEqual([]);
  });

  // The silent-recording guard that used to live in `asr/routes.ts`'s
  // `recordDictation` ("if (rawTranscript.trim() === '') return;"). An
  // accidental hotkey press produces a transcript with nothing learnable in
  // it, and five of them would otherwise satisfy `shouldConsolidate`'s
  // `>= 5 unconsolidated events` gate and burn a real LLM consolidation call
  // on nothing. Now that writing moved out of `/asr/transcribe` (the one
  // caller that used to own this check) into this single shared endpoint,
  // the guard has to live HERE: a check that lived in the old caller would
  // have to be re-remembered by every future caller of this endpoint, and a
  // guard the one shared write path enforces cannot be forgotten by any of
  // them. Answering 400 rather than silently accepting-and-ignoring, because
  // every call into this endpoint is already best-effort from the Swift side
  // (failures are swallowed there and never surface to the user) -- a clear
  // rejection costs the caller nothing and is far easier to debug than a 200
  // that quietly wrote nothing.
  test("an empty rawTranscript returns 400 and writes nothing -- a silent recording has nothing learnable in it", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(
      post("/memory/events", {
        mode: "transcribe",
        rawTranscript: "",
        correctedTranscript: "",
        effectiveInput: null,
        selectedContext: null,
        result: "",
        applicationName: "TextEdit",
        origin: "owner",
      })
    );

    expect(response.status).toBe(400);
    expect(store.recentEvents(10)).toEqual([]);
  });

  test("a whitespace-only rawTranscript returns 400 and writes nothing -- same silent-recording guard, not just the exact-empty-string case", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(
      post("/memory/events", {
        mode: "transcribe",
        rawTranscript: "  \n\t ",
        correctedTranscript: "  \n\t ",
        effectiveInput: null,
        selectedContext: null,
        result: "  \n\t ",
        applicationName: "TextEdit",
        origin: "owner",
      })
    );

    expect(response.status).toBe(400);
    expect(store.recentEvents(10)).toEqual([]);
  });
});

/**
 * Design §3.7 / plan Task 6: the read/delete surface behind the dictation
 * history page. Once Swift's local `history.json` is deleted (Task 8), that
 * page reads `episodic_events` through this endpoint instead of a local
 * file, so this is the whole data source for a UI a user looks at directly
 * -- unlike `recentEvents` (MemoryStore.ts), which exists to feed a model
 * prompt and nobody ever reads by eye.
 */
describe("GET /memory/events", () => {
  test("returns rows newest-first -- the opposite direction from recentEvents, which returns oldest-first for model context. A list UI reads top-down from most recent, so getting this backwards would show the user their oldest dictation first and read as data loss", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    seedEvent(store, { correctedTranscript: "一" });
    seedEvent(store, { correctedTranscript: "二" });
    seedEvent(store, { correctedTranscript: "三" });

    const response = await router(get("/memory/events"));

    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      events: Array<{ correctedTranscript: string }>;
    };
    expect(body.events.map((e) => e.correctedTranscript)).toEqual(["三", "二", "一"]);

    // Proof this isn't just recentEvents with the response reshaped: that
    // method is pinned to the opposite (oldest-first) order for the model.
    expect(store.recentEvents(10).map((e) => e.correctedTranscript)).toEqual([
      "一",
      "二",
      "三",
    ]);
  });

  test("limit is honoured: returns only the newest `limit` rows", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    seedEvent(store, { correctedTranscript: "一" });
    seedEvent(store, { correctedTranscript: "二" });
    seedEvent(store, { correctedTranscript: "三" });

    const response = await router(get("/memory/events?limit=2"));

    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      events: Array<{ correctedTranscript: string }>;
    };
    expect(body.events.map((e) => e.correctedTranscript)).toEqual(["三", "二"]);
  });

  // Decision (this task): the default, when `limit` is absent, is 200 -- the
  // exact value plan Task 7's `AppModel.refreshHistory()` is written to pass
  // explicitly (`GET /memory/events?limit=200`). Picking the same number
  // means an omitted limit and that call's explicit one behave identically,
  // so nothing downstream can observe a difference between "the client typed
  // 200" and "the client typed nothing". 200 is also large enough to hold a
  // history page's worth of rows without the caller having to think about
  // pagination for an ordinary user's day.
  test("an absent limit does not truncate a small result set", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    for (let i = 0; i < 5; i++) {
      seedEvent(store, { correctedTranscript: `event ${i}` });
    }

    const response = await router(get("/memory/events"));

    const body = (await response.json()) as { events: unknown[] };
    expect(body.events).toHaveLength(5);
  });

  test("the default limit is exactly 200, not merely 'large enough'", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    for (let i = 0; i < 201; i++) {
      seedEvent(store, { correctedTranscript: `event ${i}` });
    }

    const response = await router(get("/memory/events"));

    const body = (await response.json()) as {
      events: Array<{ correctedTranscript: string }>;
    };
    expect(body.events).toHaveLength(200);
    // And still the newest 200, not an arbitrary 200 -- the very oldest row
    // ("event 0") must be the one left out.
    expect(body.events.every((e) => e.correctedTranscript !== "event 0")).toBe(true);
  });

  test("mode= filters to exactly that mode", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    seedEvent(store, { mode: "transcribe", correctedTranscript: "听写" });
    seedEvent(store, { mode: "ask", correctedTranscript: "问答" });
    seedEvent(store, { mode: "agent", correctedTranscript: "代理" });

    const response = await router(get("/memory/events?mode=ask"));

    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      events: Array<{ mode: string; correctedTranscript: string }>;
    };
    expect(body.events).toHaveLength(1);
    expect(body.events[0]?.mode).toBe("ask");
    expect(body.events[0]?.correctedTranscript).toBe("问答");
  });

  test("an absent mode returns all three modes", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    seedEvent(store, { mode: "transcribe" });
    seedEvent(store, { mode: "ask" });
    seedEvent(store, { mode: "agent" });

    const response = await router(get("/memory/events"));

    expect(response.status).toBe(200);
    const body = (await response.json()) as { events: Array<{ mode: string }> };
    expect(body.events.map((e) => e.mode).sort()).toEqual(["agent", "ask", "transcribe"]);
  });

  test("mode and limit compose: the newest `limit` rows within the filtered mode, not the newest `limit` rows overall then filtered", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    seedEvent(store, { mode: "ask", correctedTranscript: "一" });
    seedEvent(store, { mode: "transcribe", correctedTranscript: "listen" });
    seedEvent(store, { mode: "ask", correctedTranscript: "二" });
    seedEvent(store, { mode: "ask", correctedTranscript: "三" });

    const response = await router(get("/memory/events?mode=ask&limit=2"));

    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      events: Array<{ correctedTranscript: string }>;
    };
    expect(body.events.map((e) => e.correctedTranscript)).toEqual(["三", "二"]);
  });

  test("an empty store returns an empty list, not an error", async () => {
    const router = createRouter(buildMemoryRoutes(makeStore(), noOpCallLLM()));

    const response = await router(get("/memory/events"));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ events: [] });
  });
});

/**
 * Design §3.6's clamp note applies to every read path over `episodic_events`,
 * not just `opentype__read_history` -- this is the second of the two the
 * spec names explicitly. SQLite reads a negative `LIMIT` as "unbounded", so
 * an un-clamped `?limit=-1` here would hand back the user's ENTIRE dictation
 * history in one response -- exactly the exposure the tool's clamp exists to
 * prevent, just reached through the HTTP route instead of the agent tool.
 *
 * Contract (same *shape* as the tool's, per spec §3.6's closing paragraph,
 * deliberately different *numbers*): any `limit` that is not a positive
 * integer -- omitted, zero, negative, or non-integer -- falls back to the
 * endpoint's own default (200, pinned above); anything above a ceiling
 * clamps down to it instead of passing through or crashing.
 *
 * Ceiling chosen: 200, the same number as the default, rather than a second
 * invented constant. `opentype__read_history` deliberately keeps its default
 * (10) and ceiling (50) apart, because it exists to bound what reaches a
 * model's context -- a small default is worth having even though a caller
 * may legitimately want to ask for more in one call. This endpoint bounds a
 * list a person scrolls through, and an absent `limit` already returns as
 * much as this endpoint considers "enough for one screenful of history" --
 * there is no separate reason a caller should be able to ask for MORE than
 * that via an explicit value, so default and ceiling coinciding at 200 is
 * the natural single-number contract rather than two numbers to reason
 * about. If that changes, this test (and its sibling above pinning the
 * default) are where to change it.
 */
describe("GET /memory/events limit clamping", () => {
  // Every case below seeds well past the ceiling and asserts the exact
  // returned count -- not just "did not throw" -- because an implementation
  // that merely avoids a crash (e.g. `Number("abc") || 200`, which happens to
  // work) could still leave the *negative* case unbounded, and a assertion
  // that only checks `response.status === 200` would not catch that.
  const CEILING = 200;

  function seedPastCeiling(store: MemoryStore): void {
    for (let i = 0; i < CEILING + 50; i++) {
      seedEvent(store, { correctedTranscript: `event ${i}` });
    }
  }

  test("limit=abc (non-numeric): falls back to the default, not a 500 from an unbindable NaN", async () => {
    const store = makeStore();
    seedPastCeiling(store);
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(get("/memory/events?limit=abc"));

    expect(response.status).toBe(200);
    const body = (await response.json()) as { events: unknown[] };
    expect(body.events).toHaveLength(CEILING);
  });

  test("limit=-1: clamps to the default rather than reading the SQLite 'negative LIMIT means unbounded' behavior -- the security-relevant case", async () => {
    const store = makeStore();
    seedPastCeiling(store);
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(get("/memory/events?limit=-1"));

    expect(response.status).toBe(200);
    const body = (await response.json()) as { events: unknown[] };
    // The load-bearing assertion: more rows exist than this, so an
    // implementation that let -1 through to SQLite unbounded would return
    // CEILING + 50, not CEILING.
    expect(body.events).toHaveLength(CEILING);
  });

  test("limit=0: falls back to the default, not an empty list", async () => {
    const store = makeStore();
    seedPastCeiling(store);
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(get("/memory/events?limit=0"));

    expect(response.status).toBe(200);
    const body = (await response.json()) as { events: unknown[] };
    expect(body.events).toHaveLength(CEILING);
  });

  test("limit=1.5 (non-integer): falls back to the default rather than truncating or rounding", async () => {
    const store = makeStore();
    seedPastCeiling(store);
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(get("/memory/events?limit=1.5"));

    expect(response.status).toBe(200);
    const body = (await response.json()) as { events: unknown[] };
    expect(body.events).toHaveLength(CEILING);
  });

  test("limit=100000 (absurdly large but syntactically valid): clamps down to the ceiling", async () => {
    const store = makeStore();
    seedPastCeiling(store);
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(get("/memory/events?limit=100000"));

    expect(response.status).toBe(200);
    const body = (await response.json()) as { events: unknown[] };
    expect(body.events).toHaveLength(CEILING);
  });
});

describe("PATCH /memory/events/:id", () => {
  test("updates only the named episodic row, preserving rawTranscript and leaving other rows untouched", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    const keepId = seedEvent(store, {
      rawTranscript: "keep raw",
      correctedTranscript: "keep corrected",
      applicationName: "Notes",
    });
    const updateId = seedEvent(store, {
      rawTranscript: "请把这笔钱通过呸泡转给他",
      correctedTranscript: "请把这笔钱通过呸泡转给他",
      applicationName: "WeChat",
    });

    const response = await router(
      patch(`/memory/events/${updateId}`, {
        correctedTranscript: "请把这笔钱通过PayPal转给他",
        result: "请把这笔钱通过PayPal转给他",
      })
    );

    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      event: {
        id: number;
        rawTranscript: string;
        correctedTranscript: string;
        result: string | null;
        applicationName: string;
      };
    };
    expect(body.event).toEqual({
      id: updateId,
      rawTranscript: "请把这笔钱通过呸泡转给他",
      correctedTranscript: "请把这笔钱通过PayPal转给他",
      result: "请把这笔钱通过PayPal转给他",
      applicationName: "WeChat",
    });

    const updated = store.getEventById(updateId);
    expect(updated).toMatchObject({
      id: updateId,
      rawTranscript: "请把这笔钱通过呸泡转给他",
      correctedTranscript: "请把这笔钱通过PayPal转给他",
      result: "请把这笔钱通过PayPal转给他",
    });

    const untouched = store.getEventById(keepId);
    expect(untouched).toMatchObject({
      id: keepId,
      rawTranscript: "keep raw",
      correctedTranscript: "keep corrected",
      result: null,
    });
  });

  test("after a patch, history reads and recent-activity context both surface the updated text", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    const id = seedEvent(store, {
      rawTranscript: "把🍣发给小王",
      correctedTranscript: "把🍣发给小王",
      applicationName: "Messages",
    });

    const patchResponse = await router(
      patch(`/memory/events/${id}`, {
        correctedTranscript: "把寿司发给小王",
        result: "把寿司发给小王",
      })
    );
    expect(patchResponse.status).toBe(200);

    const historyResponse = await router(get("/memory/events"));
    expect(historyResponse.status).toBe(200);
    const history = (await historyResponse.json()) as {
      events: Array<{ id: number; correctedTranscript: string; result: string | null }>;
    };
    expect(history.events[0]).toMatchObject({
      id,
      correctedTranscript: "把寿司发给小王",
      result: "把寿司发给小王",
    });

    const recent = buildRecentActivityContext(store.recentEvents(10), {
      includeIds: true,
    });
    const recentEntry = JSON.parse(recent.trim().split("\n")[1] ?? "") as {
      eventId: number;
      input: string;
      result: string;
    };
    expect(recentEntry).toMatchObject({
      eventId: id,
      input: "把寿司发给小王",
      result: "把寿司发给小王",
    });
  });

  test("an unknown id is a 404 once the route itself is proven to exist", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    const id = seedEvent(store, {
      correctedTranscript: "before",
    });

    const probe = await router(
      patch(`/memory/events/${id}`, {
        correctedTranscript: "after",
        result: "after",
      })
    );
    expect(probe.status).toBe(200);

    const response = await router(
      patch("/memory/events/999999", {
        correctedTranscript: "missing",
        result: "missing",
      })
    );

    expect(response.status).toBe(404);
  });

  test("a non-numeric id is a 400 invalid_id and leaves real rows untouched", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    const id = seedEvent(store, { correctedTranscript: "still here" });

    const response = await router(
      patch("/memory/events/not-an-id", {
        correctedTranscript: "missing",
        result: "missing",
      })
    );

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_id" });
    expect(store.getEventById(id)).toMatchObject({
      id,
      correctedTranscript: "still here",
      result: null,
    });
  });

  test("a negative numeric id is a 404 and leaves real rows untouched", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    const id = seedEvent(store, { correctedTranscript: "still here" });

    const probe = await router(
      patch(`/memory/events/${id}`, {
        correctedTranscript: "updated once",
        result: "updated once",
      })
    );
    expect(probe.status).toBe(200);

    const response = await router(
      patch("/memory/events/-1", {
        correctedTranscript: "missing",
        result: "missing",
      })
    );

    expect(response.status).toBe(404);
    expect(store.getEventById(id)).toMatchObject({
      id,
      correctedTranscript: "updated once",
      result: "updated once",
    });
  });

  test("missing correctedTranscript returns 400 and leaves the row untouched", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    const probeId = seedEvent(store, { correctedTranscript: "probe" });
    const targetId = seedEvent(store, { correctedTranscript: "still here" });

    const probe = await router(
      patch(`/memory/events/${probeId}`, {
        correctedTranscript: "probe updated",
        result: "probe updated",
      })
    );
    expect(probe.status).toBe(200);

    const response = await router(
      patch(`/memory/events/${targetId}`, {
        result: "missing correctedTranscript",
      })
    );

    expect(response.status).toBe(400);
    expect(store.getEventById(targetId)).toMatchObject({
      id: targetId,
      correctedTranscript: "still here",
      result: null,
    });
  });

  test("a whitespace-only correctedTranscript returns 400 and leaves the row untouched", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    const probeId = seedEvent(store, { correctedTranscript: "probe" });
    const targetId = seedEvent(store, { correctedTranscript: "before" });

    const probe = await router(
      patch(`/memory/events/${probeId}`, {
        correctedTranscript: "probe updated",
        result: "probe updated",
      })
    );
    expect(probe.status).toBe(200);

    const response = await router(
      patch(`/memory/events/${targetId}`, {
        correctedTranscript: " \n\t ",
        result: "after",
      })
    );

    expect(response.status).toBe(400);
    expect(store.getEventById(targetId)).toMatchObject({
      id: targetId,
      correctedTranscript: "before",
      result: null,
    });
  });

  test("a whitespace-only result returns 400 and leaves the row untouched", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    const probeId = seedEvent(store, { correctedTranscript: "probe" });
    const targetId = seedEvent(store, { correctedTranscript: "before" });

    const probe = await router(
      patch(`/memory/events/${probeId}`, {
        correctedTranscript: "probe updated",
        result: "probe updated",
      })
    );
    expect(probe.status).toBe(200);

    const response = await router(
      patch(`/memory/events/${targetId}`, {
        correctedTranscript: "after",
        result: " \n\t ",
      })
    );

    expect(response.status).toBe(400);
    expect(store.getEventById(targetId)).toMatchObject({
      id: targetId,
      correctedTranscript: "before",
      result: null,
    });
  });

  test("missing result returns 400 and leaves the row untouched", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    const probeId = seedEvent(store, { correctedTranscript: "probe" });
    const targetId = seedEvent(store, { correctedTranscript: "before" });

    const probe = await router(
      patch(`/memory/events/${probeId}`, {
        correctedTranscript: "probe updated",
        result: "probe updated",
      })
    );
    expect(probe.status).toBe(200);

    const response = await router(
      patch(`/memory/events/${targetId}`, {
        correctedTranscript: "after",
      })
    );

    expect(response.status).toBe(400);
    expect(store.getEventById(targetId)).toMatchObject({
      id: targetId,
      correctedTranscript: "before",
      result: null,
    });
  });
});

describe("DELETE /memory/events/:id", () => {
  test("removes exactly that row, leaving the others", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    const keepId = seedEvent(store, { correctedTranscript: "keep me" });
    const deleteId = seedEvent(store, { correctedTranscript: "delete me" });

    const response = await router(del(`/memory/events/${deleteId}`));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ deleted: true });
    const remaining = store.recentEvents(10);
    expect(remaining).toHaveLength(1);
    expect(remaining[0]?.id).toBe(keepId);
    expect(remaining[0]?.correctedTranscript).toBe("keep me");
  });

  test("a second delete of the same id is a 404 -- deleting nothing is not success", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    const id = seedEvent(store);

    // Delete a real id first, so this test can only pass once the route
    // actually exists -- a *missing* route also answers 404, same reasoning
    // as the neighbouring 404 tests for /memory/terms/:id and
    // /memory/owner-facts/:id elsewhere in this file.
    expect((await router(del(`/memory/events/${id}`))).status).toBe(200);

    const response = await router(del(`/memory/events/${id}`));

    expect(response.status).toBe(404);
  });

  // Decision (this task): a malformed id -- one that cannot be a row id at
  // all (non-numeric) -- is a 400, matching the existing `parseIdParam`
  // convention this file already uses for /memory/terms/:id and
  // /memory/owner-facts/:id (see routes.ts's `parseIdParam`). A negative
  // number, by contrast, IS a syntactically valid integer; it is simply one
  // that can never address a real row, since ids are positive AUTOINCREMENT
  // values. Treating it as an ordinary (never-matching) id and answering 404
  // is sane and requires no special-casing -- the alternative of a 400 would
  // mean deciding, arbitrarily, which negative-looking inputs count as
  // "malformed enough", when SQLite already treats -1 as a value that no row
  // has.
  test("400 on a non-numeric id -- a malformed id is a bad request, not a missing row", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    const id = seedEvent(store);

    const response = await router(del("/memory/events/abc"));

    expect(response.status).toBe(400);
    // The malformed request must not touch the store -- the real row survives.
    expect(store.recentEvents(10).some((e) => e.id === id)).toBe(true);
  });

  test("a negative id is a 404, not a 500 or an accidental delete of another row", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    const id = seedEvent(store, { correctedTranscript: "untouched" });

    // Prove the route itself exists first: a *missing* route also answers
    // 404 for "/memory/events/-1", which would make the assertion below pass
    // vacuously before this endpoint is even implemented. Deleting a real id
    // is the same "delete a real id first" pattern this file already uses
    // for the other 404 tests in this describe block.
    const probe = await router(del(`/memory/events/${id}`));
    expect(probe.status).toBe(200);

    const response = await router(del("/memory/events/-1"));

    expect(response.status).toBe(404);
    expect(store.recentEvents(10)).toHaveLength(0);
  });
});

describe("DELETE /memory/events", () => {
  test("clears every episodic row and returns how many it removed", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    seedEvent(store, { correctedTranscript: "一" });
    seedEvent(store, { correctedTranscript: "二" });
    seedEvent(store, { correctedTranscript: "三" });

    const response = await router(del("/memory/events"));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ deleted: 3 });
    expect(store.recentEvents(10)).toHaveLength(0);
  });

  // Backs the Memory panel / Settings "重置输入历史" (reset input history)
  // button. A user resetting their dictation history must not silently lose
  // the dictionary they hand-edited, the owner facts remembered about them,
  // or the conversations still visible in the sessions list -- so every one
  // of those has to be seeded here and asserted to survive, not just assumed
  // safe because the DELETE statement only names one table.
  test("leaves entity_terms, owner_facts, conversations and conversation_messages completely untouched", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));
    seedEvent(store, { correctedTranscript: "一" });
    seedEvent(store, { correctedTranscript: "二" });
    const termId = seedTerm(store, { canonicalTerm: "PayPal" });
    const factId = store.recordOwnerFact("The owner's name is Diyi.");
    const conversations = new ConversationStore(store.db);
    const conversationId = conversations.createConversation("ask", "what's the weather");
    conversations.appendMessage(conversationId, "user", "what's the weather");
    conversations.appendMessage(conversationId, "assistant", "sunny");

    const response = await router(del("/memory/events"));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ deleted: 2 });

    // The dictionary the user hand-edited must survive a history reset.
    expect(store.allTerms().find((t) => t.id === termId)).toBeDefined();
    // Same for owner facts.
    expect(store.allOwnerFacts().find((f) => f.id === factId)).toBeDefined();
    // And the conversations visible in the sessions list, messages included.
    const conversationRow = store.db
      .query("SELECT * FROM conversations WHERE id = ?")
      .get(conversationId);
    expect(conversationRow).not.toBeNull();
    const messageRows = store.db
      .query("SELECT * FROM conversation_messages WHERE conversationId = ?")
      .all(conversationId);
    expect(messageRows).toHaveLength(2);
  });

  test("deleting when there is nothing to delete returns { deleted: 0 }, not an error", async () => {
    const store = makeStore();
    const router = createRouter(buildMemoryRoutes(store, noOpCallLLM()));

    const response = await router(del("/memory/events"));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ deleted: 0 });
  });
});
