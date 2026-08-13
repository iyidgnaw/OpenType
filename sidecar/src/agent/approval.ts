import type { ToolSet } from "./toolSets";

/**
 * Approval seam for agent tool calls (B2 core tools v2,
 * docs/superpowers/specs/2026-08-13-b2-agent-core-tools-v2-design.md §1/§4).
 *
 * v2 ships exactly one policy -- `yoloApprovalPolicy`, always allow -- as a
 * deliberate, owner-accepted stance for a single-user, self-configured local
 * tool: no sandbox, no pre-execution confirmation. The seam itself is the
 * point: `server.ts` wraps the *merged* tool set (built-in memory tools, core
 * shell/file/web tools, and MCP alike) in `withApproval`, so a later
 * user-prompting policy (popup/notification + approve/deny) can be swapped in
 * without restructuring anything -- every tool call already flows through
 * this one gate.
 *
 * A denial must surface to the model as a normal tool-error result
 * (`{ content }`), never as a rejection/crash, so the agent loop can report
 * it and keep going.
 */
export type ApprovalDecision = { allowed: true } | { allowed: false; reason: string };

export interface ApprovalPolicy {
  approve(toolName: string, args: unknown): Promise<ApprovalDecision>;
}

/** The only shipped policy in v2: every tool call is auto-approved (YOLO). */
export const yoloApprovalPolicy: ApprovalPolicy = {
  approve: async () => ({ allowed: true }),
};

/**
 * Wraps a tool set so every `callTool` consults `policy` first. Allowed calls
 * pass through with the same name/args and result; denied calls resolve with
 * a content string naming the denial and its reason, without ever invoking
 * the wrapped tool. `openAiTools` is exposed unchanged -- approval gates
 * execution, not visibility.
 */
export function withApproval(tools: ToolSet, policy: ApprovalPolicy): ToolSet {
  return {
    openAiTools: tools.openAiTools,
    callTool: async (name, args) => {
      const decision = await policy.approve(name, args);
      if (!decision.allowed) {
        return {
          content: `Tool call to ${name} was denied by the approval policy: ${decision.reason}`,
        };
      }
      return tools.callTool(name, args);
    },
  };
}
