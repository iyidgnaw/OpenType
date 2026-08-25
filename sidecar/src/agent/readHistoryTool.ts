import type { MemoryStore, EpisodicEventRow } from "../memory/MemoryStore";
import type { ConversationStore } from "../memory/conversations";
import { RECENT_ACTIVITY_LIMIT } from "../memory/recentActivity";

/**
 * `opentype__read_history` (Task 11,
 * docs/superpowers/plans/2026-08-25-unified-memory-and-recent-context.md,
 * spec §3.6): the other half of `buildRecentActivityContext`
 * (`../memory/recentActivity.ts`). That block clips every field to
 * `RECENT_ACTIVITY_FIELD_MAX` characters and shows only an `eventId` /
 * `conversationId` per entry -- this tool is how the Agent turns one of
 * those clipped ids back into the full, untruncated record. Agent-only:
 * registered in `coreTools.ts`, which Ask never sees (Ask's toolset is
 * built from `ASK_TOOL_NAMES`, an allowlist of exactly the two web tools --
 * see `src/oneshot/routes.ts` -- so a tool simply never added to that list
 * is absent from Ask for free, no exclusion logic needed here).
 *
 * `eventId`/`conversationId`/`limit` are deliberately named to match the
 * keys `buildRecentActivityContext` emits verbatim: the model can copy an
 * id straight out of the injected "Recent activity" block into a tool call
 * with no translation step. A rename on either side breaks that link.
 *
 * **The `limit` clamp is a security boundary, not a nicety.** SQLite reads
 * a negative `LIMIT` as "unbounded", so an un-clamped `{ limit: -1 }` would
 * read the user's entire `episodic_events` table -- every dictation, ask,
 * and agent turn ever recorded -- back into the agent's context in one
 * call. Any `limit` that is not a positive integer (omitted, zero,
 * negative, or non-integer) falls back to `RECENT_ACTIVITY_LIMIT` (kept in
 * sync with the injected block's own default rather than a second literal);
 * anything above `MAX_LIMIT` clamps down to it instead of passing through.
 *
 * Every branch returns a plain, readable string and never throws --
 * including "no such id" and "memory not wired up". A thrown tool error
 * turns a cheap probe (the model guessing at an id, or running before
 * memory is configured) into a failed step the model has to recover from;
 * a plain sentence lets it just read the answer and move on.
 */
export const READ_HISTORY_TOOL_NAME = "opentype__read_history";

/** Ceiling on the "neither id given" branch's `limit`, independent of the default. */
const MAX_LIMIT = 50;

export const READ_HISTORY_TOOL_SCHEMA = {
  type: "function",
  function: {
    name: READ_HISTORY_TOOL_NAME,
    description:
      "Read the user's own past turns in full. Pass eventId (from the Recent activity block) " +
      "for one turn's complete, untruncated record including which app it happened in; pass " +
      "conversationId for a whole ask/agent thread; pass neither to list the most recent turns " +
      "in full. Read-only.",
    parameters: {
      type: "object",
      properties: {
        eventId: { type: "number", description: "One turn's id, as shown in Recent activity." },
        conversationId: { type: "number", description: "A thread's id, as shown in Recent activity." },
        limit: {
          type: "number",
          description: "How many recent turns to list when no id is given; defaults to 10.",
        },
      },
    },
  },
};

export interface ReadHistoryArgs {
  eventId?: number;
  conversationId?: number;
  limit?: number;
}

export interface ReadHistoryDeps {
  store?: MemoryStore;
  conversations?: ConversationStore;
}

function clampLimit(raw: unknown): number {
  if (typeof raw !== "number" || !Number.isInteger(raw) || raw <= 0) {
    return RECENT_ACTIVITY_LIMIT;
  }
  return Math.min(raw, MAX_LIMIT);
}

/** Renders one event's full, untruncated record. */
function formatEvent(row: EpisodicEventRow): string {
  const lines = [
    `Event #${row.id} (${row.mode}, app: ${row.applicationName})`,
    `Input: ${row.correctedTranscript}`,
  ];
  if (row.selectedContext != null && row.selectedContext.trim() !== "") {
    lines.push(`Selected context: ${row.selectedContext}`);
  }
  if (row.result != null && row.result.trim() !== "") {
    lines.push(`Result: ${row.result}`);
  }
  if (row.conversationId != null) {
    lines.push(`Conversation: ${row.conversationId}`);
  }
  return lines.join("\n");
}

/** Handler for `opentype__read_history`. See this file's doc comment for the full contract. */
export async function handleReadHistory(
  args: ReadHistoryArgs,
  deps: ReadHistoryDeps
): Promise<string> {
  const { store, conversations } = deps;

  if (typeof args.eventId === "number") {
    if (!store) {
      return `Can't read event ${args.eventId}: history is not available right now.`;
    }
    const row = store.getEventById(args.eventId);
    if (!row) {
      return `No history entry with eventId ${args.eventId}.`;
    }
    return formatEvent(row);
  }

  if (typeof args.conversationId === "number") {
    if (!conversations) {
      return `Can't read conversation ${args.conversationId}: history is not available right now.`;
    }
    const conversation = conversations.getConversation(args.conversationId);
    if (!conversation) {
      return `No conversation with conversationId ${args.conversationId}.`;
    }
    if (conversation.messages.length === 0) {
      return `Conversation ${args.conversationId} ("${conversation.title}") has no messages yet.`;
    }
    return conversation.messages
      .map((m) => `${m.role}: ${m.content}`)
      .join("\n\n");
  }

  if (!store) {
    return "Can't list recent history: history is not available right now.";
  }
  const limit = clampLimit(args.limit);
  const rows = store.recentEvents(limit);
  if (rows.length === 0) {
    return "No history yet.";
  }
  return rows.map(formatEvent).join("\n\n");
}
