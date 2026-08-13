import type { ToolSet } from "./toolSets";

/**
 * Approval seam for agent tool calls (B2 core tools v2,
 * docs/superpowers/specs/2026-08-13-b2-agent-core-tools-v2-design.md §1/§4;
 * vocabulary hardened by T6 of
 * docs/superpowers/specs/2026-08-13-dsh-borrowings-plan.md §12).
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

/**
 * Closed, fail-closed outcome vocabulary borrowed from dsh's approval seam.
 *
 * Only `allowed-once` is a grant, and it grants exactly the call it was asked
 * about. The three denials stay distinct because they need different handling
 * the day a real prompting policy lands: `rejected` is the human saying no,
 * `cancelled` is the question being withdrawn (the run was stopped), and
 * `unavailable` is there being nobody to ask. The previous two-valued
 * decision could not express the difference between the last two -- exactly
 * the pair where guessing wrong is dangerous.
 */
export type ApprovalOutcome = "allowed-once" | "rejected" | "cancelled" | "unavailable";

const OUTCOMES: readonly ApprovalOutcome[] = [
  "allowed-once",
  "rejected",
  "cancelled",
  "unavailable",
];

export interface ApprovalPolicy {
  approve(toolName: string, args: unknown): Promise<ApprovalOutcome>;
}

/** The only shipped policy in v2: every tool call is auto-approved (YOLO). */
export const yoloApprovalPolicy: ApprovalPolicy = {
  approve: async () => "allowed-once",
};

/**
 * A final, monotonic pre-dispatch check.
 *
 * The return type deliberately has NO allow result: `undefined` leaves the
 * call as it stands, a string denies it. Because a guard cannot grant, a
 * later guard can never undo an earlier denial -- so registration order
 * carries no security meaning and cannot be got wrong. Straight from dsh's
 * `ToolGuard`, which makes the same point with the same missing case.
 *
 * @param call - the tool about to run.
 * @returns a denial reason, or `undefined` to abstain.
 */
export type ToolGuard = (call: { name: string; args: unknown }) => string | undefined;

/** One half of the audit pair; both halves share a `requestId`. */
export interface ApprovalAuditEvent {
  type: "approval_asked" | "approval_decided";
  requestId: string;
  toolName: string;
  /** Present on `approval_decided` only. */
  outcome?: ApprovalOutcome;
}

/** Denial text per outcome, so the model can tell the three apart. */
const DENIAL_TEXT: Record<Exclude<ApprovalOutcome, "allowed-once">, string> = {
  rejected: "the user denied it",
  cancelled: "the request was withdrawn",
  unavailable: "no approval channel was available",
};

let nextRequestId = 0;

/**
 * Wraps a tool set so every `callTool` passes the approval gate, then the
 * monotonic guards, before reaching the tool.
 *
 * @param tools - the set to protect; `openAiTools` is exposed unchanged,
 *   because approval gates EXECUTION, not visibility.
 * @param policy - decides each call.
 * @param guards - final checks that may only reduce permission.
 * @param audit - optional sink for the asked/decided pair.
 */
export function withApproval(
  tools: ToolSet,
  policy: ApprovalPolicy,
  guards: readonly ToolGuard[] = [],
  audit?: (event: ApprovalAuditEvent) => void
): ToolSet {
  function report(event: ApprovalAuditEvent): void {
    try {
      audit?.(event);
    } catch {
      // An audit sink failure must not change what the call does: it was
      // already allowed or denied on its own merits.
    }
  }

  return {
    openAiTools: tools.openAiTools,
    callTool: async (name, args, signal) => {
      const requestId = `approval-${(nextRequestId += 1)}`;
      report({ type: "approval_asked", requestId, toolName: name });

      let outcome: ApprovalOutcome;
      try {
        outcome = await policy.approve(name, args);
      } catch {
        // Fail closed. A policy that threw has granted nothing, and surfacing
        // its internal message would dress a crash up as a decision.
        outcome = "unavailable";
      }
      if (!OUTCOMES.includes(outcome)) {
        outcome = "unavailable";
      }

      report({ type: "approval_decided", requestId, toolName: name, outcome });

      if (outcome !== "allowed-once") {
        return {
          content: `Tool call to ${name} was denied by the approval policy: ${DENIAL_TEXT[outcome]}.`,
        };
      }

      // Guards run only AFTER a grant: they exist to reduce permission, never
      // to reconsider a call the policy already refused.
      for (const guard of guards) {
        let reason: string | undefined;
        try {
          reason = guard({ name, args });
        } catch {
          reason = "a guard failed to evaluate";
        }
        if (reason !== undefined) {
          return { content: `Tool call to ${name} was denied by a guard: ${reason}` };
        }
      }

      return tools.callTool(name, args, signal);
    },
  };
}
