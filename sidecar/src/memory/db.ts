import { Database } from "bun:sqlite";
import { existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

const SCHEMA_SQL = `
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
  consolidatedAt INTEGER
);

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
`;

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
  db.exec(SCHEMA_SQL);
  return db;
}
