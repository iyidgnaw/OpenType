import { describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, readdir, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDatabase } from "../../src/memory/db";
import { MemoryStore } from "../../src/memory/MemoryStore";
import { ConversationStore } from "../../src/memory/conversations";
import type { AgentChatFn } from "../../src/agent/loop";
import type { McpToolSet } from "../../src/agent/mcpClient";
import { buildAgentRoutes } from "../../src/agent/routes";
import { createRouter } from "../../src/router";
import type { ContextUsageLogWriter } from "../../src/oneshot/contextDebugLog";

/**
 * Stage-1 (TDD red) coverage for `DELETE /agent/run-logs`.
 *
 * Owner decision: run logs (`run-logs/<runId>.jsonl`, `sidecar/src/agent/
 * runLog.ts`) are records of what the user asked the agent to do, so
 * 「清除本地数据」 (`AppModel.resetHistory()`) must clear them too, the same way
 * it already clears `episodic_events` (`DELETE /memory/events`) and the
 * context-debug log (`DELETE /memory/context-log`). This file pins the new
 * route's serving side; `RunLogsResetRequestTests.swift` (Swift, separate
 * PR-half) pins `resetHistory()`'s calling side.
 *
 * THE MISSING SURFACE (stage 3 builds this; nothing here builds it): a new
 * route entry inside `buildAgentRoutes` --
 *
 *     { method: "DELETE", path: "/agent/run-logs", handler: ... }
 *
 * -- that removes every `*.jsonl` file directly under the `runLogRoot`
 * parameter `buildAgentRoutes` already accepts (used today only to
 * construct `createRunLog(runLogRoot)`), and:
 *   - touches nothing else: not the directory itself, not non-`.jsonl`
 *     files that happen to sit in the same root;
 *   - returns the same response shape `DELETE /memory/events` uses
 *     (`sidecar/src/memory/routes.ts` ~:222-227): `{ deleted: <count> }`,
 *     where `<count>` is how many files were actually removed;
 *   - is a no-op, not an error, when `runLogRoot` is empty, missing, or
 *     (matching every other trailing-optional-parameter route in this file)
 *     was never configured at all -- `{ deleted: 0 }`, HTTP 200.
 *
 * ## Per-file failure isolation (stage-4 finding, closed here rather than deferred)
 *
 * The first implementation's `handleDeleteRunLogs` awaited `Promise.all`
 * over every `unlink` with no per-file catch: one failing unlink (e.g. a
 * concurrent agent run's own `pruneToRetentionCap` removing the same file
 * between this handler's `readdir` and its `unlink`) rejects the whole
 * `Promise.all`, which the router turns into a 500 -- so `resetHistory()`
 * records a `historyResetError` for a reset that mostly worked. That is the
 * exact same "success reported as failure" shape as the `Memory
 * DeletionResponseBody` decoder bug fixed alongside this, arriving through a
 * different door, so it is closed the same way rather than left open here:
 * an unlink failing for ONE entry must not fail the request. The handler
 * must catch each `unlink` individually, count only the ones that actually
 * succeeded, and still return 200 with that count -- leaving whatever it
 * could not remove in place, exactly like the existing "leaves a non-.jsonl
 * file untouched" test already expects for a different reason.
 */

function makeStore(): MemoryStore {
  return new MemoryStore(openDatabase(":memory:"));
}

function makeConversations(): ConversationStore {
  return new ConversationStore(openDatabase(":memory:"));
}

function noTools(): McpToolSet {
  return { openAiTools: [], callTool: async () => ({ content: "" }) };
}

function noopLog(): ContextUsageLogWriter {
  return () => {};
}

function routerWithRunLogRoot(runLogRoot?: string) {
  const chat: AgentChatFn = async () => ({ content: "x" });
  return createRouter(
    buildAgentRoutes(
      makeStore(),
      makeConversations(),
      chat,
      noTools(),
      noopLog(),
      undefined, // spillRoot
      runLogRoot
    )
  );
}

function deleteRunLogs(): Request {
  return new Request("http://sidecar/agent/run-logs", { method: "DELETE" });
}

async function tempRoot(): Promise<string> {
  return mkdtemp(join(tmpdir(), "opentype-runlog-routes-test-"));
}

describe("DELETE /agent/run-logs", () => {
  test("removes every *.jsonl file under the run-log root and reports how many", async () => {
    const root = await tempRoot();
    await writeFile(join(root, "run-1.jsonl"), "{}\n");
    await writeFile(join(root, "run-2.jsonl"), "{}\n");
    const router = routerWithRunLogRoot(root);

    const response = await router(deleteRunLogs());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ deleted: 2 });
    expect(await readdir(root)).toEqual([]);
  });

  test("leaves a non-.jsonl file untouched", async () => {
    const root = await tempRoot();
    await writeFile(join(root, "run-1.jsonl"), "{}\n");
    await writeFile(join(root, "notes.txt"), "keep me");
    const router = routerWithRunLogRoot(root);

    const response = await router(deleteRunLogs());

    expect(await response.json()).toEqual({ deleted: 1 });
    expect(await readdir(root)).toEqual(["notes.txt"]);
  });

  test("leaves the run-log directory itself present", async () => {
    const root = await tempRoot();
    await writeFile(join(root, "run-1.jsonl"), "{}\n");
    const router = routerWithRunLogRoot(root);

    await router(deleteRunLogs());

    expect(existsSync(root)).toBe(true);
  });

  test("an empty run-log root is a no-op, not an error", async () => {
    const root = await tempRoot();
    const router = routerWithRunLogRoot(root);

    const response = await router(deleteRunLogs());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ deleted: 0 });
  });

  test("a missing run-log root (never created) is a no-op, not an error", async () => {
    const root = join(await tempRoot(), "never-created");
    const router = routerWithRunLogRoot(root);

    const response = await router(deleteRunLogs());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ deleted: 0 });
  });

  test("no runLogRoot configured at all (matches every other trailing-optional param in this file) is a no-op, not a crash", async () => {
    const router = routerWithRunLogRoot(undefined);

    const response = await router(deleteRunLogs());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ deleted: 0 });
  });

  test("one entry failing to unlink does not fail the request -- it still deletes everything it can and reports that count", async () => {
    const root = await tempRoot();
    await writeFile(join(root, "a.jsonl"), "{}\n");
    await writeFile(join(root, "b.jsonl"), "{}\n");
    // A DIRECTORY named "c.jsonl": `readdir` lists it and the `.jsonl`
    // filter keeps it (the filter is name-based, not a file-type check),
    // but `unlink` on a directory fails (EPERM/EISDIR on macOS/Linux)
    // while `a.jsonl`/`b.jsonl` -- real files -- unlink fine. This
    // reproduces the "one bad entry among several" shape without mocking
    // the filesystem: it's a real, reachable failure (a concurrent run's
    // own retention prune racing this handler's readdir-then-unlink would
    // throw ENOENT the same deletion-fails-but-request-must-not way).
    await mkdir(join(root, "c.jsonl"));
    const router = routerWithRunLogRoot(root);

    const response = await router(deleteRunLogs());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ deleted: 2 });
    const remaining = await readdir(root);
    expect(remaining).not.toContain("a.jsonl");
    expect(remaining).not.toContain("b.jsonl");
    expect(remaining).toContain("c.jsonl");
    expect(existsSync(root)).toBe(true);
  });
});
