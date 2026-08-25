import { describe, expect, test } from "bun:test";
import { buildAsrRoutes } from "../../src/asr/routes";
import type { EntityTerm } from "../../src/memory/MemoryStore";
import { createRouter } from "../../src/router";

/**
 * Stage-1 (TDD red) coverage for D-1 -- the first of the three silent exits of
 * the learning loop (`docs/superpowers/specs/2026-08-15-product-batch-plan.md`
 * §D, motivated by `docs/reviews/2026-08-15-product-review.md` §1).
 *
 * `handleTranscribe` today computes `applyAliasCorrections(text, terms).text`
 * and throws `.replacements` away on that same line, so the one deterministic,
 * guaranteed half of the dictionary feedback loop leaves no trace the user can
 * see: they say 「呸泡」, 「PayPal」 comes out, and the only two explanations
 * available to them are "Whisper got lucky" and "something rewrote my words and
 * I don't know what."
 *
 * This suite pins the wire shape that ends that, and it pins one field §D did
 * not ask for -- `termId`.
 *
 * ## Why `termId` is here
 *
 * §D-1's headline requirement is that a replacement be **undoable**: one click
 * restores the text *and* deletes the alias that caused it, because alias
 * learning is heuristic and a wrongly-learned alias is otherwise only reachable
 * by hunting through the memory page. The delete endpoint the plan points at is
 * `DELETE /memory/terms/:id`, and `{ from, to }` alone does not carry an `:id`.
 * Swift would have to reverse-look-up the term by its canonical spelling in
 * `memoryTerms` -- a list that is only populated when the memory panel has been
 * opened, and which cannot disambiguate two terms that share a canonical. The
 * route already holds the whole dictionary in `terms` when it builds the
 * response, so it is the only place where the answer is free and unambiguous.
 *
 * ## What `termId` must be, exactly
 *
 * The term whose alias actually **won** the match. `applyAliasCorrections`
 * ranks competing aliases (`compareAliasPatterns`: alias length, then
 * confidence, then recency, then canonical spelling) precisely because the
 * dictionary is written automatically and two terms claiming 「呸泡」 is a
 * reachable state. Reporting the id of a term that lost that ranking would send
 * the undo click to delete an innocent row and leave the guilty one in place --
 * the exact failure the feature exists to fix.
 */

let nextId = 1;

function makeTerm(
  canonicalTerm: string,
  aliases: string[],
  overrides: Partial<EntityTerm> = {}
): EntityTerm {
  return {
    id: nextId++,
    canonicalTerm,
    aliases,
    category: "term",
    confidence: 0.9,
    origin: "owner",
    sourceEventIds: [],
    createdAt: 0,
    updatedAt: 0,
    supersedes: null,
    ...overrides,
  };
}

