import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { buildKnownTermsContext, buildOwnerFactsContext, findKnownTerms } from "../../src/oneshot/memoryContext";

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
}

describe("buildOwnerFactsContext", () => {
  test("returns empty string when there are no owner facts", () => {
    expect(buildOwnerFactsContext(makeStore())).toBe("");
  });

  test("includes every recorded owner fact, regardless of relevance to any particular text", () => {
    const store = makeStore();
    store.recordOwnerFact("The owner's name is Diyi.");
    store.recordOwnerFact("The owner prefers formal English.");

    const context = buildOwnerFactsContext(store);

    expect(context).toContain("Diyi");
    expect(context).toContain("formal English");
  });
});

describe("buildKnownTermsContext with owner facts", () => {
  test("includes owner facts even when no entity terms match the text", () => {
    const store = makeStore();
    store.recordOwnerFact("The owner's name is Diyi.");

    const context = buildKnownTermsContext(store, "what time is it?");

    expect(context).toContain("Diyi");
  });

  test("includes both matched known terms and owner facts when both exist", () => {
    const store = makeStore();
    const now = Date.now();
    store.db.run(
      `INSERT INTO entity_terms
        (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
       VALUES ('Zephyrus', '[]', 'project', 0.9, 'owner', '[]', ?, ?, NULL)`,
      [now, now]
    );
    store.recordOwnerFact("The owner's name is Diyi.");

    const context = buildKnownTermsContext(store, "what is the status of Zephyrus?");

    expect(context).toContain("Zephyrus");
    expect(context).toContain("Diyi");
  });

  test("returns empty string when there is neither a matched term nor any owner fact", () => {
    expect(buildKnownTermsContext(makeStore(), "anything")).toBe("");
  });

  test("findKnownTerms is unaffected by owner facts (still only about entity_terms)", () => {
    const store = makeStore();
    store.recordOwnerFact("The owner's name is Diyi.");
    expect(findKnownTerms(store, "Diyi is here")).toEqual([]);
  });
});
