import type { Route } from "../router";
import type { ConversationKind } from "./conversations";
import { ConversationStore } from "./conversations";

const VALID_KINDS: ConversationKind[] = ["ask", "agent"];

function isConversationKind(value: string | null): value is ConversationKind {
  return value !== null && (VALID_KINDS as string[]).includes(value);
}

/**
 * Read routes over `ConversationStore`, backing the macOS client's Q&A and
 * Agent tabs (`GET /conversations?kind=ask|agent` for the list, most-recent
 * first; `GET /conversations/:id` for a single thread with its full message
 * history). Both endpoints only read -- conversations/messages are written
 * as a side effect of `POST /oneshot/ask` / `POST /agent/run`
 * (`oneshot/routes.ts`, `agent/routes.ts`), not here.
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
        const pathname = new URL(req.url).pathname;
        const idSegment = pathname.slice(pathname.lastIndexOf("/") + 1);
        const id = Number(idSegment);
        if (!Number.isInteger(id)) {
          return Response.json({ error: "invalid_id" }, { status: 400 });
        }
        const conversation = conversations.getConversation(id);
        if (!conversation) {
          return Response.json({ error: "not_found" }, { status: 404 });
        }
        return Response.json({ conversation });
      },
    },
  ];
}
