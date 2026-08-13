/**
 * The agent's way to ask the user a question mid-run (T5 of
 * docs/superpowers/specs/2026-08-13-dsh-borrowings-plan.md §13).
 *
 * Voice input is inherently ambiguous -- homophones, pronouns, elision. "把
 * 桌面那个 PDF 发给他" with three PDFs on the Desktop was a coin flip, and the
 * agent had no way to do anything but guess. This turns "guess once, be wrong,
 * start over" into "ask one question".
 *
 * Borrowed from dsh's user-questions seam, including its two structural
 * choices: a request carries MULTIPLE questions with stable ids (so a UI can
 * present one coherent flow and answers still route unambiguously), and the
 * answer encoding is independent of how the question is presented -- a richer
 * UI later must not change what the agent receives.
 *
 * The rule that matters most is dsh's "only a live runtime root may ask": a
 * question nobody can answer must FAIL, never park forever holding the run.
 * Here that becomes two guarantees -- no run id means an immediate refusal,
 * and every question carries a timeout.
 *
 * MODEL EXPERIENCE: the rendered answer becomes the tool result the model
 * reads. See `docs/model-context-inventory.md` §3.5.
 */
import type { ToolSet } from "./toolSets";

export const ASK_USER_TOOL_NAME = "opentype__ask_user";

/** One offered choice. `label` is both the UI text and the answer value. */
export interface AskUserOption {
  label: string;
  description?: string;
}

/** One question in a request. */
export interface AskUserQuestion {
  /** Stable id echoed back with the answer; how answers route. */
  id: string;
  question: string;
  /** Supporting text shown with the question but never an option label. */
  detail?: string;
  options?: AskUserOption[];
  /** Defaults to single-select. */
  multiSelect?: boolean;
}

/** One question's answer. */
export interface AskUserAnswerItem {
  id: string;
  /** Chosen option labels; empty with no `custom` means the user skipped it. */
  selected: string[];
  /** Free-text "other" answer. */
  custom?: string;
}

export interface AskUserAnswer {
  answers: AskUserAnswerItem[];
}

/** A question waiting for the UI, as the transport hands it out. */
export interface PendingAsk {
  runId: string;
  questions: AskUserQuestion[];
}

/**
 * Routes questions from the agent to whatever UI is polling, and answers
 * back. One pending question per run: the agent is a single loop, so it
 * cannot be waiting on two at once.
 */
export interface AskUserBroker {
  /** The question this run is waiting on, if any. */
  pending(runId: string): PendingAsk | undefined;
  /** Deliver an answer. Unknown or already-settled runs are a no-op. */
  answer(runId: string, answer: AskUserAnswer): void;
  /** Register a waiter; returns its resolver handle. Internal to the tool. */
  wait(
    runId: string,
    questions: AskUserQuestion[]
  ): { promise: Promise<AskUserAnswer | undefined>; settle: () => void };
}

export function createAskUserBroker(): AskUserBroker {
  const waiting = new Map<
    string,
    { questions: AskUserQuestion[]; resolve: (answer: AskUserAnswer | undefined) => void }
  >();

  return {
    pending(runId) {
      const entry = waiting.get(runId);
      return entry ? { runId, questions: entry.questions } : undefined;
    },
    answer(runId, answer) {
      const entry = waiting.get(runId);
      if (!entry) {
        return;
      }
      waiting.delete(runId);
      entry.resolve(answer);
    },
    wait(runId, questions) {
      let resolve!: (answer: AskUserAnswer | undefined) => void;
      const promise = new Promise<AskUserAnswer | undefined>((r) => {
        resolve = r;
      });
      waiting.set(runId, { questions, resolve });
      return {
        promise,
        // Removing the entry is what makes giving up safe: a late answer
        // resolves nothing, and the next question is not blocked by a corpse.
        settle: () => {
          if (waiting.get(runId)?.resolve === resolve) {
            waiting.delete(runId);
          }
          resolve(undefined);
        },
      };
    },
  };
}

export interface AskUserToolOptions {
  /** The run to address; absent means there is no UI channel at all. */
  runId: string | undefined;
  /** How long to wait for a human before giving up. */
  timeoutMs: number;
}

