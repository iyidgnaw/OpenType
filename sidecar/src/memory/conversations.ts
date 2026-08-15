import type { Database } from "bun:sqlite";

export type ConversationKind = "ask" | "agent";
export type ConversationMessageRole = "user" | "assistant";

export interface Conversation {
  id: number;
  kind: ConversationKind;
  title: string;
  createdAt: number;
  updatedAt: number;
  /**
   * The most recent message in the thread, whoever wrote it.
   *
   * The list row's second line. Without it the list shows only what the user
   * asked and never what came back, so every row reads as an unanswered
   * question — which is exactly wrong for a list whose whole job is telling
   * you which threads got somewhere.
   */
  preview?: string;
}

export interface ConversationMessage {
  id: number;
  conversationId: number;
  role: ConversationMessageRole;
  content: string;
  createdAt: number;
}

export interface ConversationWithMessages extends Conversation {
  messages: ConversationMessage[];
}

interface ConversationRow {
  id: number;
  kind: ConversationKind;
  title: string;
  createdAt: number;
  updatedAt: number;
  /** Only selected by `listConversations`; absent elsewhere. */
  preview?: string;
}

interface ConversationMessageRow {
  id: number;
  conversationId: number;
  role: ConversationMessageRole;
  content: string;
  createdAt: number;
}

const TITLE_MAX_LENGTH = 40;

/** Auto-title from the first user message: the first ~40 characters,
 * ellipsized with "…" if the message is longer than that. */
function titleFrom(seedMessage: string): string {
  const trimmed = seedMessage.trim();
  if (trimmed.length <= TITLE_MAX_LENGTH) {
    return trimmed;
  }
  return `${trimmed.slice(0, TITLE_MAX_LENGTH)}…`;
}

/**
 * Wraps a bun:sqlite Database handle over the `conversations` /
 * `conversation_messages` tables (schema in `memory/db.ts`) -- multi-turn
 * conversation history for Ask and Agent mode, shared with `MemoryStore`'s
 * underlying `Database` rather than a separate connection. Same
 * dependency-injection spirit as `MemoryStore`: a thin, directly-testable
 * wrapper the route handlers depend on rather than raw SQL.
 */
export class ConversationStore {
  constructor(public readonly db: Database) {}

  /**
   * Creates a new conversation of `kind`, titled from `seedMessage` (usually
   * the first user message about to be appended). Does not itself insert a
   * message -- callers append the seed message (and every later turn) via
   * `appendMessage`.
   */
  createConversation(kind: ConversationKind, seedMessage: string): number {
    const now = Date.now();
    const result = this.db.run(
      `INSERT INTO conversations (kind, title, createdAt, updatedAt) VALUES (?, ?, ?, ?)`,
      [kind, titleFrom(seedMessage), now, now]
    );
    return Number(result.lastInsertRowid);
  }

  /**
   * Appends a message to `conversationId` and bumps the conversation's
   * `updatedAt` so `listConversations` reflects the new activity.
   */
  appendMessage(
    conversationId: number,
    role: ConversationMessageRole,
    content: string
  ): number {
    const now = Date.now();
    const result = this.db.run(
      `INSERT INTO conversation_messages (conversationId, role, content, createdAt) VALUES (?, ?, ?, ?)`,
      [conversationId, role, content, now]
    );
    this.db.run(`UPDATE conversations SET updatedAt = ? WHERE id = ?`, [now, conversationId]);
    return Number(result.lastInsertRowid);
  }

  /** Lists conversations of `kind`, most-recently-updated first. */
  listConversations(kind: ConversationKind): Conversation[] {
    const rows = this.db
      .query(
        // The newest message per conversation, by a correlated subquery rather
        // than a join + GROUP BY: the list is short, this reads as what it
        // means, and it keeps the ORDER BY on the outer rows where it belongs.
        `SELECT c.id, c.kind, c.title, c.createdAt, c.updatedAt,
                (SELECT m.content FROM conversation_messages m
                  WHERE m.conversationId = c.id
                  ORDER BY m.createdAt DESC, m.id DESC LIMIT 1) AS preview
           FROM conversations c
          WHERE c.kind = ?
          ORDER BY c.updatedAt DESC, c.id DESC`
      )
      .all(kind) as ConversationRow[];
    return rows.map((row) => ({
      ...row,
      // Collapsed and clipped here rather than in the view: a preview is one
      // line by definition, and a markdown answer's newlines would otherwise
      // arrive as a row three times its height.
      preview: row.preview
        ? row.preview.replace(/\s+/gu, " ").trim().slice(0, 140)
        : undefined,
    }));
  }

  /** Fetches one conversation with its full, chronologically-ordered message
   * list, or `null` if `id` doesn't exist. */
  getConversation(id: number): ConversationWithMessages | null {
    const conversation = this.db
      .query(`SELECT id, kind, title, createdAt, updatedAt FROM conversations WHERE id = ?`)
      .get(id) as ConversationRow | null;
    if (!conversation) {
      return null;
    }

    const messages = this.db
      .query(
        `SELECT id, conversationId, role, content, createdAt FROM conversation_messages
         WHERE conversationId = ?
         ORDER BY id ASC`
      )
      .all(id) as ConversationMessageRow[];

    return { ...conversation, messages };
  }

  /**
   * Deletes a conversation and every message in it, atomically. Returns
   * `true` if a conversation was actually removed, `false` if `id` didn't
   * exist (the route maps that to 404, matching `getConversation`'s "no such
   * row" contract rather than treating a no-op delete as success).
   *
   * The two DELETEs run in one `db.transaction` rather than leaning on the
   * schema's `conversation_messages.conversationId ... ON DELETE CASCADE`:
   * bun:sqlite ships with the `foreign_keys` pragma off by default, so that
   * constraint is not actually enforced and a single `DELETE FROM
   * conversations` would leave the messages behind as invisible-but-still-
   * on-disk orphans -- exactly what deleting is supposed to prevent. Deleting
   * messages before the conversation (rather than after) also means a crash
   * mid-transaction can never leave a message pointing at an
   * already-gone conversation, though the transaction wrapper makes that
   * ordering belt-and-suspenders rather than load-bearing.
   */
  deleteConversation(id: number): boolean {
    const run = this.db.transaction((): boolean => {
      this.db.run(`DELETE FROM conversation_messages WHERE conversationId = ?`, [id]);
      const result = this.db.run(`DELETE FROM conversations WHERE id = ?`, [id]);
      return result.changes > 0;
    });
    return run();
  }
}
