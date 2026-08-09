import { describe, expect, test } from "bun:test";
import type { OneShotChatFn, OneShotChatMessage } from "../../src/oneshot/client";
import { buildTranscribeRoutes } from "../../src/transcribe/routes";
import { createRouter } from "../../src/router";

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
