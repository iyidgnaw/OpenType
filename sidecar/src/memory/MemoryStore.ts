import type { Database } from "bun:sqlite";

export type EventOrigin = "owner" | "agent" | "untrusted" | "system";
export type EntityCategory = "person" | "project" | "term" | "org";

export interface RecordEpisodicEventInput {
  mode: string;
  rawTranscript: string;
  correctedTranscript: string;
  effectiveInput: string | null;
  selectedContext: string | null;
  result: string | null;
  applicationName: string;
  origin?: EventOrigin;
}

export interface EntityTerm {
  id: number;
  canonicalTerm: string;
  aliases: string[];
  category: EntityCategory;
  confidence: number;
  origin: EventOrigin;
  sourceEventIds: number[];
  createdAt: number;
  updatedAt: number;
  supersedes: number | null;
}

export interface ConsolidationRunSummary {
  id: number;
  ranAt: number;
  eventsConsidered: number;
  candidatesProposed: number;
  candidatesAccepted: number;
  summary: string;
  rolledBackAt: number | null;
}

interface EntityTermRow {
  id: number;
  canonicalTerm: string;
  aliases: string;
  category: EntityCategory;
  confidence: number;
  origin: EventOrigin;
  sourceEventIds: string;
  createdAt: number;
  updatedAt: number;
  supersedes: number | null;
}

function rowToEntityTerm(row: EntityTermRow): EntityTerm {
  return {
    id: row.id,
    canonicalTerm: row.canonicalTerm,
    aliases: JSON.parse(row.aliases) as string[],
    category: row.category,
    confidence: row.confidence,
    origin: row.origin,
    sourceEventIds: JSON.parse(row.sourceEventIds) as number[],
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    supersedes: row.supersedes,
  };
}

/**
 * Wraps a bun:sqlite Database handle over the spec §4.2 schema. This is the
 * only write path into episodic_events, and the read interface A/B1/B2 use
 * for entity lookups. It does not know about "modes" beyond the plain string
 * label the caller passes in, and it does not perform phonetic/similarity
 * matching (that belongs to module A) — only exact substring matching.
 */
export class MemoryStore {
  constructor(public readonly db: Database) {}

  recordEpisodicEvent(input: RecordEpisodicEventInput): number {
    const origin: EventOrigin = input.origin ?? "owner";
    const now = Date.now();
    const result = this.db.run(
      `INSERT INTO episodic_events
        (createdAt, mode, rawTranscript, correctedTranscript, effectiveInput, selectedContext, result, applicationName, origin)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        now,
        input.mode,
        input.rawTranscript,
        input.correctedTranscript,
        input.effectiveInput,
        input.selectedContext,
        input.result,
        input.applicationName,
        origin,
      ]
    );
    return Number(result.lastInsertRowid);
  }

  allTerms(): EntityTerm[] {
    const rows = this.db.query("SELECT * FROM entity_terms").all() as EntityTermRow[];
    return rows.map(rowToEntityTerm);
  }

  search(text: string): EntityTerm[] {
    const needle = text.toLowerCase();
    return this.allTerms().filter((term) => {
      if (term.canonicalTerm.toLowerCase().includes(needle)) {
        return true;
      }
      return term.aliases.some((alias) => alias.toLowerCase().includes(needle));
    });
  }

  unconsolidatedEventCount(): number {
    const row = this.db
      .query("SELECT COUNT(*) as count FROM episodic_events WHERE consolidatedAt IS NULL")
      .get() as { count: number };
    return row.count;
  }

  hoursSinceLastConsolidation(): number | null {
    const row = this.db
      .query(
        "SELECT ranAt FROM memory_consolidation_runs ORDER BY ranAt DESC LIMIT 1"
      )
      .get() as { ranAt: number } | null;
    if (!row) {
      return null;
    }
    return (Date.now() - row.ranAt) / (1000 * 60 * 60);
  }

  /**
   * Human-review surface for the Settings "Memory" panel (design §4.1): a
   * consolidation run log. Deliberately excludes snapshotBeforeJSON — that's
   * large internal rollback state, not meant for display.
   */
  listConsolidationRuns(): ConsolidationRunSummary[] {
    const rows = this.db
      .query(
        `SELECT id, ranAt, eventsConsidered, candidatesProposed, candidatesAccepted, summary, rolledBackAt
         FROM memory_consolidation_runs
         ORDER BY ranAt DESC`
      )
      .all() as ConsolidationRunSummary[];
    return rows;
  }
}
