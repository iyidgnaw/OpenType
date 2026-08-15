import type { Route } from "../router";
import type { ConversationKind } from "./conversations";
import { ConversationStore } from "./conversations";

const VALID_KINDS: ConversationKind[] = ["ask", "agent"];

function isConversationKind(value: string | null): value is ConversationKind {
  return value !== null && (VALID_KINDS as string[]).includes(value);
}

/**
 * Parses the trailing `:id` segment off a `/conversations/:id` request.
 * Returns `null` for anything that isn't an integer (no id at all, or a
 * non-numeric one) so a malformed id never reaches `ConversationStore` --
 * shared by `GET` and `DELETE` since both need exactly this same check
 * before touching the store.
 */
function parseConversationId(req: Request): number | null {
  const pathname = new URL(req.url).pathname;
  const idSegment = pathname.slice(pathname.lastIndexOf("/") + 1);
  const id = Number(idSegment);
  return Number.isInteger(id) ? id : null;
}

/**
 * Routes over `ConversationStore`, backing the macOS client's Q&A and Agent
 * tabs (`GET /conversations?kind=ask|agent` for the list, most-recent first;
 * `GET /conversations/:id` for a single thread with its full message
 * history; `DELETE /conversations/:id` to remove one). Conversations and
 * messages are otherwise written only as a side effect of `POST
 * /oneshot/ask` / `POST /agent/run` (`oneshot/routes.ts`, `agent/routes.ts`)
 * -- `DELETE` is the one place this file writes.
 *
 * `DELETE` only ever touches the `conversations`/`conversation_messages`
 * tables (see `ConversationStore.deleteConversation`). It deliberately does
 * NOT touch the episodic events those turns produced or the append-only
 * audit trail (`ImmutableAuditStore` on the Swift side) -- both are
 * documented as unaffected by history resets, and quietly rewriting either
 * from a UI delete here would break that stated property. If a
 * conversation's episodic events should also be prunable, that is a
 * separate, deliberate decision to make later, not a side effect of this
 * route.
 */
export function buildConversationRoutes(conversations: ConversationStore): Route[] {
  return [
    {
      method: "GET",
      path: "/conversations",
      handler: (req) => {
        const kind = new URL(req.url).searchParams.get("kind");
        if (!isConversationKind(kind)) {
          return Response.json(
            { error: "invalid_kind", detail: "kind must be 'ask' or 'agent'" },
            { status: 400 }
          );
        }
        return Response.json({ conversations: conversations.listConversations(kind) });
      },
    },
    {
      method: "GET",
      path: "/conversations/:id",
      handler: (req) => {
        const id = parseConversationId(req);
        if (id === null) {
          return Response.json({ error: "invalid_id" }, { status: 400 });
        }
        const conversation = conversations.getConversation(id);
        if (!conversation) {
          return Response.json({ error: "not_found" }, { status: 404 });
        }
        return Response.json({ conversation });
      },
    },
    {
      method: "DELETE",
      path: "/conversations/:id",
      handler: (req) => {
        const id = parseConversationId(req);
        if (id === null) {
          return Response.json({ error: "invalid_id" }, { status: 400 });
        }
        // Same "unknown id is a 404, not a silent success" contract as
        // `GET /conversations/:id` right above -- deleting is a panel editing
        // action (the same spirit as `/memory/terms/:id`'s DELETE), and a
        // caller that thinks it just deleted something already-gone should
        // see that mismatch rather than get an idempotent 2xx.
        if (!conversations.deleteConversation(id)) {
          return Response.json({ error: "not_found" }, { status: 404 });
        }
        return Response.json({ deleted: true });
      },
    },
  ];
}
