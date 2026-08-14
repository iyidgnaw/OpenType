import { describe, expect, test } from "bun:test";
import type { OneShotChatFn, OneShotChatMessage } from "../../src/oneshot/client";
import { buildTranscribeRoutes } from "../../src/transcribe/routes";
import { createRouter } from "../../src/router";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";

function post(body: unknown): Request {
  return new Request("http://sidecar/transcribe/correct", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

describe("POST /transcribe/correct", () => {
  test("happy path: returns the model's replacement for the selected span, trimmed", async () => {
    let capturedMessages: OneShotChatMessage[] | undefined;
    const chat: OneShotChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "  PayPal  " };
    };
    const router = createRouter(buildTranscribeRoutes(chat));

    const fullText = "请把这笔钱通过呸泡转给他";
    const selectionStart = fullText.indexOf("呸泡");
    const selectionEnd = selectionStart + "呸泡".length;

    const response = await router(
      post({
        fullText,
        selectionStart,
        selectionEnd,
        instruction: "这不对，应该是英文PayPal",
      })
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ replacement: "PayPal" });
    // The system prompt scopes the model to only the selected span.
    expect(capturedMessages![0].role).toBe("system");
    // The user content must carry the full text, the selected span, and the
    // spoken instruction so the model has enough context to correct just
    // that span without touching the rest.
    expect(capturedMessages![1].content).toContain(fullText);
    expect(capturedMessages![1].content).toContain("呸泡");
    expect(capturedMessages![1].content).toContain("这不对，应该是英文PayPal");
  });

  test("a selection spanning the entire text is treated as a full rewrite request", async () => {
    let capturedMessages: OneShotChatMessage[] | undefined;
    const chat: OneShotChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "Rewritten, more formal version." };
    };
    const router = createRouter(buildTranscribeRoutes(chat));

    const fullText = "hey can u send this over thanks";
    const response = await router(
      post({
        fullText,
        selectionStart: 0,
        selectionEnd: fullText.length,
        instruction: "rewrite this more formally",
      })
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      replacement: "Rewritten, more formal version.",
    });
    expect(capturedMessages![1].content).toContain("rewrite this more formally");
  });

  test("only the replacement is returned -- surrounding text is not echoed back by this endpoint", async () => {
    const chat: OneShotChatFn = async () => ({ content: "PayPal" });
    const router = createRouter(buildTranscribeRoutes(chat));

    const fullText = "please pay via 呸泡 today";
    const response = await router(
      post({
        fullText,
        selectionStart: fullText.indexOf("呸泡"),
        selectionEnd: fullText.indexOf("呸泡") + "呸泡".length,
        instruction: "should be PayPal",
      })
    );

    const body = (await response.json()) as { replacement: string };
    expect(body.replacement).toBe("PayPal");
    expect(body).not.toHaveProperty("fullText");
    expect(body).not.toHaveProperty("result");
  });

  test("rejects a selection range where start >= end", async () => {
    const chat: OneShotChatFn = async () => ({ content: "should not be called" });
    const router = createRouter(buildTranscribeRoutes(chat));

    const response = await router(
      post({
        fullText: "hello world",
        selectionStart: 5,
        selectionEnd: 5,
        instruction: "fix it",
      })
    );

    expect(response.status).toBe(400);
  });

  test("rejects a selection range that runs past the end of fullText", async () => {
    const chat: OneShotChatFn = async () => ({ content: "should not be called" });
    const router = createRouter(buildTranscribeRoutes(chat));

    const response = await router(
      post({
        fullText: "hello world",
        selectionStart: 0,
        selectionEnd: 999,
        instruction: "fix it",
      })
    );

    expect(response.status).toBe(400);
  });

  test("rejects a negative selectionStart", async () => {
    const chat: OneShotChatFn = async () => ({ content: "should not be called" });
    const router = createRouter(buildTranscribeRoutes(chat));

    const response = await router(
      post({
        fullText: "hello world",
        selectionStart: -1,
        selectionEnd: 5,
        instruction: "fix it",
      })
    );

    expect(response.status).toBe(400);
  });

  test("rejects a missing/blank instruction", async () => {
    const chat: OneShotChatFn = async () => ({ content: "should not be called" });
    const router = createRouter(buildTranscribeRoutes(chat));

    const response = await router(
      post({
        fullText: "hello world",
        selectionStart: 0,
        selectionEnd: 5,
        instruction: "   ",
      })
    );

    expect(response.status).toBe(400);
  });

  test("uses UTF-16 code unit offsets, matching JS string indexing, so multi-byte characters before the selection do not shift it", async () => {
    let capturedMessages: OneShotChatMessage[] | undefined;
    const chat: OneShotChatFn = async (messages) => {
      capturedMessages = messages;
      return { content: "OpenClaw" };
    };
    const router = createRouter(buildTranscribeRoutes(chat));

    // "龙虾" (2 UTF-16 code units) precedes the mangled term -- JS string
    // indexing (and thus `.slice`) is UTF-16-code-unit based, the same
    // representation `NSString`/`NSRange` use on the Swift side, so passing
    // raw offsets straight through (no re-encoding) must select exactly
    // "龙虾" itself here, not something shifted by a byte-based miscount.
    const fullText = "龙虾是一个很棒的项目";
    const selectionStart = 0;
    const selectionEnd = 2;

    await router(
      post({
        fullText,
        selectionStart,
        selectionEnd,
        instruction: "that should be OpenClaw",
      })
    );

    expect(capturedMessages![1].content).toContain('"龙虾"');
  });
});

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
}

