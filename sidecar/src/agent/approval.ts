import { classifyCommandRisk } from "./commandRisk";
import type { AskUserBroker, AskUserQuestion } from "./askUser";
import type { ToolSet } from "./toolSets";

/**
 * Approval seam for agent tool calls (B2 core tools v2,
 * docs/superpowers/specs/2026-08-13-b2-agent-core-tools-v2-design.md §1/§4;
 * vocabulary hardened by T6 of
 * docs/superpowers/specs/2026-08-13-dsh-borrowings-plan.md §12; the prompting
 * policy added by P1-6,
 * docs/superpowers/specs/2026-08-14-product-batch-plan.md).
 *
 * Two policies ship. `yoloApprovalPolicy` (always allow) is the baseline
 * `server.ts` wraps the *merged* tool set in at construction, so built-in
 * memory tools, core shell/file/web tools, and MCP alike flow through one
 * gate. `createPromptingApprovalPolicy` is what `/agent/run` applies on top,
 * per run: it asks a human about the small class of calls
 * `commandRisk.ts` recognises as destructive, and lets everything else
 * through untouched.
 *
 * That asymmetry is the stance, not a halfway house. YOLO stays the default --
 * no sandbox, no confirmation for ordinary tool calls -- because a guard that
 * fires often trains the user to click through it, which is worse than no
 * guard: it manufactures both the interruption and the complacency. See
 * `commandRisk.ts` for exactly what "destructive" promises and, more
 * importantly, what it does not.
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

/** The baseline policy: every tool call is auto-approved (YOLO). */
export const yoloApprovalPolicy: ApprovalPolicy = {
  approve: async () => "allowed-once",
};

/**
 * The id the approval question carries, and how its answer routes back
 * (`AskUserAnswerItem.id`). Stable because the policy and whatever UI renders
 * the card have to agree on it.
 */
export const APPROVAL_QUESTION_ID = "opentype__approval";

/** The two labels; `label` is both the UI text and the answer value. */
export const APPROVAL_APPROVE_LABEL = "允许这一次";
export const APPROVAL_DENY_LABEL = "不要执行";

export interface PromptingApprovalPolicyOptions {
  /** The same broker `opentype__ask_user` uses -- one question channel per run. */
  broker: AskUserBroker;
  /** The run to address; absent means there is nobody to ask. */
  runId: string | undefined;
  /** How long to wait for a human before giving up. */
  timeoutMs: number;
  /** The run's cancellation, so a stopped run withdraws its question. */
  signal?: AbortSignal;
}

function approvalQuestion(toolName: string, args: unknown): AskUserQuestion {
  // The user is being asked to vouch for something, which they can only do if
  // they can see it -- verbatim, not summarised.
  const payload =
    (args as { command?: unknown; code?: unknown } | undefined)?.command ??
    (args as { command?: unknown; code?: unknown } | undefined)?.code;
  const shown = typeof payload === "string" ? payload : JSON.stringify(args ?? null);
  return {
    id: APPROVAL_QUESTION_ID,
    question: "这条命令会删除或覆盖文件，要执行吗？",
    detail: `${toolName}\n${shown}`,
    options: [
      { label: APPROVAL_APPROVE_LABEL, description: "只放行这一次" },
      { label: APPROVAL_DENY_LABEL, description: "跳过这一步，让它换个做法" },
    ],
    // One decision, not a multi-select: approving and denying the same command
    // is not a state that should be expressible.
    multiSelect: false,
  };
}

/**
 * The policy P1-6 ships: safe calls sail through, destructive ones ask the
 * human through the existing `ask_user` channel.
 *
 * Built per run rather than once at construction, because asking needs this
 * run's id (there is a surface polling `GET /agent/question/:runId` for it),
 * this run's cancellation signal, and the broker -- none of which exist where
 * `server.ts` assembles the tool set. See `agent/routes.ts`.
 *
 * The three denials stay distinct, and the distinction is load-bearing:
 * `rejected` is the human saying no, `cancelled` is the question being
 * withdrawn because the run was stopped, and `unavailable` is there being
 * nobody to ask. Conflating the last two would let the model read "I could not
 * reach you" as "you said no" -- the difference between a retry and a dead
 * end.
 */
export function createPromptingApprovalPolicy(
  options: PromptingApprovalPolicyOptions
): ApprovalPolicy {
  return {
    async approve(toolName, args) {
      // The YOLO default, and the thing this feature must not quietly become:
      // everything the classifier does not recognise as destructive runs
      // without anyone being asked.
      if (classifyCommandRisk(toolName, args) === "safe") {
        return "allowed-once";
      }

      const { broker, runId, timeoutMs, signal } = options;
      if (signal?.aborted) {
        return "cancelled";
      }
      if (!runId) {
        // `askUser.ts`'s "only a live runtime root may ask", in this policy's
        // terms: a run with no id has no surface polling for it, so waiting
        // could only ever time out -- and a headless run must not stall the
        // sidecar for the full timeout on every destructive command.
        return "unavailable";
      }

      const { promise, settle } = broker.wait(runId, [approvalQuestion(toolName, args)]);
      const timer = setTimeout(settle, timeoutMs);
      const onAbort = (): void => settle();
      signal?.addEventListener("abort", onAbort, { once: true });

      let answer;
      try {
        answer = await promise;
      } finally {
        clearTimeout(timer);
        signal?.removeEventListener("abort", onAbort);
      }

      if (!answer) {
        // `settle()` resolves the same way for both, so which one it was is
        // read off the signal rather than tracked separately.
        return signal?.aborted ? "cancelled" : "unavailable";
      }

      const item = answer.answers.find((entry) => entry.id === APPROVAL_QUESTION_ID);
      if (item?.selected?.includes(APPROVAL_APPROVE_LABEL)) {
        // Exactly this call. There is no "allow always", so the next
        // destructive command asks again.
        return "allowed-once";
      }
      // Denial, a dismissed card (empty `selected`, how `AskUserAnswerItem`
      // encodes "skipped"), or an answer to some other question. Reading
      // silence as consent would mean a user who closed the card got their
      // disk written to anyway.
      return "rejected";
    },
  };
}

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
