import { describe, expect, test } from "bun:test";
// Namespace import so a missing export surfaces as a clean assertion failure
// ("expected function, got undefined") rather than an ESM link error that
// crashes the whole file before any test body runs. `maskApiKey` currently
// lives (unexported) in routes.ts; the seam is to export it (optionally after
// extracting it into its own `src/provider/maskApiKey.ts` re-exported here).
import * as maskModule from "../../src/provider/routes";

/**
 * Bug P2: the current `maskApiKey` (private in `src/provider/routes.ts`)
 * reveals far too much of short keys -- for a 9-char key ("sk-abc123") it
 * shows 8 of the 9 characters ("sk-a...c123"), since its only guard is
 * `length <= 8 -> full stars` and everything longer reveals first-4 + last-4.
 *
 * Desired seam: `export` the `maskApiKey(apiKey: string): string` helper (from
 * routes.ts, or extract it into `src/provider/maskApiKey.ts` and re-export it
 * from routes.ts) so it is unit-testable, and fix its rule to:
 *
 *   - length 0            -> "" (nothing to mask)
 *   - length 1..12        -> all asterisks; reveal NOTHING
 *   - length > 12         -> reveal only a 3-char prefix + 3-char suffix,
 *                            middle fully masked with asterisks:
 *                            key.slice(0,3) + "*".repeat(len-6) + key.slice(-3)
 *
 * The masked form is what round-trips back to the Swift Settings UI, so it
 * must never let a short real key be reconstructed.
 */

const maskApiKey = (maskModule as { maskApiKey?: (k: string) => string }).maskApiKey;

describe("maskApiKey is exported as a standalone helper", () => {
  test("maskApiKey is a function", () => {
    expect(typeof maskApiKey).toBe("function");
  });
});

describe("maskApiKey masking rule", () => {
  test("empty string masks to empty string", () => {
    expect(maskApiKey!("")).toBe("");
  });

  test("a 9-char key reveals none of its characters (regression: was 'sk-a...c123')", () => {
    const key = "sk-abc123"; // 9 chars
    const masked = maskApiKey!(key);
    expect(masked).toBe("*********"); // 9 asterisks, nothing revealed
    // Nothing recognizable from the original key survives.
    expect(masked).not.toContain("abc");
    expect(masked).not.toContain("123");
    expect(masked).not.toContain("sk-");
  });

  test("a 12-char key reveals nothing (boundary: still fully masked)", () => {
    const key = "abcdefghijkl"; // 12 chars
    expect(maskApiKey!(key)).toBe("************");
  });

  test("a long key reveals only a 3-char prefix and 3-char suffix", () => {
    const key = "sk-1234567890abc"; // 16 chars
    const masked = maskApiKey!(key);
    expect(masked).toBe("sk-**********abc"); // "sk-" + 10 stars + "abc"
    // The secret middle is never revealed.
    expect(masked).not.toContain("1234567890");
    // Exactly 6 non-asterisk characters are revealed, no more.
    const revealed = masked.replace(/\*/g, "");
    expect(revealed.length).toBe(6);
  });

  test("a realistic long key masks its middle entirely", () => {
    const key = "sk-proj-ABCDEF1234567890"; // 24 chars
    const masked = maskApiKey!(key);
    expect(masked).toBe("sk-" + "*".repeat(18) + "890");
    expect(masked).not.toContain("ABCDEF");
    expect(masked).not.toContain("1234567890");
  });
});
