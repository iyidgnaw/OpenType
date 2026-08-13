import { describe, expect, test } from "bun:test";
import {
  AgentCancelledError,
  createCancellationRegistry,
  runBudgetSignal,
} from "../../src/agent/cancellation";
import { runAgentLoop } from "../../src/agent/loop";
import { mergeToolSets, filterToolSet, type ToolSet } from "../../src/agent/toolSets";
import { withApproval, yoloApprovalPolicy } from "../../src/agent/approval";

/**
 * T1 of the dsh-borrowings plan
 * (docs/superpowers/specs/2026-08-13-dsh-borrowings-plan.md §5).
 *
 * Before this, `AbortSignal` appeared ZERO times in src/agent and
 * src/oneshot: the Swift side could kill its curl child, but the sidecar
 * loop kept running -- still burning tokens, still executing bash with no
 * sandbox. Nothing could stop a misfired agent run.
 */

/** A tool set that records the signal it was handed. */
function recordingTools(): { tools: ToolSet; signals: (AbortSignal | undefined)[] } {
  const signals: (AbortSignal | undefined)[] = [];
  const tools: ToolSet = {
    openAiTools: [
      { type: "function", function: { name: "probe", description: "d", parameters: {} } },
    ],
    callTool: async (_name, _args, signal) => {
      signals.push(signal);
      return { content: "ok" };
    },
  };
  return { tools, signals };
}

describe("signal propagation through the tool-set combinators", () => {
  test("mergeToolSets forwards the caller's signal", async () => {
    const { tools, signals } = recordingTools();
    const controller = new AbortController();

    await mergeToolSets(tools).callTool("probe", {}, controller.signal);

    expect(signals[0]).toBe(controller.signal);
  });

  test("filterToolSet forwards the caller's signal", async () => {
    const { tools, signals } = recordingTools();
    const controller = new AbortController();

    await filterToolSet(tools, ["probe"]).callTool("probe", {}, controller.signal);

    expect(signals[0]).toBe(controller.signal);
  });

  test("withApproval forwards the caller's signal on an allowed call", async () => {
    const { tools, signals } = recordingTools();
    const controller = new AbortController();

    await withApproval(tools, yoloApprovalPolicy).callTool("probe", {}, controller.signal);

    expect(signals[0]).toBe(controller.signal);
  });

  test("a wrapper cannot silently drop the signal", async () => {
    // The composed stack is what production uses; the signal must survive all
    // three layers, not just each one in isolation.
    const { tools, signals } = recordingTools();
    const controller = new AbortController();
    const composed = filterToolSet(
      withApproval(mergeToolSets(tools), yoloApprovalPolicy),
      ["probe"]
    );

    await composed.callTool("probe", {}, controller.signal);

    expect(signals[0]).toBe(controller.signal);
  });
});

describe("runAgentLoop cancellation", () => {
  const alwaysCallsTool = () => ({
    content: null,
    toolCalls: [
      {
        id: "call-1",
        type: "function",
        function: { name: "probe", arguments: "{}" },
      },
    ],
  });

  test("makes no further model call once the signal aborts", async () => {
    const controller = new AbortController();
    let calls = 0;
    const chat = async () => {
      calls += 1;
      controller.abort(new AgentCancelledError("user"));
      return alwaysCallsTool();
    };

    await expect(
      runAgentLoop(
        { task: "t" },
        {
          chat,
          tools: { openAiTools: [], callTool: async () => ({ content: "ok" }) },
          signal: controller.signal,
        }
      )
    ).rejects.toBeInstanceOf(AgentCancelledError);

    expect(calls).toBe(1);
  });

  test("rejects immediately when handed an already-aborted signal", async () => {
    const controller = new AbortController();
    controller.abort(new AgentCancelledError("user"));
    let calls = 0;

    await expect(
      runAgentLoop(
        { task: "t" },
        {
          chat: async () => {
            calls += 1;
            return { content: "never" };
          },
          tools: { openAiTools: [], callTool: async () => ({ content: "" }) },
          signal: controller.signal,
        }
      )
    ).rejects.toBeInstanceOf(AgentCancelledError);

    expect(calls).toBe(0);
  });

  test("hands the signal to every tool call", async () => {
    const { tools, signals } = recordingTools();
    const controller = new AbortController();
    let calls = 0;

    await runAgentLoop(
      { task: "t" },
      {
        chat: async () => {
          calls += 1;
          return calls === 1 ? alwaysCallsTool() : { content: "done" };
        },
        tools,
        signal: controller.signal,
      }
    );

    expect(signals[0]).toBe(controller.signal);
  });

  test("still runs to completion with no signal at all", async () => {
    const result = await runAgentLoop(
      { task: "t" },
      {
        chat: async () => ({ content: "fine" }),
        tools: { openAiTools: [], callTool: async () => ({ content: "" }) },
      }
    );

    expect(result.result).toBe("fine");
  });
});

