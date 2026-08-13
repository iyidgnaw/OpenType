import { describe, expect, test } from "bun:test";
import type { AgentProgressEvent } from "../../src/agent/loop";
// Stage-1 TDD (red): this module does not exist yet. The import below MUST
// fail with module-not-found until stage 3 creates
// `sidecar/src/agent/progressRegistry.ts`.
import { createAgentProgressRegistry } from "../../src/agent/progressRegistry";

/**
 * Contract for the in-memory agent progress registry
 * (spec: docs/superpowers/specs/2026-08-13-agent-progress-panel-design.md §2).
 *
 * Contract picks made by this test file (stage 1 owns these decisions;
 * stage 3 implements them exactly):
 *
 * - Factory: `createAgentProgressRegistry()` returns an object with
 *   `register(runId)`, `append(runId, event)`, `finish(runId, status)`,
 *   and `get(runId)`.
 * - `get(runId)` returns `{ status, events }` where `status` is
 *   `"running" | "done" | "failed" | "unknown"` and `events` is an array of
 *   `{ type, detail }` (the loop's `AgentProgressEvent` shape).
 * - `register(runId)` starts the run as `"running"` with no events.
 * - Detail truncation: an event `detail` of <= 400 chars is stored verbatim;
 *   a longer detail is truncated on append to at most 400 chars of original
 *   content plus a short visible marker containing the word "truncated"
 *   (total stored length <= 450). The truncated detail keeps the original's
 *   prefix.
 * - Event cap: at most 200 events are kept per run, dropping the OLDEST
 *   first (keep-newest). Rationale: the panel is a live feed and the final
 *   `done`/`error` event must survive the cap, which keep-first could drop.
 * - `finish(runId, "done" | "failed")` flips the status; events are kept.
 * - Retention: at most 20 FINISHED runs are retained; finishing more evicts
 *   the oldest-finished first (their `get` becomes `"unknown"`). Runs still
 *   `"running"` are never evicted, no matter how many runs finish around
 *   them.
 * - `append`/`finish` on an unknown (never-registered or evicted) id is a
 *   safe no-op: no throw, and it does not create/resurrect the run.
 */
describe("createAgentProgressRegistry", () => {
  function event(type: AgentProgressEvent["type"], detail: string): AgentProgressEvent {
    return { type, detail } as AgentProgressEvent;
  }

  test("register starts a run as 'running' with empty events", () => {
    const registry = createAgentProgressRegistry();

    registry.register("run-1");

    expect(registry.get("run-1")).toEqual({ status: "running", events: [] });
  });

  test("append accumulates events in order, preserving type and detail", () => {
    const registry = createAgentProgressRegistry();
    registry.register("run-1");

    registry.append("run-1", event("thinking", "Thinking (step 1/10)..."));
    registry.append("run-1", event("tool_call", 'Calling search__lookup({"q":"x"})'));
    registry.append("run-1", event("tool_result", "sunny, 75F"));

    const { status, events } = registry.get("run-1");
    expect(status).toBe("running");
    expect(events).toEqual([
      { type: "thinking", detail: "Thinking (step 1/10)..." },
      { type: "tool_call", detail: 'Calling search__lookup({"q":"x"})' },
      { type: "tool_result", detail: "sunny, 75F" },
    ]);
  });

  test("a detail of exactly 400 chars is stored verbatim (no marker)", () => {
    const registry = createAgentProgressRegistry();
    registry.register("run-1");
    const detail = "y".repeat(400);

    registry.append("run-1", event("tool_result", detail));

    expect(registry.get("run-1").events[0]?.detail).toBe(detail);
  });

  test("a long detail is truncated on append: bounded length, visible marker, prefix kept", () => {
    const registry = createAgentProgressRegistry();
    registry.register("run-1");
    const long = "0123456789".repeat(500); // 5000 chars

    registry.append("run-1", event("tool_result", long));

    const stored = registry.get("run-1").events[0]?.detail ?? "";
    expect(stored.length).toBeLessThanOrEqual(450);
    expect(stored).toContain("truncated");
    expect(stored.startsWith(long.slice(0, 100))).toBe(true);
  });

  test("event cap: appending 250 events keeps only the newest 200", () => {
    const registry = createAgentProgressRegistry();
    registry.register("run-1");

    for (let i = 1; i <= 250; i++) {
      registry.append("run-1", event("thinking", `evt-${i}`));
    }

    const { events } = registry.get("run-1");
    expect(events).toHaveLength(200);
    // Keep-newest (drop-oldest): the survivors are evt-51 .. evt-250, in order.
    expect(events[0]?.detail).toBe("evt-51");
    expect(events[199]?.detail).toBe("evt-250");
  });

  test("finish(runId, 'done') flips status to done and keeps the events", () => {
    const registry = createAgentProgressRegistry();
    registry.register("run-1");
    registry.append("run-1", event("done", "final answer"));

    registry.finish("run-1", "done");

    expect(registry.get("run-1")).toEqual({
      status: "done",
      events: [{ type: "done", detail: "final answer" }],
    });
  });

  test("finish(runId, 'failed') flips status to failed", () => {
    const registry = createAgentProgressRegistry();
    registry.register("run-1");

    registry.finish("run-1", "failed");

    expect(registry.get("run-1").status).toBe("failed");
  });

  test("get on an unknown id returns { status: 'unknown', events: [] }", () => {
    const registry = createAgentProgressRegistry();

    expect(registry.get("never-registered")).toEqual({ status: "unknown", events: [] });
  });

  test("retention: finishing a 21st run evicts the oldest finished run only", () => {
    const registry = createAgentProgressRegistry();

    for (let i = 1; i <= 21; i++) {
      const id = `run-${i}`;
      registry.register(id);
      registry.finish(id, "done");
    }

    // Oldest finished run is gone...
    expect(registry.get("run-1")).toEqual({ status: "unknown", events: [] });
    // ...and the remaining 20 finished runs are still retained.
    expect(registry.get("run-2").status).toBe("done");
    expect(registry.get("run-21").status).toBe("done");
  });

  test("retention: running runs are never evicted, no matter how many runs finish", () => {
    const registry = createAgentProgressRegistry();
    registry.register("long-runner");
    registry.append("long-runner", event("thinking", "still going"));

    for (let i = 1; i <= 25; i++) {
      const id = `finished-${i}`;
      registry.register(id);
      registry.finish(id, "done");
    }

    const longRunner = registry.get("long-runner");
    expect(longRunner.status).toBe("running");
    expect(longRunner.events).toEqual([{ type: "thinking", detail: "still going" }]);
  });

  test("append/finish on a never-registered id is a safe no-op", () => {
    const registry = createAgentProgressRegistry();

    expect(() => registry.append("ghost", event("thinking", "boo"))).not.toThrow();
    expect(() => registry.finish("ghost", "done")).not.toThrow();
    // The no-op must not create the run either.
    expect(registry.get("ghost")).toEqual({ status: "unknown", events: [] });
  });

  test("append/finish on an evicted id is a safe no-op and does not resurrect it", () => {
    const registry = createAgentProgressRegistry();
    for (let i = 1; i <= 21; i++) {
      const id = `run-${i}`;
      registry.register(id);
      registry.finish(id, "done");
    }
    expect(registry.get("run-1").status).toBe("unknown"); // precondition: evicted

    expect(() => registry.append("run-1", event("thinking", "late event"))).not.toThrow();
    expect(() => registry.finish("run-1", "failed")).not.toThrow();
    expect(registry.get("run-1")).toEqual({ status: "unknown", events: [] });
  });
});
