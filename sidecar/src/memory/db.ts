import { Database } from "bun:sqlite";
import { existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

/**
 * Bumped whenever `episodic_events`'s shape changes. `applySchema` compares
 * this against the version stored in `schema_meta` and, when they differ,
 * drops and recreates *only* `episodic_events` -- nothing else.
 *
 * This product resets rather than migrates: there is no column-by-column
 * ALTER path, on the deliberate bet that `episodic_events` is the one table
 * a user never looks at (only the consolidator reads it -- see
 * `memory/startupConsolidation.ts`), so silently clearing it on a schema
 * change is an acceptable cost. `entity_terms`, `owner_facts`,
 * `conversations`/`conversation_messages` and `memory_consolidation_runs`
 * are all visible assets (the dictionary, owner facts, chat history, the
 * consolidation run log) a user would notice losing, so they are never
 * touched here regardless of version.
 *
 * Known cost of this tradeoff: any episodic events recorded since the last
 * consolidation pass are lost on a version bump, not carried forward. That
 * is accepted rather than building a migration for a table with no user
 * surface.
 */
export const SCHEMA_VERSION = 2;

const SCHEMA_META_SQL = `
CREATE TABLE IF NOT EXISTS schema_meta (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  version INTEGER NOT NULL
);
`;

// Isolated from the rest of the schema so applySchema can DROP + recreate
// just this table on a version bump (see SCHEMA_VERSION's doc comment)
// without touching anything else.
const EPISODIC_EVENTS_SQL = `
CREATE TABLE IF NOT EXISTS episodic_events (
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

CREATE INDEX IF NOT EXISTS episodic_events_created_at
ON episodic_events(createdAt DESC);
`;

const REST_OF_SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS entity_terms (
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

CREATE TABLE IF NOT EXISTS memory_consolidation_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ranAt INTEGER NOT NULL,
  eventsConsidered INTEGER NOT NULL,
  candidatesProposed INTEGER NOT NULL,
  candidatesAccepted INTEGER NOT NULL,
  summary TEXT NOT NULL,
  snapshotBeforeJSON TEXT NOT NULL,
  rolledBackAt INTEGER
);

CREATE TABLE IF NOT EXISTS owner_facts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  content TEXT NOT NULL,
  createdAt INTEGER NOT NULL,
  origin TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS conversations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,
  title TEXT NOT NULL,
  createdAt INTEGER NOT NULL,
  updatedAt INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS conversations_kind_updated_at
ON conversations(kind, updatedAt DESC);

-- NOTE: the ON DELETE CASCADE below is documentation, not behaviour. bun:sqlite
-- opens connections with \`PRAGMA foreign_keys = 0\`, and nothing here turns it
-- on, so deleting a conversation does NOT remove its messages -- they are left
-- behind as rows no query reaches and nothing cleans up. Verified directly:
-- \`PRAGMA foreign_keys\` reads 0, and a raw DELETE against \`conversations\`
-- leaves the message rows in place.
--
-- So any code that deletes a row referenced here must delete the children
-- itself, in one transaction. \`ConversationStore.deleteConversation\` is the
-- one such caller today and does exactly that. Turning the pragma on would be
-- the tidier fix, but it makes every existing insert subject to a constraint
-- that has never been enforced on live data -- a separate change with its own
-- migration question, not a one-liner.
CREATE TABLE IF NOT EXISTS conversation_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  conversationId INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  createdAt INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS conversation_messages_conversation_id
ON conversation_messages(conversationId, id);
`;

/**
 * Ensures the spec §4.2 tables exist against `db`, then reconciles
 * `episodic_events` against `SCHEMA_VERSION`:
 *
 * - The schema (including `schema_meta` itself) is always created if
 *   missing -- this also covers a brand new database, which has no stored
 *   version yet.
 * - If the stored version already equals `SCHEMA_VERSION`, this is a no-op:
 *   `episodic_events` rows are left exactly as they are.
 * - Otherwise (no stored version, or an older one), `episodic_events` is
 *   dropped and recreated empty, and the stored version is set to
 *   `SCHEMA_VERSION`. Every other table keeps its rows -- see
 *   `SCHEMA_VERSION`'s doc comment for why only this table resets.
 */
export function applySchema(db: Database): void {
  db.exec(SCHEMA_META_SQL);
  db.exec(EPISODIC_EVENTS_SQL);
  db.exec(REST_OF_SCHEMA_SQL);

  db.run("INSERT OR IGNORE INTO schema_meta (id, version) VALUES (1, 0)");
  const row = db.query("SELECT version FROM schema_meta WHERE id = 1").get() as
    | { version: number }
    | undefined;
  const storedVersion = row?.version ?? 0;

  if (storedVersion === SCHEMA_VERSION) {
    return;
  }

  db.exec("DROP TABLE IF EXISTS episodic_events");
  db.exec(EPISODIC_EVENTS_SQL);
  db.run("UPDATE schema_meta SET version = ? WHERE id = 1", [SCHEMA_VERSION]);
}

/**
 * Opens (creating if necessary) the bun:sqlite database at `path` and ensures
 * the spec §4.2 tables exist. Pass ":memory:" in tests to avoid touching disk.
 */
export function openDatabase(path: string): Database {
  if (path !== ":memory:") {
    const dir = dirname(path);
    if (dir && dir !== "." && !existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }
  }

  const db = new Database(path, { create: true });
  applySchema(db);
  return db;
}
