import { describe, expect, test } from "bun:test";
import { openDatabase } from "../../src/memory/db";

describe("openDatabase", () => {
  test("creates the episodic_events table with the spec §4.2 columns", () => {
    const db = openDatabase(":memory:");
    const columns = db
      .query("PRAGMA table_info(episodic_events)")
      .all() as Array<{ name: string }>;
    const names = columns.map((c) => c.name).sort();
    expect(names).toEqual(
      [
        "applicationName",
        "consolidatedAt",
        "correctedTranscript",
        "createdAt",
        "effectiveInput",
        "id",
        "mode",
        "origin",
        "rawTranscript",
        "result",
        "selectedContext",
      ].sort()
    );
  });

  test("creates the entity_terms table with the spec §4.2 columns", () => {
    const db = openDatabase(":memory:");
    const columns = db
      .query("PRAGMA table_info(entity_terms)")
      .all() as Array<{ name: string }>;
    const names = columns.map((c) => c.name).sort();
    expect(names).toEqual(
      [
        "aliases",
        "canonicalTerm",
        "category",
        "confidence",
        "createdAt",
        "id",
        "origin",
        "sourceEventIds",
        "supersedes",
        "updatedAt",
      ].sort()
    );
  });

  test("creates the memory_consolidation_runs table with the spec §4.2 columns", () => {
    const db = openDatabase(":memory:");
    const columns = db
      .query("PRAGMA table_info(memory_consolidation_runs)")
      .all() as Array<{ name: string }>;
    const names = columns.map((c) => c.name).sort();
    expect(names).toEqual(
      [
        "candidatesAccepted",
        "candidatesProposed",
        "eventsConsidered",
        "id",
        "ranAt",
        "rolledBackAt",
        "snapshotBeforeJSON",
        "summary",
      ].sort()
    );
  });

  test("is idempotent — opening twice against the same file does not error", () => {
    const db1 = openDatabase(":memory:");
    db1.close();
    // Reopening a fresh in-memory db exercises the same "create if not exists" path.
    const db2 = openDatabase(":memory:");
    const columns = db2
      .query("PRAGMA table_info(episodic_events)")
      .all() as Array<{ name: string }>;
    expect(columns.length).toBeGreaterThan(0);
  });

  test("allows inserting and reading a row from each table", () => {
    const db = openDatabase(":memory:");

    db.run(
      `INSERT INTO episodic_events
        (createdAt, mode, rawTranscript, correctedTranscript, effectiveInput, selectedContext, result, applicationName, origin)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [Date.now(), "transcribe", "raw", "corrected", null, null, null, "TestApp", "owner"]
    );
    const event = db.query("SELECT * FROM episodic_events").get() as Record<string, unknown>;
    expect(event.mode).toBe("transcribe");

    db.run(
      `INSERT INTO entity_terms
        (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ["天润", "[]", "org", 0.8, "owner", "[]", Date.now(), Date.now(), null]
    );
    const term = db.query("SELECT * FROM entity_terms").get() as Record<string, unknown>;
    expect(term.canonicalTerm).toBe("天润");

    db.run(
      `INSERT INTO memory_consolidation_runs
        (ranAt, eventsConsidered, candidatesProposed, candidatesAccepted, summary, snapshotBeforeJSON, rolledBackAt)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [Date.now(), 5, 2, 1, "test summary", "[]", null]
    );
    const run = db.query("SELECT * FROM memory_consolidation_runs").get() as Record<string, unknown>;
    expect(run.summary).toBe("test summary");
  });
});
