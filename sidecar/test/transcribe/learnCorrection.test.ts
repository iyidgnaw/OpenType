import { describe, expect, test } from "bun:test";
import { shouldLearnCorrection } from "../../src/transcribe/learnCorrection";

/**
 * The gate in front of "a voice correction becomes an entity_terms alias"
 * (P0-2). It is deliberately a pure function so every rule below is testable
 * without a router, a model, or a database: the endpoint only decides *when*
 * to ask, this decides *whether* the pair is a term correction at all.
 */
describe("shouldLearnCorrection", () => {
  test("the motivating case: a mis-transcribed term corrected to its real spelling is worth learning", () => {
    expect(shouldLearnCorrection("呸泡", "PayPal")).toBe(true);
  });

  test("two non-empty sides that differ after trimming are worth learning", () => {
    expect(shouldLearnCorrection("  呸泡  ", " PayPal ")).toBe(true);
    expect(shouldLearnCorrection("OpenTight", "OpenType")).toBe(true);
  });

  test("sides that are identical after trimming are not a correction at all", () => {
    expect(shouldLearnCorrection(" PayPal ", "PayPal")).toBe(false);
  });

  test("sides that differ only in case are not worth learning", () => {
    expect(shouldLearnCorrection("paypal", "PayPal")).toBe(false);
    expect(shouldLearnCorrection("PAYPAL", "PayPal")).toBe(false);
  });

  test("an empty side is never worth learning", () => {
    expect(shouldLearnCorrection("", "PayPal")).toBe(false);
    expect(shouldLearnCorrection("呸泡", "")).toBe(false);
    expect(shouldLearnCorrection("", "")).toBe(false);
  });

  test("selected text longer than 24 characters is a rewrite, not a term correction", () => {
    expect(shouldLearnCorrection("a".repeat(25), "PayPal")).toBe(false);
  });

  test("selected text of exactly 24 characters is still learnable (the boundary is inclusive)", () => {
    expect(shouldLearnCorrection("a".repeat(24), "PayPal")).toBe(true);
  });

  test("replacement text longer than 24 characters is a rewrite, not a term correction", () => {
    expect(shouldLearnCorrection("呸泡", "x".repeat(25))).toBe(false);
  });

  test("replacement text of exactly 24 characters is still learnable (the boundary is inclusive)", () => {
    expect(shouldLearnCorrection("呸泡", "x".repeat(24))).toBe(true);
  });

  test("a replacement containing a newline is a multi-line rewrite, not a term", () => {
    expect(shouldLearnCorrection("呸泡", "PayPal\n转账")).toBe(false);
  });

  test("a replacement that contains the selected text is an expansion, not an alias", () => {
    // Learning this would teach the dictionary that "PayPal" is an alias of
    // "PayPal 转账", so every future "PayPal" would get expanded.
    expect(shouldLearnCorrection("PayPal", "PayPal 转账")).toBe(false);
    expect(shouldLearnCorrection("转账", "用 PayPal 转账")).toBe(false);
  });

  test("a pure-punctuation side is never worth learning", () => {
    expect(shouldLearnCorrection("。。。", "PayPal")).toBe(false);
    expect(shouldLearnCorrection("...", "PayPal")).toBe(false);
    expect(shouldLearnCorrection("PayPal", "！！！")).toBe(false);
    expect(shouldLearnCorrection("PayPal", "---")).toBe(false);
  });

  test("a pure-whitespace side is never worth learning", () => {
    expect(shouldLearnCorrection("   ", "PayPal")).toBe(false);
    expect(shouldLearnCorrection("PayPal", "   ")).toBe(false);
    expect(shouldLearnCorrection("\t\n ", "PayPal")).toBe(false);
  });
});