function parseQuestions(raw: unknown): { questions: AskUserQuestion[] } | { error: string } {
  const list = (raw as { questions?: unknown } | undefined)?.questions;
  if (!Array.isArray(list) || list.length === 0) {
    return { error: "ask_user requires at least one question." };
  }
  const questions: AskUserQuestion[] = [];
  for (const entry of list) {
    const item = (entry ?? {}) as Partial<AskUserQuestion>;
    if (typeof item.id !== "string" || item.id.length === 0) {
      return { error: "Every ask_user question needs a stable id." };
    }
    if (typeof item.question !== "string" || item.question.trim().length === 0) {
      return { error: `Question ${item.id} needs non-empty question text.` };
    }
    questions.push({
      id: item.id,
      question: item.question,
      detail: typeof item.detail === "string" ? item.detail : undefined,
      options: Array.isArray(item.options) ? (item.options as AskUserOption[]) : undefined,
      multiSelect: item.multiSelect === true,
    });
  }
  return { questions };
}

/** Render the answer in the questions' own order, so the model reads it as a dialogue. */
function renderAnswer(questions: AskUserQuestion[], answer: AskUserAnswer): string {
  const byId = new Map(answer.answers.map((item) => [item.id, item]));
  const lines = questions.map((question) => {
    const item = byId.get(question.id);
    if (!item) {
      return `${question.question}\n  (skipped)`;
    }
    // A single-select `custom` REPLACES the choice; a multi-select one adds to
    // it. Same encoding either way, so a richer UI later changes nothing here.
    const parts = [...item.selected];
    if (item.custom) {
      parts.push(item.custom);
    }
    return `${question.question}\n  ${parts.length > 0 ? parts.join(", ") : "(skipped)"}`;
  });
  return `The user answered:\n${lines.join("\n")}`;
}

/**
 * Build the single-tool set exposing `opentype__ask_user`.
 *
 * @param broker - shared routing between the agent and the UI transport.
 * @param options - the run to address and the no-answer timeout.
 */
export function createAskUserTool(
  broker: AskUserBroker,
  options: AskUserToolOptions
): ToolSet {
  const openAiTools = [
    {
      type: "function",
      function: {
        name: ASK_USER_TOOL_NAME,
        description:
          "Ask the user one or more questions and wait for their answer. Use this when the " +
          "spoken task is genuinely ambiguous -- several files match, a name is unclear, or a " +
          "choice is the user's to make -- instead of guessing. Do not use it for anything you " +
          "can find out yourself with the other tools.",
        parameters: {
          type: "object",
          properties: {
            questions: {
              type: "array",
              description: "The questions to ask, presented together.",
              items: {
                type: "object",
                properties: {
                  id: { type: "string", description: "Stable id echoed back with the answer." },
                  question: { type: "string", description: "The question to show the user." },
                  detail: { type: "string", description: "Optional supporting context." },
                  options: {
                    type: "array",
                    description: "Optional choices to offer.",
                    items: {
                      type: "object",
                      properties: {
                        label: { type: "string" },
                        description: { type: "string" },
                      },
                      required: ["label"],
                    },
                  },
                  multiSelect: { type: "boolean", description: "Allow more than one choice." },
                },
                required: ["id", "question"],
              },
            },
          },
          required: ["questions"],
        },
      },
    },
  ];

  async function callTool(
    _name: string,
    args: unknown,
    signal?: AbortSignal
  ): Promise<{ content: string }> {
    const parsed = parseQuestions(args);
    if ("error" in parsed) {
      return { content: `Error: ${parsed.error}` };
    }

    const { runId, timeoutMs } = options;
    if (!runId) {
      // dsh's "only a live runtime root may ask", in this product's terms: a
      // run with no id has no surface polling for it, so waiting could only
      // ever time out. Refusing immediately is the honest answer and keeps a
      // headless call from stalling the whole sidecar.
      return {
        content:
          "Error: there is no way to ask the user right now (no interactive run). " +
          "Continue without asking, or state the ambiguity in your final answer.",
      };
    }

    const { promise, settle } = broker.wait(runId, parsed.questions);
    const timer = setTimeout(settle, timeoutMs);
    const onAbort = (): void => settle();
    signal?.addEventListener("abort", onAbort, { once: true });
    if (signal?.aborted) {
      settle();
    }

    let answer: AskUserAnswer | undefined;
    try {
      answer = await promise;
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
    }

    if (!answer) {
      return {
        content: signal?.aborted
          ? "The question was cancelled because the run was stopped."
          : "No answer came back in time. Continue without it, or say what you still need.",
      };
    }
    return { content: renderAnswer(parsed.questions, answer) };
  }

  return { openAiTools, callTool };
}
