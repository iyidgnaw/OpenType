import type { MemoryStore } from "../memory/MemoryStore";

/**
 * Light memory context injected into each one-shot prompt: entity terms the
 * local MemoryStore already knows about that are mentioned somewhere in the
 * current input, so the model can use the user's established names/
 * terminology. Deliberately simple (per the task spec) — a plain
 * "Known terms: ..." line, not a structured section like
 * `PromptBuilder.swift`'s full memory-profile prompt (out of scope here).
 *
 * `MemoryStore.search(text)` matches terms whose *canonicalTerm/alias
 * contains `text`* (built for looking up one short, near-exact name — see
 * its tests: `search("diyi wang")` finds the term "Diyi Wang"). That's the
 * opposite direction from what's needed here — spotting which already-known
 * terms are mentioned somewhere inside a longer, arbitrary sentence — so
 * this scans `allTerms()` and checks containment the other way around.
 */
export function buildKnownTermsContext(store: MemoryStore, relevantText: string): string {
  const haystack = relevantText.trim().toLowerCase();
  if (haystack.length === 0) {
    return "";
  }

  const mentioned = store.allTerms().filter((term) => {
    const names = [term.canonicalTerm, ...term.aliases];
    return names.some((name) => name.length > 0 && haystack.includes(name.toLowerCase()));
  });

  if (mentioned.length === 0) {
    return "";
  }
  const names = mentioned.map((term) => term.canonicalTerm);
  return `Known terms: ${names.join(", ")}.`;
}
