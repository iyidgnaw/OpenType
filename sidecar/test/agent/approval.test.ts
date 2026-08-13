/**
 * Tests for the approval seam (B2 core tools v2 design,
 * docs/superpowers/specs/2026-08-13-b2-agent-core-tools-v2-design.md §4).
 *
 * v2 ships exactly one policy -- `yoloApprovalPolicy` (always allow) -- but
 * the seam itself is the architecture being tested here: every tool call
 * flows through `withApproval`, and a denial must surface to the model as a
 * normal tool-error result (`{ content }`), never as a rejection/crash.
 */
import { describe, expect, test } from "bun:test";
import type { ToolSet } from "../../src/agent/toolSets";
import {
  withApproval,
  yoloApprovalPolicy,
  type ApprovalPolicy,
} from "../../src/agent/approval";

interface RecordedCall {
  name: string;
  args: unknown;
}

function makeRecordingToolSet(
  toolNames: string[],
  result = "inner tool result"
): { set: ToolSet; calls: RecordedCall[] } {
  const calls: RecordedCall[] = [];
  const set: ToolSet = {
    openAiTools: toolNames.map((name) => ({ type: "function", function: { name } })),
    callTool: async (name, args) => {
      calls.push({ name, args });
      return { content: result };
    },
  };
  return { set, calls };
}

describe("yoloApprovalPolicy", () => {
  // T6 replaced the two-valued `{ allowed }` decision with the closed
  // fail-closed outcome vocabulary (see approvalVocabulary.test.ts): the
  // grant is now a named value rather than a boolean, so that a denial can
  // say WHICH kind of denial it is.
  test("approves any tool name and any args with 'allowed-once'", async () => {
    await expect(
      yoloApprovalPolicy.approve("opentype__bash", { command: "rm -rf /tmp/whatever" })
    ).resolves.toBe("allowed-once");
    await expect(
      yoloApprovalPolicy.approve("some_mcp_server__anything", null)
    ).resolves.toBe("allowed-once");
  });
});

describe("withApproval", () => {
  test("returns a ToolSet exposing the same openAiTools contents as the wrapped set", () => {
    const { set } = makeRecordingToolSet(["opentype__bash", "opentype__read_file"]);

    const wrapped = withApproval(set, yoloApprovalPolicy);

    expect(wrapped.openAiTools).toEqual(set.openAiTools);
  });

  test("on an allowing policy, callTool passes through with the same name/args and result", async () => {
    const { set, calls } = makeRecordingToolSet(["opentype__bash"], "passthrough-ok");
    const wrapped = withApproval(set, yoloApprovalPolicy);

    const result = await wrapped.callTool("opentype__bash", { command: "echo hi", cwd: "/tmp" });

    expect(result).toEqual({ content: "passthrough-ok" });
    expect(calls).toHaveLength(1);
    expect(calls[0]).toEqual({
      name: "opentype__bash",
      args: { command: "echo hi", cwd: "/tmp" },
    });
  });

  test("on a denying policy, the wrapped tool is never invoked and the denial resolves as { content }", async () => {
    const { set, calls } = makeRecordingToolSet(["opentype__bash"]);
    const denyAll: ApprovalPolicy = { approve: async () => "rejected" };
    const wrapped = withApproval(set, denyAll);

    // Per design §1: "a denial surfaces to the model as a tool-error result,
    // never a crash" -- so this must resolve, not reject.
    const result = await wrapped.callTool("opentype__bash", { command: "echo hi" });

    expect(calls).toHaveLength(0);
    expect(result.content).toMatch(/denied/i);
    // T6: the outcome is a closed value, so the denial no longer carries the
    // policy's own free text. Free-text reasons did not disappear -- they
    // moved to `ToolGuard`, which is the layer that HAS a specific reason to
    // give ("denied by a guard: <why>"). An approval outcome answers "may
    // this proceed", not "explain yourself".
    expect(result.content).toContain("the user denied it");
  });

  test("the policy receives the tool name and parsed args of the call", async () => {
    const { set } = makeRecordingToolSet(["opentype__grep"]);
    const seen: RecordedCall[] = [];
    const recordingPolicy: ApprovalPolicy = {
      approve: async (toolName, args) => {
        seen.push({ name: toolName, args });
        return "allowed-once";
      },
    };
    const wrapped = withApproval(set, recordingPolicy);

    await wrapped.callTool("opentype__grep", { pattern: "needle", caseInsensitive: true });

    expect(seen).toHaveLength(1);
    expect(seen[0]).toEqual({
      name: "opentype__grep",
      args: { pattern: "needle", caseInsensitive: true },
    });
  });
});
