import type { Database } from "bun:sqlite";

export type ConversationKind = "ask" | "agent";
export type ConversationMessageRole = "user" | "assistant";

export interface Conversation {
  id: number;
  kind: ConversationKind;
  title: string;
  createdAt: number;
  updatedAt: number;
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
        `SELECT id, kind, title, createdAt, updatedAt FROM conversations
         WHERE kind = ?
         ORDER BY updatedAt DESC, id DESC`
      )
      .all(kind) as ConversationRow[];
    return rows;
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
}
