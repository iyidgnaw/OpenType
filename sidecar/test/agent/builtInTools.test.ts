import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { createBuiltInTools } from "../../src/agent/builtInTools";
import type { CallLLM } from "../../src/memory/consolidator";

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
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

describe("createBuiltInTools", () => {
  test("exposes exactly the two namespaced tools", () => {
    const store = makeStore();
    const callLLM: CallLLM = async () => JSON.stringify({ candidates: [] });
    const tools = createBuiltInTools({ store, callLLM });

    const names = tools.openAiTools.map(
      (t) => (t as { function: { name: string } }).function.name
    );
    expect(names.sort()).toEqual(["opentype__consolidate_memory_now", "opentype__remember_fact"].sort());
  });

  describe("opentype__remember_fact", () => {
    test("category 'term' writes directly into entity_terms with confidence 1.0, origin 'untrusted'", async () => {
      const store = makeStore();
      const callLLM: CallLLM = async () => JSON.stringify({ candidates: [] });
      const tools = createBuiltInTools({ store, callLLM });

      const result = await tools.callTool("opentype__remember_fact", {
        category: "term",
        canonicalTerm: "PayPal",
        aliases: ["paypal", "pay pal"],
      });

      expect(result.content).toContain("PayPal");
      const terms = store.allTerms();
      expect(terms).toHaveLength(1);
      expect(terms[0]?.canonicalTerm).toBe("PayPal");
      expect(terms[0]?.aliases.sort()).toEqual(["pay pal", "paypal"].sort());
      expect(terms[0]?.confidence).toBe(1.0);
      expect(terms[0]?.origin).toBe("untrusted");
      expect(terms[0]?.category).toBe("term");
    });

    test("category 'term' merges with an existing term instead of duplicating, unioning aliases", async () => {
      const store = makeStore();
      const now = Date.now();
      store.db.run(
        `INSERT INTO entity_terms
          (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        ["PayPal", JSON.stringify(["paypal"]), "term", 0.6, "agent", "[]", now, now, null]
      );
      const callLLM: CallLLM = async () => JSON.stringify({ candidates: [] });
      const tools = createBuiltInTools({ store, callLLM });

      await tools.callTool("opentype__remember_fact", {
        category: "term",
        canonicalTerm: "PayPal",
        aliases: ["pay pal"],
      });

      const terms = store.allTerms();
      expect(terms).toHaveLength(1);
      expect(terms[0]?.aliases.sort()).toEqual(["pay pal", "paypal"].sort());
      expect(terms[0]?.confidence).toBe(1.0); // full trust, not gated/averaged
    });

    test("category 'term' without canonicalTerm returns an error, without writing anything", async () => {
      const store = makeStore();
      const callLLM: CallLLM = async () => JSON.stringify({ candidates: [] });
      const tools = createBuiltInTools({ store, callLLM });

      const result = await tools.callTool("opentype__remember_fact", { category: "term" });

      expect(result.content.toLowerCase()).toContain("canonicalterm");
      expect(store.allTerms()).toHaveLength(0);
    });

    test("category 'profile' writes directly into owner_facts", async () => {
      const store = makeStore();
      const callLLM: CallLLM = async () => JSON.stringify({ candidates: [] });
      const tools = createBuiltInTools({ store, callLLM });

      const result = await tools.callTool("opentype__remember_fact", {
        category: "profile",
        content: "The owner's name is Diyi.",
      });

      expect(result.content).toContain("Diyi");
      const facts = store.allOwnerFacts();
      expect(facts).toHaveLength(1);
      expect(facts[0]?.content).toBe("The owner's name is Diyi.");
      expect(facts[0]?.origin).toBe("untrusted");
    });

    test("category 'profile' without content returns an error, without writing anything", async () => {
      const store = makeStore();
      const callLLM: CallLLM = async () => JSON.stringify({ candidates: [] });
      const tools = createBuiltInTools({ store, callLLM });

      const result = await tools.callTool("opentype__remember_fact", { category: "profile" });

      expect(result.content.toLowerCase()).toContain("content");
      expect(store.allOwnerFacts()).toHaveLength(0);
    });

    test("an unrecognized category returns an error, without writing anything", async () => {
      const store = makeStore();
      const callLLM: CallLLM = async () => JSON.stringify({ candidates: [] });
      const tools = createBuiltInTools({ store, callLLM });

      const result = await tools.callTool("opentype__remember_fact", {
        category: "nonsense",
        content: "x",
      });

      expect(result.content.toLowerCase()).toContain("category");
      expect(store.allOwnerFacts()).toHaveLength(0);
      expect(store.allTerms()).toHaveLength(0);
    });
  });

  describe("opentype__consolidate_memory_now", () => {
    test("runs consolidation immediately, bypassing the normal shouldConsolidate gate", async () => {
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
      const tools = createBuiltInTools({ store, callLLM });

      const result = await tools.callTool("opentype__consolidate_memory_now", {});

      const runs = store.db.query("SELECT * FROM memory_consolidation_runs").all();
      expect(runs).toHaveLength(1); // ran despite only 2 unconsolidated events
      expect(store.allTerms()).toHaveLength(1);
      expect(result.content).toContain("2"); // events considered
      expect(result.content.toLowerCase()).toContain("consolidat");
    });

    test("returns a summary reflecting an aborted run without throwing", async () => {
      const store = makeStore();
      seedEvents(store, 3);
      const callLLM: CallLLM = async () => "not json";
      const tools = createBuiltInTools({ store, callLLM });

      const result = await tools.callTool("opentype__consolidate_memory_now", {});

      expect(result.content.length).toBeGreaterThan(0);
      const runs = store.db.query("SELECT * FROM memory_consolidation_runs").all();
      expect(runs).toHaveLength(0);
    });
  });

  test("throws for an unknown tool name", async () => {
    const store = makeStore();
    const callLLM: CallLLM = async () => JSON.stringify({ candidates: [] });
    const tools = createBuiltInTools({ store, callLLM });

    await expect(tools.callTool("opentype__not_a_real_tool", {})).rejects.toThrow();
  });
});
