import { describe, expect, test } from "bun:test";
import {
  withApproval,
  yoloApprovalPolicy,
  type ApprovalPolicy,
  type ToolGuard,
} from "../../src/agent/approval";
import type { ToolSet } from "../../src/agent/toolSets";

/**
 * T6 of the dsh-borrowings plan
 * (docs/superpowers/specs/2026-08-13-dsh-borrowings-plan.md §12).
 *
 * The seam already existed; what it lacked was a vocabulary that fails
 * closed. A two-valued decision cannot tell "the user said no" from "there
 * was nobody to ask", and those need opposite handling the day a real
 * prompting policy lands.
 */

function countingTools(): { tools: ToolSet; calls: string[] } {
  const calls: string[] = [];
  return {
    calls,
    tools: {
      openAiTools: [],
      callTool: async (name) => {
        calls.push(name);
        return { content: "executed" };
      },
    },
  };
}

const allow = (outcome: ApprovalPolicy["approve"] extends never ? never : never) => outcome;
void allow;

describe("the four-valued outcome", () => {
  test("only allowed-once actually runs the tool", async () => {
    for (const outcome of ["rejected", "cancelled", "unavailable"] as const) {
      const { tools, calls } = countingTools();
      const policy: ApprovalPolicy = { approve: async () => outcome };

      const result = await withApproval(tools, policy).callTool("t", {});

      expect(calls).toEqual([]);
      expect(result.content).toContain("denied");
    }

    const { tools, calls } = countingTools();
    await withApproval(tools, { approve: async () => "allowed-once" }).callTool("t", {});
    expect(calls).toEqual(["t"]);
  });

  test("names the outcome in the denial so the model can react to it", async () => {
    const { tools } = countingTools();

    const rejected = await withApproval(tools, { approve: async () => "rejected" }).callTool("t", {});
    const unavailable = await withApproval(tools, {
      approve: async () => "unavailable",
    }).callTool("t", {});

    expect(rejected.content).not.toBe(unavailable.content);
  });

  test("a throwing policy denies rather than crashing or opening the gate", async () => {
    const { tools, calls } = countingTools();
    const policy: ApprovalPolicy = {
      approve: async () => {
        throw new Error("answerer exploded");
      },
    };

    const result = await withApproval(tools, policy).callTool("t", {});

    expect(calls).toEqual([]);
    expect(result.content).toContain("denied");
    // The failure must not leak an internal message to the model as if it
    // were a decision.
    expect(result.content).not.toContain("exploded");
  });

  test("a rogue out-of-vocabulary return is normalised to a denial", async () => {
    const { tools, calls } = countingTools();
    const policy = { approve: async () => "yes-please" } as unknown as ApprovalPolicy;

    const result = await withApproval(tools, policy).callTool("t", {});

    expect(calls).toEqual([]);
    expect(result.content).toContain("denied");
  });

  test("a denial is a normal tool result, never a rejection", async () => {
    // The loop reports a denial to the model and keeps going; turning it into
    // a throw would end the run instead.
    const { tools } = countingTools();

    await expect(
      withApproval(tools, { approve: async () => "rejected" }).callTool("t", {})
    ).resolves.toHaveProperty("content");
  });

  test("the shipped YOLO policy still allows everything", async () => {
    const { tools, calls } = countingTools();

    await withApproval(tools, yoloApprovalPolicy).callTool("anything", {});

    expect(calls).toEqual(["anything"]);
  });
});

describe("monotonic guards", () => {
  const denies: ToolGuard = () => "denied by policy";
  const abstains: ToolGuard = () => undefined;

  test("any guard can deny", async () => {
    const { tools, calls } = countingTools();

    const result = await withApproval(tools, yoloApprovalPolicy, [abstains, denies]).callTool(
      "t",
      {}
    );

    expect(calls).toEqual([]);
    expect(result.content).toContain("denied by policy");
  });

  test("guard order cannot change the outcome", async () => {
    // This is the whole point of having no `allow` in the return type: a
    // later guard can never undo an earlier denial, so registration order
    // carries no security meaning.
    const { tools: a, calls: callsA } = countingTools();
    const { tools: b, calls: callsB } = countingTools();

    await withApproval(a, yoloApprovalPolicy, [denies, abstains]).callTool("t", {});
    await withApproval(b, yoloApprovalPolicy, [abstains, denies]).callTool("t", {});

    expect(callsA).toEqual([]);
    expect(callsB).toEqual([]);
  });

  test("all-abstaining guards leave the call allowed", async () => {
    const { tools, calls } = countingTools();

    await withApproval(tools, yoloApprovalPolicy, [abstains, abstains]).callTool("t", {});

    expect(calls).toEqual(["t"]);
  });

  test("a throwing guard denies (fail closed)", async () => {
    const { tools, calls } = countingTools();
    const explodes: ToolGuard = () => {
      throw new Error("guard bug");
    };

    const result = await withApproval(tools, yoloApprovalPolicy, [explodes]).callTool("t", {});

    expect(calls).toEqual([]);
    expect(result.content).toContain("denied");
  });

  test("guards run only after the policy allows", async () => {
    // A rejected call must not be re-examined: the guards exist to REDUCE
    // permission, never to reconsider a decision already made against it.
    let guardRuns = 0;
    const counting: ToolGuard = () => {
      guardRuns += 1;
      return undefined;
    };
    const { tools } = countingTools();

    await withApproval(tools, { approve: async () => "rejected" }, [counting]).callTool("t", {});

    expect(guardRuns).toBe(0);
  });
});

describe("approval audit", () => {
  test("reports the asked/decided pair with a shared id", async () => {
    const events: { type: string; requestId: string; outcome?: string }[] = [];
    const { tools } = countingTools();

    await withApproval(tools, { approve: async () => "allowed-once" }, [], (event) =>
      events.push(event)
    ).callTool("bash", {});

    expect(events.map((event) => event.type)).toEqual([
      "approval_asked",
      "approval_decided",
    ]);
    expect(events[0]!.requestId).toBe(events[1]!.requestId);
    expect(events[1]!.outcome).toBe("allowed-once");
  });

  test("records the denial outcome too", async () => {
    const events: { type: string; outcome?: string }[] = [];
    const { tools } = countingTools();

    await withApproval(tools, { approve: async () => "rejected" }, [], (event) =>
      events.push(event)
    ).callTool("bash", {});

    expect(events[1]!.outcome).toBe("rejected");
  });

  test("a failing audit sink never breaks the call", async () => {
    const { tools, calls } = countingTools();

    const result = await withApproval(tools, yoloApprovalPolicy, [], () => {
      throw new Error("sink down");
    }).callTool("t", {});

    expect(calls).toEqual(["t"]);
    expect(result.content).toBe("executed");
  });
});
