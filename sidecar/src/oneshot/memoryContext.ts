import type { EntityTerm, MemoryStore } from "../memory/MemoryStore";

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
 * Light memory context injected into each one-shot/agent prompt: entity
 * terms the local MemoryStore already knows about that are mentioned
 * somewhere in the current input, so the model can use the user's
 * established names/terminology. Deliberately simple (per the task spec) —
 * a plain "Known terms: ..." line, not a structured section like
 * `PromptBuilder.swift`'s full memory-profile prompt (out of scope here).
 */
export function buildKnownTermsContext(store: MemoryStore, relevantText: string): string {
  const mentioned = findKnownTerms(store, relevantText);
  if (mentioned.length === 0) {
    return "";
  }
  const names = mentioned.map((term) => term.canonicalTerm);
  return `Known terms: ${names.join(", ")}.`;
}