/** Puts a term in the dictionary directly, bypassing the code under test. */
function seedTerm(
  store: MemoryStore,
  values: { canonicalTerm: string; aliases: string[]; confidence: number }
): void {
  const now = Date.now();
  store.db.run(
    `INSERT INTO entity_terms
      (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [
      values.canonicalTerm,
      JSON.stringify(values.aliases),
      "term",
      values.confidence,
      "system",
      "[]",
      now,
      now,
      null,
    ]
  );
}

/**
 * A store whose read and write paths all throw, standing in for a corrupt or
 * unwritable memory DB. Learning is best-effort: a broken dictionary must
 * never turn a successful correction into a failed request.
 */
function makeThrowingStore(): MemoryStore {
  const store = makeStore();
  const boom = (): never => {
    throw new Error("memory store unavailable");
  };
  store.allTerms = boom;
  Object.defineProperty(store.db, "run", { value: boom, configurable: true, writable: true });
  Object.defineProperty(store.db, "query", { value: boom, configurable: true, writable: true });
  return store;
}

/** Selects `span` inside `fullText` and asks for it to be corrected. */
function correctionRequest(fullText: string, span: string, instruction: string): Request {
  const selectionStart = fullText.indexOf(span);
  return post({
    fullText,
    selectionStart,
    selectionEnd: selectionStart + span.length,
    instruction,
  });
}

function fixedChat(replacement: string): OneShotChatFn {
  return async () => ({ content: replacement });
}

const PAYPAL_TEXT = "请把这笔钱通过呸泡转给他";
const PAYPAL_TEXT_2 = "他说用拍拍付款就行";
const PAYPAL_TEXT_3 = "转账用呗宝儿就行";

describe("POST /transcribe/correct -- learning the correction into the entity dictionary", () => {
  test("with no deps, a gate-passing correction behaves exactly as before: it succeeds, writes nothing, and reports nothing learned", async () => {
    // The store exists but is never handed to the router -- the endpoint must
    // stay usable without a MemoryStore at all.
    const store = makeStore();
    const router = createRouter(buildTranscribeRoutes(fixedChat("PayPal")));

    const response = await router(
      correctionRequest(PAYPAL_TEXT, "呸泡", "这不对，应该是英文PayPal")
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ replacement: "PayPal" });
    expect(store.allTerms()).toEqual([]);
  });

  test("with a store, a gate-passing correction writes the replacement as the canonical term and the selected text as its alias", async () => {
    const store = makeStore();
    const router = createRouter(buildTranscribeRoutes(fixedChat("PayPal"), { store }));

    const response = await router(
      correctionRequest(PAYPAL_TEXT, "呸泡", "这不对，应该是英文PayPal")
    );

    expect(response.status).toBe(200);

    const terms = store.allTerms();
    expect(terms).toHaveLength(1);
    expect(terms[0].canonicalTerm).toBe("PayPal");
    expect(terms[0].aliases).toEqual(["呸泡"]);
    expect(terms[0].category).toBe("term");
    // 0.8, not 1.0: the owner corrected this by hand (so it outranks the
    // agent-mediated `remember_fact` path's "untrusted" origin), but an
    // explicit "remember this" stays higher still.
    expect(terms[0].confidence).toBe(0.8);
    expect(terms[0].origin).toBe("owner");
  });

  test("the response carries what was learned", async () => {
    const store = makeStore();
    const router = createRouter(buildTranscribeRoutes(fixedChat("PayPal"), { store }));

    const response = await router(
      correctionRequest(PAYPAL_TEXT, "呸泡", "这不对，应该是英文PayPal")
    );

    expect(await response.json()).toEqual({
      replacement: "PayPal",
      learned: { canonicalTerm: "PayPal", alias: "呸泡" },
    });
  });

  test("a second correction mapping a different alias to the same canonical merges into one term rather than adding a second row", async () => {
    const store = makeStore();
    const router = createRouter(buildTranscribeRoutes(fixedChat("PayPal"), { store }));

    await router(correctionRequest(PAYPAL_TEXT, "呸泡", "这不对，应该是英文PayPal"));
    const second = await router(
      correctionRequest(PAYPAL_TEXT_2, "拍拍", "也是PayPal")
    );

    // Merging is `upsertEntityTerm`'s job -- reusing it (rather than writing a
    // second insert path here) is what makes this pass.
    const terms = store.allTerms();
    expect(terms).toHaveLength(1);
    expect(terms[0].canonicalTerm).toBe("PayPal");
    expect(terms[0].aliases).toContain("呸泡");
    expect(terms[0].aliases).toContain("拍拍");

    expect(await second.json()).toEqual({
      replacement: "PayPal",
      learned: { canonicalTerm: "PayPal", alias: "拍拍" },
    });
  });

  test("a correction whose replacement is already some term's alias joins that term instead of starting a rival row", async () => {
    const store = makeStore();
    // The dictionary already knows PayPal, with "贝宝" as one of its aliases,
    // at a confidence higher than the 0.8 a correction writes.
    seedTerm(store, { canonicalTerm: "PayPal", aliases: ["贝宝"], confidence: 0.9 });
    const router = createRouter(buildTranscribeRoutes(fixedChat("贝宝"), { store }));

    // The user corrects a fresh mishearing into "贝宝" -- which matches nothing
    // by canonicalTerm, only by alias. `upsertEntityTerm` matches on
    // canonical-OR-alias and so folds this into the existing PayPal row; a
    // hand-rolled "look up by canonicalTerm, else INSERT" would leave two rows
    // fighting over "贝宝", and keeping the higher confidence is likewise
    // `upsertEntityTerm`'s behavior, not something a fresh insert would do.
    const response = await router(
      correctionRequest(PAYPAL_TEXT_3, "呗宝儿", "是贝宝")
    );

    expect(response.status).toBe(200);
    const body = (await response.json()) as { learned?: { alias: string } };
    expect(body.learned?.alias).toBe("呗宝儿");

    const terms = store.allTerms();
    expect(terms).toHaveLength(1);
    expect(terms[0].canonicalTerm).toBe("PayPal");
    expect(terms[0].aliases).toContain("贝宝");
    expect(terms[0].aliases).toContain("呗宝儿");
    expect(terms[0].confidence).toBe(0.9);
  });

  test("a correction that fails the gates writes nothing and omits `learned`", async () => {
    const store = makeStore();
    const rewrite = "Rewritten, more formal version.";
    const router = createRouter(buildTranscribeRoutes(fixedChat(rewrite), { store }));

    const fullText = "hey can u send this over thanks";
    const response = await router(
      post({
        fullText,
        selectionStart: 0,
        selectionEnd: fullText.length,
        instruction: "rewrite this more formally",
      })
    );

    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body).toEqual({ replacement: rewrite });
    expect(body).not.toHaveProperty("learned");
    expect(store.allTerms()).toEqual([]);
  });

  test("a failing store never breaks the correction: the endpoint still returns the replacement", async () => {
    const router = createRouter(
      buildTranscribeRoutes(fixedChat("PayPal"), { store: makeThrowingStore() })
    );

    const response = await router(
      correctionRequest(PAYPAL_TEXT, "呸泡", "这不对，应该是英文PayPal")
    );

    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body).toEqual({ replacement: "PayPal" });
    expect(body).not.toHaveProperty("learned");
  });
});
