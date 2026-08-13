import type { EntityTerm, MemoryStore } from "../memory/MemoryStore";

/**
 * MODEL EXPERIENCE: everything this module returns is injected verbatim into
 * the ask/agent user message. Exact rendered text, token cost (including the
 * unbounded, relevance-unfiltered owner-facts line), and KV-cache impact are
 * catalogued in `docs/model-context-inventory.md` §3.1–3.2 — update it in the
 * SAME change that alters what is injected here.
 */

/**
 * Finds which entity terms the local MemoryStore already knows about are
 * mentioned somewhere in `relevantText`. Split out from
 * `buildKnownTermsContext` so callers that need the raw matched terms (e.g.
 * `contextDebugLog.ts`, to prove — not just claim — that context lookup ran
 * and log exactly what it found) don't have to re-parse the formatted
 * prompt string to get them back out.
 *
 * `MemoryStore.search(text)` matches terms whose *canonicalTerm/alias
 * contains `text`* (built for looking up one short, near-exact name — see
 * its tests: `search("diyi wang")` finds the term "Diyi Wang"). That's the
 * opposite direction from what's needed here — spotting which already-known
 * terms are mentioned somewhere inside a longer, arbitrary sentence — so
 * this scans `allTerms()` and checks containment the other way around.
 */
export function findKnownTerms(store: MemoryStore, relevantText: string): EntityTerm[] {
  const haystack = relevantText.trim().toLowerCase();
  if (haystack.length === 0) {
    return [];
  }

  return store.allTerms().filter((term) => {
    const names = [term.canonicalTerm, ...term.aliases];
    return names.some((name) => name.length > 0 && haystack.includes(name.toLowerCase()));
  });
}

/**
 * Free-text facts the owner has told OpenType to remember about themselves
 * (e.g. "记住我的名字叫Diyi" -> "The owner's name is Diyi."), via the
 * `remember_fact` built-in tool's `category: "profile"` path
 * (`agent/builtInTools.ts`). Unlike `findKnownTerms`, which only surfaces
 * terms actually mentioned in the current input, this includes *every*
 * recorded owner fact unconditionally: given the likely small number of
 * facts for a single user, a relevance-matching system for free text isn't
 * worth building for v1 — see the design discussion this was scoped from.
 *
 * Origin-gated (P1-12): ONLY facts the owner actually authored (origin
 * "owner") are injected. Facts recorded through the agent/context flow
 * (origin "untrusted"/"agent"/"system") may have originated from untrusted
 * context — injecting them verbatim into every prompt is exactly the memory-
 * poisoning path being closed — so they are never surfaced here. They remain
 * visible on the management surface (`GET /memory/owner-facts`) so a user can
 * find and delete a poisoned one.
 */
export function buildOwnerFactsContext(store: MemoryStore): string {
  const facts = store.ownerFactsByOrigin("owner");
  if (facts.length === 0) {
    return "";
  }
  return `What you know about the user: ${facts.map((fact) => fact.content).join("; ")}.`;
}

/**
 * Light memory context injected into each one-shot/agent prompt: entity
 * terms the local MemoryStore already knows about that are mentioned
 * somewhere in the current input, so the model can use the user's
 * established names/terminology, plus every recorded owner fact (see
 * `buildOwnerFactsContext`). Deliberately simple (per the task spec) — plain
 * "Known terms: ..." / "What you know about the user: ..." lines, not a
 * structured section like `PromptBuilder.swift`'s full memory-profile prompt
 * (out of scope here).
 */
export function buildKnownTermsContext(store: MemoryStore, relevantText: string): string {
  const parts: string[] = [];

  const mentioned = findKnownTerms(store, relevantText);
  if (mentioned.length > 0) {
    const names = mentioned.map((term) => term.canonicalTerm);
    parts.push(`Known terms: ${names.join(", ")}.`);
  }

  const ownerFactsBlock = buildOwnerFactsContext(store);
  if (ownerFactsBlock) {
    parts.push(ownerFactsBlock);
  }

  return parts.join("\n");
}
