import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { ConversationStore } from "../../src/memory/conversations";
import type { AgentChatFn } from "../../src/agent/loop";
import type { McpToolSet } from "../../src/agent/mcpClient";
import { buildAgentRoutes } from "../../src/agent/routes";
import { createRouter } from "../../src/router";
import type { ContextUsageLogWriter } from "../../src/oneshot/contextDebugLog";

/** T1 route half (docs/superpowers/specs/2026-08-13-dsh-borrowings-plan.md §5.5-5.6). */

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
}

function noTools(): McpToolSet {
  return { openAiTools: [], callTool: async () => ({ content: "" }) };
}

function routerWith(chat: AgentChatFn, store = makeStore()) {
  const noopLog: ContextUsageLogWriter = () => {};
  return {
    store,
    router: createRouter(
      buildAgentRoutes(store, new ConversationStore(openDatabase(":memory:")), chat, noTools(), noopLog)
    ),
  };
}

function runRequest(body: unknown): Request {
  return new Request("http://sidecar/agent/run", { method: "POST", body: JSON.stringify(body) });
}

function cancelRequest(runId: string): Request {
  return new Request(`http://sidecar/agent/cancel/${runId}`, { method: "POST" });
}

describe("POST /agent/cancel/:runId", () => {
  test("an unknown id answers 200 with cancelled:false", async () => {
    const { router } = routerWith(async () => ({ content: "x" }));

    const response = await router(cancelRequest("never-dispatched"));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ cancelled: false });
  });

  test("cancelling a live run stops it with 499 and reports cancelled:true", async () => {
    const runId = "run-live";
    let cancelResponse: Response | undefined;
    // The model call is where the run parks; cancel from inside it so the
    // cancellation lands mid-flight rather than before the run starts.
    const { router } = routerWith(async () => {
      cancelResponse ??= await router(cancelRequest(runId));
      return {
        content: null,
        toolCalls: [
          { id: "c1", type: "function", function: { name: "noop", arguments: "{}" } },
        ],
      };
    });

    const response = await router(runRequest({ task: "long job", runId }));

    expect(cancelResponse?.status).toBe(200);
    expect(await cancelResponse!.json()).toEqual({ cancelled: true });
    expect(response.status).toBe(499);

    // The rule that used to be asserted here -- "a cancelled run is not a
    // completed task: teaching the memory layer from work the user
    // abandoned would poison it with results nobody accepted" -- did not go
    // away, it moved. `/agent/run` no longer writes `episodic_events` at all
    // (plan Task 3, design §3.2): writing happens only when Swift POSTs to
    // `POST /memory/events` at delivery time, and a cancelled run never
    // reaches delivery. So the suppression is now a property of the Swift
    // caller, not of this route -- see the requirement added to Task 5 to
    // pin "a cancelled agent run does not POST /memory/events" on that side.
  });

  test("the run reports a cancelled status, not a failed one", async () => {
    const runId = "run-status";
    const { router } = routerWith(async () => {
      await router(cancelRequest(runId));
      return { content: null, toolCalls: [{ id: "c", type: "function", function: { name: "n", arguments: "{}" } }] };
    });

    await router(runRequest({ task: "t", runId }));
    const progress = await router(
      new Request(`http://sidecar/agent/progress/${runId}`, { method: "GET" })
    );

    expect(((await progress.json()) as { status: string }).status).toBe("cancelled");
  });

  // Was "a normal run is unaffected and still records its episodic event" --
  // renamed because it no longer checks that (see the comment on the
  // cancelled-run test above for where that half of the pair went). What
  // stays true, and is still worth a dedicated assertion here, is the other
  // half of the pair: cancellation only affects a run that was actually
  // cancelled, not every run through this route.
  test("a normal run is unaffected by the cancel route's existence and still completes with 200", async () => {
    const { router } = routerWith(async () => ({ content: "all done" }));

    const response = await router(runRequest({ task: "quick", runId: "run-ok" }));

    expect(response.status).toBe(200);
  });

  test("cancelling an already-finished run reports nothing to cancel", async () => {
    const { router } = routerWith(async () => ({ content: "done" }));
    await router(runRequest({ task: "quick", runId: "run-done" }));

    const response = await router(cancelRequest("run-done"));

    expect(await response.json()).toEqual({ cancelled: false });
  });
});
