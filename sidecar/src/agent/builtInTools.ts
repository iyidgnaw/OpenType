import type { MemoryStore } from "../memory/MemoryStore";
import { runConsolidation, upsertEntityTerm, type CallLLM } from "../memory/consolidator";
import type { ToolSet } from "./toolSets";

/**
 * Product-owned tools that are always available in the Agent runtime,
 * regardless of what (if any) MCP servers are configured -- a different
 * category from `agent/mcpClient.ts`'s user-configured, external,
 * protocol-mediated tools. These are plain TypeScript functions with direct
 * access to the local `MemoryStore`. Namespaced with an `opentype__` prefix
 * for the same collision-avoidance reason `mcpClient.ts` namespaces
 * `serverName__toolName`.
 *
 * This is meant as a permanent extension point: adding a third built-in tool
 * later means adding another case to `callTool` and another entry in
 * `openAiTools`, not restructuring anything here.
 */
export type BuiltInToolSet = ToolSet;

export interface BuiltInToolsDeps {
  store: MemoryStore;
  /** Used only by `consolidate_memory_now` to drive `runConsolidation`. */
  callLLM: CallLLM;
}

const REMEMBER_FACT_TOOL_NAME = "opentype__remember_fact";
const CONSOLIDATE_MEMORY_NOW_TOOL_NAME = "opentype__consolidate_memory_now";

interface RememberFactArgs {
  category?: unknown;
  canonicalTerm?: unknown;
  aliases?: unknown;
  content?: unknown;
}

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.filter((item): item is string => typeof item === "string");
}

/**
 * Handles a direct, explicit owner instruction to remember something. Unlike
 * the dreaming pass's candidates, this is never run through `passesGate` --
 * an explicit "记住..."/"remember..." request is full trust, written
 * immediately. `category: "term"` writes straight into `entity_terms` at
 * confidence 1.0 via the same `upsertEntityTerm` merge logic
 * `runConsolidation` uses, so a term remembered this way merges cleanly with
 * (rather than duplicating) one the dreaming pass already proposed, and vice
 * versa. `category: "profile"` writes free text into `owner_facts`, which
 * has no merge/dedupe concept -- it's just appended.
 */
function handleRememberFact(store: MemoryStore, rawArgs: unknown): { content: string } {
  const args = (rawArgs ?? {}) as RememberFactArgs;

  if (args.category === "term") {
    if (typeof args.canonicalTerm !== "string" || args.canonicalTerm.trim().length === 0) {
      return {
        content:
          "Error: remember_fact with category \"term\" requires a non-empty canonicalTerm.",
      };
    }
    const aliases = asStringArray(args.aliases);
    const existingTerms = store.allTerms();
    const { term, merged } = upsertEntityTerm(store, existingTerms, {
      canonicalTerm: args.canonicalTerm,
      aliases,
      category: "term",
      confidence: 1.0,
      sourceEventIds: [],
      // The tool runs inside the agent loop, where content can originate from
      // untrusted context, so a term recorded here is NOT owner-confirmed
      // (P1-12). It stays usable for correction but is never treated as an
      // owner-authored term for prompt injection.
      origin: "untrusted",
    });
    const aliasSummary = term.aliases.length > 0 ? term.aliases.join(", ") : "none";
    return {
      content: merged
        ? `Updated the existing term "${term.canonicalTerm}" (aliases: ${aliasSummary}).`
        : `Remembered term "${term.canonicalTerm}" (aliases: ${aliasSummary}).`,
    };
  }

  if (args.category === "profile") {
    if (typeof args.content !== "string" || args.content.trim().length === 0) {
      return {
        content: "Error: remember_fact with category \"profile\" requires non-empty content.",
      };
    }
    // Recorded as "untrusted" for the same reason as the term path above: a
    // fact learned via the agent/context flow is not owner-confirmed and must
    // not be injected into prompt context (P1-12).
    store.recordOwnerFact(args.content, "untrusted");
    return { content: `Remembered: ${args.content}` };
  }

  return {
    content: 'Error: remember_fact requires category to be "term" or "profile".',
  };
}

/**
 * Runs consolidation ("dreaming") immediately, bypassing `shouldConsolidate`'s
 * time/count gate -- that gate exists for the automatic app-lifecycle
 * trigger, but a manual/explicit "整理一下"/"review now" request should
 * always run. Builds its return summary from the same human-readable
 * `summary` field `runConsolidation` already writes to
 * `memory_consolidation_runs`, rather than inventing a second format.
 */
async function handleConsolidateNow(
  store: MemoryStore,
  callLLM: CallLLM
): Promise<{ content: string }> {
  const result = await runConsolidation(store, callLLM);

  if (result.aborted || result.ranRunId === null) {
    return {
      content: `Consolidation did not complete (${result.reason ?? "unknown reason"}); no changes were made.`,
    };
  }

  const run = store.listConsolidationRuns().find((r) => r.id === result.ranRunId);
  const detail = run?.summary ?? `${result.candidatesAccepted} of ${result.candidatesProposed} candidate(s) accepted`;

  return {
    content:
      `Consolidation complete: considered ${result.eventsConsidered} event(s), ` +
      `proposed ${result.candidatesProposed}, accepted ${result.candidatesAccepted}. ${detail}`,
  };
}

export function createBuiltInTools(deps: BuiltInToolsDeps): BuiltInToolSet {
  const openAiTools: unknown[] = [
    {
      type: "function",
      function: {
        name: REMEMBER_FACT_TOOL_NAME,
        description:
          "Remember something the owner explicitly told you to remember. Use category \"term\" for a " +
          "name/alias correction (e.g. \"when I say PayPal I mean the company PayPal\" -> canonicalTerm " +
          "\"PayPal\", aliases [\"paypal\"]). Use category \"profile\" for a free-text fact about the owner " +
          "(e.g. their name or a stated preference) -> content is that fact in plain words. Use it when the " +
          "owner directly asks you to remember something; you do not need to ask for confirmation first.",
        parameters: {
          type: "object",
          properties: {
            category: {
              type: "string",
              enum: ["term", "profile"],
              description: "\"term\" for a name/alias correction, \"profile\" for a free-text fact about the owner.",
            },
            canonicalTerm: {
              type: "string",
              description: "Required when category is \"term\": the canonical spelling/name to remember.",
            },
            aliases: {
              type: "array",
              items: { type: "string" },
              description: "Alternate spellings, mishearings, or names that should map to canonicalTerm.",
            },
            content: {
              type: "string",
              description:
                "Required when category is \"profile\": the fact to remember about the owner, in plain text " +
                "(e.g. \"The owner's name is Diyi.\").",
            },
          },
          required: ["category"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: CONSOLIDATE_MEMORY_NOW_TOOL_NAME,
        description:
          "Run memory consolidation (\"dreaming\") immediately: review recent dictation history and " +
          "propose/accept new entity terms, bypassing the normal automatic time/event-count schedule. Call " +
          "this when the owner explicitly asks you to review, organize, or consolidate recent history right " +
          "now (e.g. \"整理一下\", \"review what you've learned\").",
        parameters: { type: "object", properties: {} },
      },
    },
  ];

  async function callTool(name: string, args: unknown): Promise<{ content: string }> {
    switch (name) {
      case REMEMBER_FACT_TOOL_NAME:
        return handleRememberFact(deps.store, args);
      case CONSOLIDATE_MEMORY_NOW_TOOL_NAME:
        return handleConsolidateNow(deps.store, deps.callLLM);
      default:
        throw new Error(`Unknown built-in tool: ${name}`);
    }
  }

  return { openAiTools, callTool };
}
