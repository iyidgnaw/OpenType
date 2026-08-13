import { describe, expect, test } from "bun:test";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRunLog, readRunLog } from "../../src/agent/runLog";

/**
 * T7 of the dsh-borrowings plan
 * (docs/superpowers/specs/2026-08-13-dsh-borrowings-plan.md §11).
 *
 * Steps existed in two parallel in-memory representations (the response's
 * `steps` and the display registry) and neither survived a restart. For a
 * product that runs shell commands with no sandbox and no pre-execution
 * confirmation, after-the-fact auditability is close to a required
 * compensating control.
 */

async function tempRoot(): Promise<string> {
  return mkdtemp(join(tmpdir(), "opentype-runlog-test-"));
}

describe("createRunLog", () => {
  test("appends one JSON line per event, in order", async () => {
    const root = await tempRoot();
    const log = createRunLog(root);

    await log.append("run-1", { type: "thinking", detail: "step 1" });
    await log.append("run-1", { type: "tool_call", detail: "bash(ls)" });
    await log.append("run-1", { type: "done", detail: "finished" });

    const entries = await readRunLog(root, "run-1");
    expect(entries.map((entry) => entry.type)).toEqual(["thinking", "tool_call", "done"]);
    expect(entries.map((entry) => entry.seq)).toEqual([0, 1, 2]);
  });

  test("stamps every entry with its run and a time", async () => {
    const root = await tempRoot();
    const log = createRunLog(root);

    await log.append("run-2", { type: "done", detail: "d" });

    const [entry] = await readRunLog(root, "run-2");
    expect(entry!.runId).toBe("run-2");
    expect(typeof entry!.time).toBe("number");
  });

  test("keeps runs in separate files", async () => {
    const root = await tempRoot();
    const log = createRunLog(root);

    await log.append("a", { type: "done", detail: "for a" });
    await log.append("b", { type: "done", detail: "for b" });

    expect((await readRunLog(root, "a")).length).toBe(1);
    expect((await readRunLog(root, "b"))[0]!.detail).toBe("for b");
  });

  test("stores the FULL detail, unlike the display feed", async () => {
    // The display registry truncates each detail to 400 chars. That bound is
    // a view concern; the durable record must keep what actually happened.
    const root = await tempRoot();
    const log = createRunLog(root);
    const huge = "x".repeat(5_000);

    await log.append("run-3", { type: "tool_result", detail: huge });

    expect((await readRunLog(root, "run-3"))[0]!.detail).toBe(huge);
  });

  test("survives a detail containing newlines", async () => {
    // JSONL's one-record-per-line invariant is the thing to protect, and
    // tool output is full of newlines.
    const root = await tempRoot();
    const log = createRunLog(root);

    await log.append("run-4", { type: "tool_result", detail: "line1\nline2\nline3" });

    const entries = await readRunLog(root, "run-4");
    expect(entries.length).toBe(1);
    expect(entries[0]!.detail).toBe("line1\nline2\nline3");
  });

  test("never throws when the root is unusable", async () => {
    // Best-effort, same stance as spill: failing to record a step must not
    // fail the run that produced it.
    const log = createRunLog("/proc/nonexistent-cannot-create");

    await expect(log.append("run-5", { type: "done", detail: "d" })).resolves.toBeUndefined();
  });

  test("sanitises a run id before it reaches the filesystem", async () => {
    const root = await tempRoot();
    const log = createRunLog(root);

    await log.append("../../escape", { type: "done", detail: "d" });

    // Nothing lands outside the root; the traversal attempt is flattened.
    const entries = await readRunLog(root, "../../escape");
    expect(entries.length).toBe(1);
  });

  test("reading an unknown run is empty, not an error", async () => {
    const root = await tempRoot();

    expect(await readRunLog(root, "never-written")).toEqual([]);
  });
});

describe("the run log is the source the response projects from", () => {
  test("a full run's log contains at least every step the response reports", async () => {
    const { runAgentLoop } = await import("../../src/agent/loop");
    const root = await tempRoot();
    const log = createRunLog(root);
    let call = 0;

    const result = await runAgentLoop(
      { task: "t" },
      {
        chat: async () => {
          call += 1;
          return call === 1
            ? {
                content: null,
                toolCalls: [
                  { id: "c", type: "function", function: { name: "probe", arguments: "{}" } },
                ],
              }
            : { content: "final" };
        },
        tools: { openAiTools: [], callTool: async () => ({ content: "tool said this" }) },
        onProgress: (event) => {
          void log.append("run-e2e", event);
        },
      }
    );

    // Let the fire-and-forget appends settle.
    await Bun.sleep(50);
    const entries = await readRunLog(root, "run-e2e");

    expect(entries.length).toBeGreaterThanOrEqual(result.steps.length);
    expect(entries.some((entry) => entry.detail === "tool said this")).toBe(true);
  });
});
