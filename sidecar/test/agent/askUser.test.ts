import { describe, expect, test } from "bun:test";
import {
  createAskUserBroker,
  createAskUserTool,
  ASK_USER_TOOL_NAME,
} from "../../src/agent/askUser";

/**
 * T5 of the dsh-borrowings plan
 * (docs/superpowers/specs/2026-08-13-dsh-borrowings-plan.md §13).
 *
 * Voice input is inherently ambiguous -- homophones, pronouns, elision. "把
 * 桌面那个 PDF 发给他" with three PDFs on the Desktop was a coin flip. This
 * lets the agent ask instead of guessing.
 *
 * The rule that matters most is the one about NOT hanging: a question with
 * no UI to answer it must fail fast, never park forever holding the run.
 */

const QUESTION = {
  id: "q1",
  question: "Which file did you mean?",
  options: [{ label: "a.pdf" }, { label: "b.pdf" }],
};

describe("ask_user without a UI channel", () => {
  test("fails immediately when the run has no id to address", async () => {
    const broker = createAskUserBroker();
    const tool = createAskUserTool(broker, { runId: undefined, timeoutMs: 60_000 });

    const result = await tool.callTool(ASK_USER_TOOL_NAME, { questions: [QUESTION] });

    expect(result.content.toLowerCase()).toContain("no way to ask");
    expect(broker.pending("anything")).toBeUndefined();
  });

  test("times out rather than parking forever", async () => {
    const broker = createAskUserBroker();
    const tool = createAskUserTool(broker, { runId: "run-1", timeoutMs: 20 });

    const result = await tool.callTool(ASK_USER_TOOL_NAME, { questions: [QUESTION] });

    expect(result.content.toLowerCase()).toContain("no answer");
    // The question must not linger after it gave up, or a late answer would
    // resolve nothing and a new question could not take its place.
    expect(broker.pending("run-1")).toBeUndefined();
  });
});

describe("ask_user answer routing", () => {
  test("resolves with the answer the UI submits", async () => {
    const broker = createAskUserBroker();
    const tool = createAskUserTool(broker, { runId: "run-2", timeoutMs: 5_000 });

    const pendingCall = tool.callTool(ASK_USER_TOOL_NAME, { questions: [QUESTION] });
    await Bun.sleep(5);
    expect(broker.pending("run-2")).toBeDefined();
    broker.answer("run-2", { answers: [{ id: "q1", selected: ["b.pdf"] }] });

    expect((await pendingCall).content).toContain("b.pdf");
  });

  test("routes answers by question id, not by order", async () => {
    const broker = createAskUserBroker();
    const tool = createAskUserTool(broker, { runId: "run-3", timeoutMs: 5_000 });

    const pendingCall = tool.callTool(ASK_USER_TOOL_NAME, {
      questions: [
        { id: "first", question: "A?", options: [{ label: "a" }] },
        { id: "second", question: "B?", options: [{ label: "b" }] },
      ],
    });
    await Bun.sleep(5);
    broker.answer("run-3", {
      answers: [
        { id: "second", selected: ["b"] },
        { id: "first", selected: ["a"] },
      ],
    });

    const content = (await pendingCall).content;
    expect(content.indexOf("A?")).toBeLessThan(content.indexOf("B?"));
    expect(content).toContain("a");
    expect(content).toContain("b");
  });

  test("free text overrides the selection on a single-select question", async () => {
    const broker = createAskUserBroker();
    const tool = createAskUserTool(broker, { runId: "run-4", timeoutMs: 5_000 });

    const pendingCall = tool.callTool(ASK_USER_TOOL_NAME, { questions: [QUESTION] });
    await Bun.sleep(5);
    broker.answer("run-4", {
      answers: [{ id: "q1", selected: [], custom: "actually c.pdf" }],
    });

    expect((await pendingCall).content).toContain("actually c.pdf");
  });

  test("a skipped question is reported as skipped, not as an error", async () => {
    const broker = createAskUserBroker();
    const tool = createAskUserTool(broker, { runId: "run-5", timeoutMs: 5_000 });

    const pendingCall = tool.callTool(ASK_USER_TOOL_NAME, { questions: [QUESTION] });
    await Bun.sleep(5);
    broker.answer("run-5", { answers: [{ id: "q1", selected: [] }] });

    expect((await pendingCall).content.toLowerCase()).toContain("skipped");
  });
});

describe("ask_user and cancellation", () => {
  test("a cancelled run abandons its pending question", async () => {
    const broker = createAskUserBroker();
    const tool = createAskUserTool(broker, { runId: "run-6", timeoutMs: 60_000 });
    const controller = new AbortController();

    const pendingCall = tool.callTool(
      ASK_USER_TOOL_NAME,
      { questions: [QUESTION] },
      controller.signal
    );
    await Bun.sleep(5);
    controller.abort();

    expect((await pendingCall).content.toLowerCase()).toContain("cancel");
    expect(broker.pending("run-6")).toBeUndefined();
  });
});

describe("ask_user input validation", () => {
  test("rejects an empty question list", async () => {
    const broker = createAskUserBroker();
    const tool = createAskUserTool(broker, { runId: "run-7", timeoutMs: 5_000 });

    const result = await tool.callTool(ASK_USER_TOOL_NAME, { questions: [] });

    expect(result.content.toLowerCase()).toContain("at least one question");
  });

  test("rejects questions without a stable id", async () => {
    // Ids are how answers route back; without them a batch is unanswerable.
    const broker = createAskUserBroker();
    const tool = createAskUserTool(broker, { runId: "run-8", timeoutMs: 5_000 });

    const result = await tool.callTool(ASK_USER_TOOL_NAME, {
      questions: [{ question: "no id?" }],
    });

    expect(result.content.toLowerCase()).toContain("id");
  });

  test("exposes exactly one tool, named for the product", () => {
    const tool = createAskUserTool(createAskUserBroker(), {
      runId: "r",
      timeoutMs: 1_000,
    });

    expect(tool.openAiTools).toHaveLength(1);
    expect(ASK_USER_TOOL_NAME).toBe("opentype__ask_user");
  });
});

describe("the broker's view of pending questions", () => {
  test("answering an unknown run is a no-op, not a throw", () => {
    const broker = createAskUserBroker();

    expect(() => broker.answer("nobody", { answers: [] })).not.toThrow();
  });

  test("keeps runs independent", async () => {
    const broker = createAskUserBroker();
    const first = createAskUserTool(broker, { runId: "x", timeoutMs: 5_000 });
    const second = createAskUserTool(broker, { runId: "y", timeoutMs: 5_000 });

    const pendingFirst = first.callTool(ASK_USER_TOOL_NAME, { questions: [QUESTION] });
    void second.callTool(ASK_USER_TOOL_NAME, { questions: [QUESTION] });
    await Bun.sleep(5);
    broker.answer("x", { answers: [{ id: "q1", selected: ["a.pdf"] }] });

    expect((await pendingFirst).content).toContain("a.pdf");
    expect(broker.pending("y")).toBeDefined();
  });
});
