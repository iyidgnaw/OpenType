import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { openDatabase, SCHEMA_VERSION } from "../../src/memory/db";

/**
 * Pipeline B (docs/superpowers/specs/2026-08-28-skill-agent-ui-and-step-log-persistence.md
 * §2, decision D0): `conversation_messages` gains a nullable `steps` column,
 * and -- because D0 explicitly forbids a real migration -- a
 * *conversations-scoped* schema version is introduced so that opening a
 * database file written by the OLD code (no `steps` column, no trace of
 * whatever tracks this new version) drops and rebuilds ONLY `conversations` +
 * `conversation_messages`, exactly once, leaving every other table's rows
 * untouched. A database already at the current conversations schema must NOT
 * be rebuilt again on a later open (no rebuild-on-every-boot).
 *
 * This suite deliberately does NOT assume any particular *internal*
 * representation for that new version tracker (a new column bolted onto the
 * existing singleton `schema_meta` row, a second row keyed by scope, or an
 * entirely separate table) -- only the externally observable behavior D0
 * asks for. That is also a hard constraint, not just caution: the existing
 * `schema_meta.version` column already gates `episodic_events` (see
 * `applySchema`'s doc comment in `src/memory/db.ts`), and
 * `test/memory/db.test.ts`'s "applying the schema against an older stored
 * version drops and rebuilds episodic_events, leaving ... conversations,
 * conversation_messages ... untouched" test PINS that lowering that
 * existing column's value must NOT, by itself, rebuild conversations. So
 * whatever tracks the new conversations-scoped version has to be
 * independent of that column's value -- these tests only pin behavior, never
 * a column/table name, so they hold regardless of which independent
 * mechanism stage 3 picks.
 */

function tempDbPath(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "opentype-conversations-schema-"));
  return path.join(dir, "memory.sqlite");
}

/**
 * Builds a raw sqlite file shaped exactly like the schema `src/memory/db.ts`
 * produces *before* this batch: `conversation_messages` has no `steps`
 * column, and there is no trace of whatever new version-tracking mechanism
 * this batch introduces. Deliberately hand-rolled SQL (a frozen snapshot of
 * the old shape) rather than anything imported from `db.ts` -- once this
 * batch lands, `db.ts`'s own `openDatabase`/`applySchema` produce the NEW
 * shape, so they can no longer be used to manufacture an "old" file for this
 * test to open.
 *
 * The existing episodic-events `schema_meta.version` is stamped to the
 * CURRENT `SCHEMA_VERSION` on purpose, so the pre-existing episodic_events
 * versioning mechanism sees "already current" and does not also rebuild
 * episodic_events -- keeping this test isolated to the NEW conversations
 * mismatch only, not conflated with the already-covered episodic one.
 */