describe("AgentCancelledError", () => {
  test("distinguishes a user cancellation from a budget expiry", () => {
    // The two must be tellable apart: one is the user changing their mind,
    // the other is the harness giving up. Reporting a budget expiry as "you
    // cancelled this" would be a lie to the user.
    expect(new AgentCancelledError("user").cause).toBe("user");
    expect(new AgentCancelledError("budget").cause).toBe("budget");
  });

  test("is recognisable after crossing an AbortSignal", () => {
    const controller = new AbortController();
    controller.abort(new AgentCancelledError("budget"));

    expect(controller.signal.reason).toBeInstanceOf(AgentCancelledError);
    expect((controller.signal.reason as AgentCancelledError).cause).toBe("budget");
  });
});

describe("runBudgetSignal", () => {
  test("aborts with a budget cause once the budget expires", async () => {
    const signal = runBudgetSignal(undefined, 5);

    await Bun.sleep(30);

    expect(signal.aborted).toBe(true);
    expect((signal.reason as AgentCancelledError).cause).toBe("budget");
  });

  test("a caller abort wins and keeps its own cause", () => {
    const controller = new AbortController();
    const signal = runBudgetSignal(controller.signal, 60_000);

    controller.abort(new AgentCancelledError("user"));

    expect(signal.aborted).toBe(true);
    expect((signal.reason as AgentCancelledError).cause).toBe("user");
  });

  test("an already-aborted caller signal produces an already-aborted result", () => {
    const controller = new AbortController();
    controller.abort(new AgentCancelledError("user"));

    expect(runBudgetSignal(controller.signal, 60_000).aborted).toBe(true);
  });
});

describe("createCancellationRegistry", () => {
  test("cancels a registered run and reports that it did", () => {
    const registry = createCancellationRegistry();
    const signal = registry.register("run-1");

    expect(registry.cancel("run-1")).toBe(true);
    expect(signal.aborted).toBe(true);
    expect((signal.reason as AgentCancelledError).cause).toBe("user");
  });

  test("an unknown id is not an error, just nothing to cancel", () => {
    // Same precedent as GET /agent/progress/:runId: unknown is "nothing to
    // show", not a 404.
    expect(createCancellationRegistry().cancel("never-registered")).toBe(false);
  });

  test("a released run can no longer be cancelled", () => {
    const registry = createCancellationRegistry();
    registry.register("run-2");
    registry.release("run-2");

    expect(registry.cancel("run-2")).toBe(false);
  });

  test("cancelling twice reports false the second time", () => {
    const registry = createCancellationRegistry();
    registry.register("run-3");

    expect(registry.cancel("run-3")).toBe(true);
    expect(registry.cancel("run-3")).toBe(false);
  });

  test("keeps runs independent", () => {
    const registry = createCancellationRegistry();
    const first = registry.register("a");
    const second = registry.register("b");

    registry.cancel("a");

    expect(first.aborted).toBe(true);
    expect(second.aborted).toBe(false);
  });
});
