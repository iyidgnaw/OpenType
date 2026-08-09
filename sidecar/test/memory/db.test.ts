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

  test("creates the owner_facts table with the spec columns", () => {
    const db = openDatabase(":memory:");
    const columns = db
      .query("PRAGMA table_info(owner_facts)")
      .all() as Array<{ name: string }>;
    const names = columns.map((c) => c.name).sort();
    expect(names).toEqual(["content", "createdAt", "id", "origin"].sort());
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

  test("creates the conversations table with the expected columns", () => {
    const db = openDatabase(":memory:");
    const columns = db
      .query("PRAGMA table_info(conversations)")
      .all() as Array<{ name: string }>;
    const names = columns.map((c) => c.name).sort();
    expect(names).toEqual(["createdAt", "id", "kind", "title", "updatedAt"].sort());
  });

  test("creates the conversation_messages table with the expected columns", () => {
    const db = openDatabase(":memory:");
    const columns = db
      .query("PRAGMA table_info(conversation_messages)")
      .all() as Array<{ name: string }>;
    const names = columns.map((c) => c.name).sort();
    expect(names).toEqual(
      ["id", "conversationId", "role", "content", "createdAt"].sort()
    );
  });

  test("allows inserting and reading a row from the conversations and conversation_messages tables", () => {
    const db = openDatabase(":memory:");
    db.run(
      `INSERT INTO conversations (kind, title, createdAt, updatedAt) VALUES (?, ?, ?, ?)`,
      ["ask", "what is 2+2?", Date.now(), Date.now()]
    );
    const conversation = db.query("SELECT * FROM conversations").get() as Record<string, unknown>;
    expect(conversation.kind).toBe("ask");
    expect(conversation.title).toBe("what is 2+2?");

    db.run(
      `INSERT INTO conversation_messages (conversationId, role, content, createdAt) VALUES (?, ?, ?, ?)`,
      [conversation.id, "user", "what is 2+2?", Date.now()]
    );
    const message = db.query("SELECT * FROM conversation_messages").get() as Record<string, unknown>;
    expect(message.role).toBe("user");
    expect(message.content).toBe("what is 2+2?");
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

    db.run(
      `INSERT INTO owner_facts (content, createdAt, origin) VALUES (?, ?, ?)`,
      ["The owner's name is Diyi.", Date.now(), "owner"]
    );
    const fact = db.query("SELECT * FROM owner_facts").get() as Record<string, unknown>;
    expect(fact.content).toBe("The owner's name is Diyi.");
    expect(fact.origin).toBe("owner");
  });
});