function post(body: unknown): Request {
  return new Request("http://sidecar/asr/transcribe", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

interface ReplacementRow {
  from: string;
  to: string;
  termId: number;
}

interface TranscribeResponseBody {
  text: string;
  replacements?: ReplacementRow[];
}

async function transcribeWith(
  text: string,
  terms: EntityTerm[]
): Promise<TranscribeResponseBody> {
  const router = createRouter(
    buildAsrRoutes(async () => text, { listTerms: () => terms })
  );
  const response = await router(post({ audioBase64: "aGk=" }));
  expect(response.status).toBe(200);
  return (await response.json()) as TranscribeResponseBody;
}

describe("POST /asr/transcribe reports what the dictionary rewrote", () => {
  test("returns one row per applied rewrite, alias in `from` and canonical in `to`", async () => {
    const payPal = makeTerm("PayPal", ["呸泡"]);

    const body = await transcribeWith("我用呸泡付款", [payPal]);

    expect(body.text).toBe("我用PayPal付款");
    expect(body.replacements).toEqual([
      { from: "呸泡", to: "PayPal", termId: payPal.id },
    ]);
  });

  test("counts places, not distinct terms: a term heard twice is two rows", async () => {
    // The toast says 「自动修正 N 处」 and offers one undo control per row, so N
    // has to be the number of spots in the text that changed. Collapsing to
    // distinct terms would under-report the damage of a bad alias in exactly
    // the sentence where it did the most.
    const payPal = makeTerm("PayPal", ["呸泡"]);

    const body = await transcribeWith("呸泡转账给我，我也用呸泡", [payPal]);

    expect(body.text).toBe("PayPal转账给我，我也用PayPal");
    expect(body.replacements).toEqual([
      { from: "呸泡", to: "PayPal", termId: payPal.id },
      { from: "呸泡", to: "PayPal", termId: payPal.id },
    ]);
  });

  test("rows are in text order, left to right, across different terms", async () => {
    // Left-to-right is what makes 「第 2 处」 mean the same thing to the user and
    // to the undo code. `applyAliasCorrections` already guarantees it; this
    // pins that the route does not re-group or sort on the way out.
    const anthropic = makeTerm("Anthropic", ["安思罗匹克"]);
    const payPal = makeTerm("PayPal", ["呸泡"]);

    const body = await transcribeWith("先问安思罗匹克，再用呸泡付款", [
      payPal,
      anthropic,
    ]);

    expect(body.text).toBe("先问Anthropic，再用PayPal付款");
    expect(body.replacements).toEqual([
      { from: "安思罗匹克", to: "Anthropic", termId: anthropic.id },
      { from: "呸泡", to: "PayPal", termId: payPal.id },
    ]);
  });

  test("`from` carries the alias as written in the dictionary, `to` the canonical's own casing", async () => {
    // ASCII aliases match case-insensitively and the canonical is written back
    // with its own casing regardless of how it was heard. The undo row has to
    // show the user the pair that is actually in the dictionary, not the
    // casing the recogniser happened to emit -- that pair is what they are
    // about to delete.
    const payPal = makeTerm("PayPal", ["paipal"]);

    const body = await transcribeWith("I paid with PAIPAL yesterday", [payPal]);

    expect(body.text).toBe("I paid with PayPal yesterday");
    expect(body.replacements).toEqual([
      { from: "paipal", to: "PayPal", termId: payPal.id },
    ]);
  });
});

describe("POST /asr/transcribe replacement rows name the term that won", () => {
  test("`termId` is the term the winning alias belongs to, not another term with the same alias", async () => {
    // Two terms claiming 「呸泡」 is a state the product reaches on its own:
    // every accepted correction becomes an alias, so correcting 呸泡 -> PayPal
    // once and 呸泡 -> 贝宝 later leaves both rows claiming it.
    // `compareAliasPatterns` breaks the tie on confidence, and the undo click
    // must delete whichever row actually rewrote the user's text.
    const loser = makeTerm("贝宝", ["呸泡"], { confidence: 0.7 });
    const winner = makeTerm("PayPal", ["呸泡"], { confidence: 0.95 });

    const body = await transcribeWith("我用呸泡付款", [loser, winner]);

    expect(body.text).toBe("我用PayPal付款");
    expect(body.replacements).toEqual([
      { from: "呸泡", to: "PayPal", termId: winner.id },
    ]);
  });

  test("a longer alias wins over a shorter one, and `termId` follows it", async () => {
    // Length-first is the rule `compareAliasPatterns` names, so the shorter
    // alias never eats the prefix of a longer one -- and the reported term has
    // to be the one whose alias was actually consumed. Both aliases clear
    // `MIN_ALIAS_LENGTH` (2) on purpose: a one-character alias is dropped
    // before ranking ever sees it, so pitting one against a two-character
    // alias would agree with this expectation for the wrong reason.
    const shortAlias = makeTerm("Pay", ["呸泡"]);
    const longAlias = makeTerm("PayPal", ["呸泡付"]);

    const body = await transcribeWith("我用呸泡付款", [shortAlias, longAlias]);

    expect(body.text).toBe("我用PayPal款");
    expect(body.replacements).toEqual([
      { from: "呸泡付", to: "PayPal", termId: longAlias.id },
    ]);
  });

  test("two rows identical down to the canonical resolve deterministically to the lowest id", async () => {
    // `allTerms()` is `SELECT * FROM entity_terms` with no `ORDER BY`, so if
    // the same pair is duplicated, ranking on arrival order would let the id we
    // report -- and therefore the row the undo click deletes -- change after an
    // unrelated write. Lowest id is arbitrary but total and order-independent.
    const first = makeTerm("PayPal", ["呸泡"], { id: 10 });
    const second = makeTerm("PayPal", ["呸泡"], { id: 11 });

    const forwards = await transcribeWith("我用呸泡付款", [first, second]);
    const backwards = await transcribeWith("我用呸泡付款", [second, first]);

    expect(forwards.replacements).toEqual([
      { from: "呸泡", to: "PayPal", termId: 10 },
    ]);
    expect(backwards.replacements).toEqual(forwards.replacements);
  });
});

describe("POST /asr/transcribe stays backward compatible when nothing was rewritten", () => {
  test("omits the key entirely rather than sending an empty array", async () => {
    // Not cosmetic: every existing caller (including any older build of the
    // Swift app talking to a newer sidecar) reads a `replacements` array it
    // does not recognise as an unfamiliar shape, and an empty one would let
    // the UI announce 「自动修正 0 处」. An absent key is the only form of
    // "nothing was rewritten" that costs nothing downstream. This is
    // specifically about `replacements`, not the whole response: `rawText`
    // (Task 4) is unconditional and present below regardless of whether a
    // rewrite happened -- see the "rawText" describe block in
    // `routes.test.ts` for that field's own coverage.
    const body = await transcribeWith("hello world", [makeTerm("PayPal", ["呸泡"])]);

    expect(body).toEqual({ text: "hello world", rawText: "hello world" });
    expect("replacements" in body).toBe(false);
  });

  test("omits the key when the route was built without a dictionary at all", async () => {
    const router = createRouter(buildAsrRoutes(async () => "hello world"));

    const response = await router(post({ audioBase64: "aGk=" }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ text: "hello world", rawText: "hello world" });
  });

  test("omits the key when reading the dictionary throws", async () => {
    // The degradation stance `readTerms` already takes: losing term biasing is
    // a degradation, losing transcription is an outage. A locked memory DB must
    // therefore produce the *old* response, not a new one carrying an empty
    // list that would let the UI claim 「自动修正 0 处」.
    const router = createRouter(
      buildAsrRoutes(async () => "我用呸泡付款", {
        listTerms: () => {
          throw new Error("database is locked");
        },
      })
    );

    const response = await router(post({ audioBase64: "aGk=" }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      text: "我用呸泡付款",
      rawText: "我用呸泡付款",
    });
  });

  test("the error responses are untouched", async () => {
    const router = createRouter(
      buildAsrRoutes(
        async () => {
          throw new Error("whisper server unavailable");
        },
        { listTerms: () => [makeTerm("PayPal", ["呸泡"])] }
      )
    );

    const response = await router(post({ audioBase64: "aGk=" }));

    expect(response.status).toBe(502);
    const body = (await response.json()) as { error?: string; replacements?: unknown };
    expect(body.error).toContain("whisper server unavailable");
    expect("replacements" in body).toBe(false);
  });
});