function seedOldConversationsSchema(dbPath: string): void {
  const db = new Database(dbPath, { create: true });

  db.exec(`
    CREATE TABLE schema_meta (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      version INTEGER NOT NULL
    );
  `);
  db.run("INSERT INTO schema_meta (id, version) VALUES (1, ?)", [SCHEMA_VERSION]);

  db.exec(`
    CREATE TABLE episodic_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      createdAt INTEGER NOT NULL,
      mode TEXT NOT NULL,
      rawTranscript TEXT NOT NULL,
      correctedTranscript TEXT NOT NULL,
      effectiveInput TEXT,
      selectedContext TEXT,
      result TEXT,
      applicationName TEXT NOT NULL,
      origin TEXT NOT NULL,
      consolidatedAt INTEGER,
      conversationId INTEGER
    );
  `);

  db.exec(`
    CREATE TABLE entity_terms (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      canonicalTerm TEXT NOT NULL,
      aliases TEXT NOT NULL DEFAULT '[]',
      category TEXT NOT NULL,
      confidence REAL NOT NULL,
      origin TEXT NOT NULL,
      sourceEventIds TEXT NOT NULL DEFAULT '[]',
      createdAt INTEGER NOT NULL,
      updatedAt INTEGER NOT NULL,
      supersedes INTEGER REFERENCES entity_terms(id)
    );
  `);

  // The OLD shape -- no `steps` column.
  db.exec(`
    CREATE TABLE conversations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      kind TEXT NOT NULL,
      title TEXT NOT NULL,
      createdAt INTEGER NOT NULL,
      updatedAt INTEGER NOT NULL
    );
  `);
  db.exec(`
    CREATE TABLE conversation_messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      conversationId INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
      role TEXT NOT NULL,
      content TEXT NOT NULL,
      createdAt INTEGER NOT NULL
    );
  `);

  const now = Date.now();
  db.run(
    `INSERT INTO episodic_events
      (createdAt, mode, rawTranscript, correctedTranscript, effectiveInput, selectedContext, result, applicationName, origin)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [now, "transcribe", "raw", "corrected", null, null, null, "TestApp", "owner"]
  );
  db.run(
    `INSERT INTO entity_terms
      (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    ["Diyi Wang", "[]", "person", 0.9, "owner", "[]", now, now]
  );
  db.run(
    `INSERT INTO conversations (kind, title, createdAt, updatedAt) VALUES (?, ?, ?, ?)`,
    ["ask", "an old pre-migration conversation", now, now]
  );
  const conversation = db.query("SELECT id FROM conversations").get() as { id: number };
  db.run(
    `INSERT INTO conversation_messages (conversationId, role, content, createdAt) VALUES (?, ?, ?, ?)`,
    [conversation.id, "user", "an old pre-migration message", now]
  );

  db.close();
}

describe("conversations-scoped schema version (Pipeline B / D0)", () => {
  test("opening a file written with the OLD conversations schema drops and rebuilds ONLY conversations + conversation_messages, leaving every other table's rows byte-for-byte intact", () => {
    const dbPath = tempDbPath();
    seedOldConversationsSchema(dbPath);

    // This is the exact call a real launch makes against an existing file on
    // disk -- SidecarClient/server.ts never call anything lower-level.
    const db = openDatabase(dbPath);

    // The new column must exist post-rebuild.
    const columns = db
      .query("PRAGMA table_info(conversation_messages)")
      .all() as Array<{ name: string }>;
    expect(columns.map((c) => c.name)).toContain("steps");

    // The old rows in the two rebuilt tables must be gone.
    expect(
      (db.query("SELECT COUNT(*) c FROM conversations").get() as { c: number }).c
    ).toBe(0);
    expect(
      (db.query("SELECT COUNT(*) c FROM conversation_messages").get() as { c: number }).c
    ).toBe(0);

    // Every OTHER table -- D0 explicitly says "仅这两张" (only these two) --
    // must survive untouched.
    expect(
      (db.query("SELECT COUNT(*) c FROM episodic_events").get() as { c: number }).c
    ).toBe(1);
    expect(
      (db.query("SELECT COUNT(*) c FROM entity_terms").get() as { c: number }).c
    ).toBe(1);
    const survivingTerm = db.query("SELECT canonicalTerm FROM entity_terms").get() as {
      canonicalTerm: string;
    };
    expect(survivingTerm.canonicalTerm).toBe("Diyi Wang");
  });

  test("re-opening an already-current-schema database does NOT drop conversations/conversation_messages, and a message's steps column survives the reopen (no rebuild-on-every-boot)", () => {
    const dbPath = tempDbPath();

    const first = openDatabase(dbPath);
    const insertResult = first.run(
      `INSERT INTO conversations (kind, title, createdAt, updatedAt) VALUES (?, ?, ?, ?)`,
      ["agent", "keep me across a reopen", Date.now(), Date.now()]
    );
    const conversationId = Number(insertResult.lastInsertRowid);
    const stepsJson = JSON.stringify([{ type: "done", detail: "ok" }]);
    first.run(
      `INSERT INTO conversation_messages (conversationId, role, content, createdAt, steps) VALUES (?, ?, ?, ?, ?)`,
      [conversationId, "assistant", "keep me across a reopen", Date.now(), stepsJson]
    );
    first.close();

    // A later launch against the same file, once its version is already
    // current, must be a no-op for these two tables -- rebuilding on
    // literally every boot would defeat the whole point of versioning it.
    const second = openDatabase(dbPath);

    expect(
      (second.query("SELECT COUNT(*) c FROM conversations").get() as { c: number }).c
    ).toBe(1);
    expect(
      (second.query("SELECT COUNT(*) c FROM conversation_messages").get() as { c: number }).c
    ).toBe(1);

    const survivor = second
      .query("SELECT content, steps FROM conversation_messages WHERE conversationId = ?")
      .get(conversationId) as { content: string; steps: string | null } | null;
    expect(survivor?.content).toBe("keep me across a reopen");
    expect(survivor?.steps).toBe(stepsJson);
  });
});
