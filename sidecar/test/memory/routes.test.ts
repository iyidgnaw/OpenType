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

function post(path: string): Request {
  return new Request(`http://sidecar${path}`, { method: "POST" });
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
