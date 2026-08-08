import type { EntityCategory, EntityTerm, EventOrigin, MemoryStore } from "./MemoryStore";

/**
 * Injected dependency ("ProviderCalling protocol" in the design spec) so this
 * module never imports the DeepSeek client directly and stays testable with a
 * fake in unit tests.
 */
export type CallLLM = (prompt: string) => Promise<string>;

export interface ConsolidationResult {
  /** null when the run was aborted before anything was written. */
  ranRunId: number | null;
  eventsConsidered: number;
  candidatesProposed: number;
  candidatesAccepted: number;
  aborted: boolean;
  reason?: "callLLM_failed" | "unparseable_response";
}

interface EpisodicEventRow {
  id: number;
  createdAt: number;
  mode: string;
  rawTranscript: string;
  correctedTranscript: string;
  effectiveInput: string | null;
  selectedContext: string | null;
  result: string | null;
  applicationName: string;
  origin: EventOrigin;
  consolidatedAt: number | null;
}

interface EntityTermCandidate {
  canonicalTerm: string;
  aliases: string[];
  category: EntityCategory;
  confidence: number;
  supportingEventIds: number[];
}

const ALLOWED_CATEGORIES: readonly EntityCategory[] = ["person", "project", "term", "org"];
const MAX_EVENTS_PER_RUN = 200;
const MIN_HOURS_BETWEEN_RUNS = 12;
const MIN_UNCONSOLIDATED_EVENTS = 5;
const HIGH_CONFIDENCE_SINGLE_EVENT = 0.9;
const MODERATE_CONFIDENCE_MULTI_EVENT = 0.6;
const MODERATE_CONFIDENCE_MIN_EVENTS = 2;

// A run's `ranAt` doubles as the correlator that lets rollbackRun() find
// exactly the events *this* run marked consolidatedAt on (there's no join
// column for that in the spec's schema). Runs are 12+ hours apart in normal
// operation, but nothing stops two runs (e.g. in tests, or a manual re-run)
// from landing in the same Date.now() millisecond, which would make rollback
// ambiguous. This keeps ranAt strictly increasing per process so it stays a
// safe correlation key.
let lastAssignedRanAt = 0;
function nextRanAt(): number {
  const candidate = Date.now();
  const value = candidate > lastAssignedRanAt ? candidate : lastAssignedRanAt + 1;
  lastAssignedRanAt = value;
  return value;
}

/**
 * Trigger check from spec §4.4: at least 12 hours since the last run (or no
 * run has ever happened) AND at least 5 unconsolidated events exist.
 */
export function shouldConsolidate(store: MemoryStore): boolean {
  const hours = store.hoursSinceLastConsolidation();
  const enoughTimePassed = hours === null || hours >= MIN_HOURS_BETWEEN_RUNS;
  return enoughTimePassed && store.unconsolidatedEventCount() >= MIN_UNCONSOLIDATED_EVENTS;
}

/**
 * Judgment call (spec §5 flags this as undecided): the consolidation prompt
 * is a single JSON document containing an instruction, the existing entity
 * dictionary (so the model can propose merges/aliases against what's already
 * known), and up to 200 of the most recent unconsolidated events. The
 * requested response shape is
 * `{"candidates":[{canonicalTerm, aliases, category, confidence, supportingEventIds}]}`
 * with no prose/markdown wrapper, so `parseCandidates` can stay a strict
 * `JSON.parse`.
 */
export function buildConsolidationPrompt(
  events: EpisodicEventRow[],
  existingTerms: EntityTerm[]
): string {
  return JSON.stringify({
    instruction:
      "You are OpenType's local memory consolidator. Review the recent dictation events and the " +
      "already-known entity dictionary below, and propose entity-term candidates (people, projects, " +
      "terms, organizations) worth remembering long-term, including any ASR mis-transcription variants " +
      "you notice in rawTranscript as aliases. Respond with ONLY JSON of this exact shape, no prose, no " +
      "markdown code fences: " +
      '{"candidates":[{"canonicalTerm":string,"aliases":string[],' +
      '"category":"person"|"project"|"term"|"org","confidence":number between 0 and 1,' +
      '"supportingEventIds":number[]}]}. If nothing is worth remembering, respond with {"candidates":[]}.',
    existingEntityTerms: existingTerms.map((t) => ({
      id: t.id,
      canonicalTerm: t.canonicalTerm,
      aliases: t.aliases,
    })),
    events: events.map((e) => ({
      id: e.id,
      mode: e.mode,
      rawTranscript: e.rawTranscript,
      correctedTranscript: e.correctedTranscript,
    })),
  });
}

/**
 * Defensively parses the LLM's response. Returns `null` when the response is
 * not JSON, or is JSON but doesn't have a `candidates` array at all — either
 * case means "skip this run silently" per spec §4.4's failure-handling rule.
 * Individual malformed candidate entries inside an otherwise-valid array are
 * dropped rather than aborting the whole run (a judgment call: the spec is
 * ambiguous between whole-response and per-item validation, and dropping
 * just the bad item wastes less of a real model's otherwise-useful output).
 */
function parseCandidates(response: string): EntityTermCandidate[] | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(response);
  } catch {
    return null;
  }

  if (
    typeof parsed !== "object" ||
    parsed === null ||
    !Array.isArray((parsed as { candidates?: unknown }).candidates)
  ) {
    return null;
  }

  const rawList = (parsed as { candidates: unknown[] }).candidates;
  const valid: EntityTermCandidate[] = [];

  for (const item of rawList) {
    if (typeof item !== "object" || item === null) {
      continue;
    }
    const c = item as Record<string, unknown>;
    const aliasesValid =
      Array.isArray(c.aliases) && c.aliases.every((a) => typeof a === "string");
    const supportingValid =
      Array.isArray(c.supportingEventIds) &&
      c.supportingEventIds.every((id) => typeof id === "number");

    if (
      typeof c.canonicalTerm !== "string" ||
      !aliasesValid ||
      typeof c.category !== "string" ||
      !ALLOWED_CATEGORIES.includes(c.category as EntityCategory) ||
      typeof c.confidence !== "number" ||
      !supportingValid
    ) {
      continue;
    }

    valid.push({
      canonicalTerm: c.canonicalTerm,
      aliases: c.aliases as string[],
      category: c.category as EntityCategory,
      confidence: c.confidence,
      supportingEventIds: c.supportingEventIds as number[],
    });
  }

  return valid;
}

/** Deterministic gate from spec §4.4 — never trust the model's own judgment on acceptance. */
function passesGate(candidate: EntityTermCandidate): boolean {
  const supportCount = new Set(candidate.supportingEventIds).size;
  if (candidate.confidence >= HIGH_CONFIDENCE_SINGLE_EVENT && supportCount >= 1) {
    return true;
  }
  return (
    candidate.confidence >= MODERATE_CONFIDENCE_MULTI_EVENT &&
    supportCount >= MODERATE_CONFIDENCE_MIN_EVENTS
  );
}

/** Exact canonicalTerm-or-alias match (case-insensitive), never substring/phonetic. */
function findMatchingTerm(
  existingTerms: EntityTerm[],
  candidate: EntityTermCandidate
): EntityTerm | undefined {
  const candidateNames = new Set(
    [candidate.canonicalTerm, ...candidate.aliases].map((s) => s.toLowerCase())
  );
  return existingTerms.find((term) => {
    const existingNames = [term.canonicalTerm, ...term.aliases].map((s) => s.toLowerCase());
    return existingNames.some((name) => candidateNames.has(name));
  });
}

function unionCaseInsensitive(a: string[], b: string[]): string[] {
  const seen = new Map<string, string>();
  for (const value of [...a, ...b]) {
    const key = value.toLowerCase();
    if (!seen.has(key)) {
      seen.set(key, value);
    }
  }
  return Array.from(seen.values());
}

/**
 * Runs one "dreaming" consolidation pass per spec §4.4. Fetches up to 200
 * most-recent unconsolidated events, asks `callLLM` for structured
 * candidates, applies the deterministic gate, snapshots `entity_terms`
 * before writing, merges/inserts accepted candidates, marks the considered
 * events' `consolidatedAt`, and records one `memory_consolidation_runs` row.
 *
 * On any failure to get a usable, parseable response, this is a strict
 * no-op: nothing is written to `entity_terms` or `episodic_events`, and (a
 * further judgment call) no `memory_consolidation_runs` row is written
 * either — otherwise a failed attempt would reset the 12-hour trigger and
 * delay the retry the spec explicitly wants ("the next scheduled attempt
 * retries the same material").
 */
export async function runConsolidation(
  store: MemoryStore,
  callLLM: CallLLM
): Promise<ConsolidationResult> {
  const events = store.db
    .query(
      "SELECT * FROM episodic_events WHERE consolidatedAt IS NULL ORDER BY createdAt DESC LIMIT ?"
    )
    .all(MAX_EVENTS_PER_RUN) as EpisodicEventRow[];

  const existingTermsBefore = store.allTerms();
  const prompt = buildConsolidationPrompt(events, existingTermsBefore);

  let response: string;
  try {
    response = await callLLM(prompt);
  } catch (err) {
    console.error("[memory/consolidator] callLLM failed; skipping this consolidation run.", err);
    return {
      ranRunId: null,
      eventsConsidered: events.length,
      candidatesProposed: 0,
      candidatesAccepted: 0,
      aborted: true,
      reason: "callLLM_failed",
    };
  }

  const candidates = parseCandidates(response);
  if (candidates === null) {
    console.error(
      "[memory/consolidator] consolidation response did not parse against the expected shape; skipping this run.",
      response
    );
    return {
      ranRunId: null,
      eventsConsidered: events.length,
      candidatesProposed: 0,
      candidatesAccepted: 0,
      aborted: true,
      reason: "unparseable_response",
    };
  }

  const accepted = candidates.filter(passesGate);

  // Snapshot BEFORE any change, per spec.
  const snapshotRows = store.db.query("SELECT * FROM entity_terms").all();
  const snapshotBeforeJSON = JSON.stringify(snapshotRows);

  const now = nextRanAt();
  const summaryParts: string[] = [];
  // Kept up to date as we go so a later accepted candidate in the same batch
  // can merge into one inserted earlier in the same run.
  const currentTerms = existingTermsBefore.slice();

  for (const candidate of accepted) {
    const match = findMatchingTerm(currentTerms, candidate);
    if (match) {
      const mergedAliases = unionCaseInsensitive(match.aliases, candidate.aliases);
      const mergedConfidence = Math.max(match.confidence, candidate.confidence);
      const mergedSourceEventIds = Array.from(
        new Set([...match.sourceEventIds, ...candidate.supportingEventIds])
      );

      store.db.run(
        "UPDATE entity_terms SET aliases = ?, confidence = ?, sourceEventIds = ?, updatedAt = ? WHERE id = ?",
        [JSON.stringify(mergedAliases), mergedConfidence, JSON.stringify(mergedSourceEventIds), now, match.id]
      );

      match.aliases = mergedAliases;
      match.confidence = mergedConfidence;
      match.sourceEventIds = mergedSourceEventIds;
      match.updatedAt = now;

      summaryParts.push(`merged "${candidate.canonicalTerm}" into "${match.canonicalTerm}"`);
    } else {
      const insertResult = store.db.run(
        `INSERT INTO entity_terms
          (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [
          candidate.canonicalTerm,
          JSON.stringify(candidate.aliases),
          candidate.category,
          candidate.confidence,
          "owner" as EventOrigin,
          JSON.stringify(candidate.supportingEventIds),
          now,
          now,
          null,
        ]
      );

      currentTerms.push({
        id: Number(insertResult.lastInsertRowid),
        canonicalTerm: candidate.canonicalTerm,
        aliases: candidate.aliases,
        category: candidate.category,
        confidence: candidate.confidence,
        origin: "owner",
        sourceEventIds: candidate.supportingEventIds,
        createdAt: now,
        updatedAt: now,
        supersedes: null,
      });

      const aliasSummary = candidate.aliases.length > 0 ? candidate.aliases.join(", ") : "none";
      summaryParts.push(`added "${candidate.canonicalTerm}" (aliases: ${aliasSummary})`);
    }
  }

  // All fetched events were considered by this run, whether or not they ended
  // up supporting an accepted candidate — "processed" per spec, not just the
  // supporting subset. consolidatedAt is set to this run's own timestamp so
  // rollbackRun can find exactly this run's events again.
  if (events.length > 0) {
    const ids = events.map((e) => e.id);
    const placeholders = ids.map(() => "?").join(",");
    store.db.run(
      `UPDATE episodic_events SET consolidatedAt = ? WHERE id IN (${placeholders})`,
      [now, ...ids]
    );
  }

  const summary =
    summaryParts.length > 0
      ? summaryParts.join("; ")
      : `no candidates accepted (${candidates.length} proposed, ${events.length} events considered)`;

  const runInsert = store.db.run(
    `INSERT INTO memory_consolidation_runs
      (ranAt, eventsConsidered, candidatesProposed, candidatesAccepted, summary, snapshotBeforeJSON, rolledBackAt)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [now, events.length, candidates.length, accepted.length, summary, snapshotBeforeJSON, null]
  );

  return {
    ranRunId: Number(runInsert.lastInsertRowid),
    eventsConsidered: events.length,
    candidatesProposed: candidates.length,
    candidatesAccepted: accepted.length,
    aborted: false,
  };
}

interface ConsolidationRunRow {
  id: number;
  ranAt: number;
  snapshotBeforeJSON: string;
  rolledBackAt: number | null;
}

/**
 * Undoes one consolidation run: restores `entity_terms` (including ids) from
 * that run's `snapshotBeforeJSON`, marks the run `rolledBackAt`, and clears
 * `consolidatedAt` on exactly the events that run had processed (identified
 * by sharing that run's `ranAt` timestamp — see the note in
 * `runConsolidation`), so they're reconsidered on the next pass.
 */
export function rollbackRun(store: MemoryStore, runId: number): void {
  const run = store.db
    .query("SELECT * FROM memory_consolidation_runs WHERE id = ?")
    .get(runId) as ConsolidationRunRow | null;

  if (!run) {
    throw new Error(`No consolidation run found with id ${runId}`);
  }
  if (run.rolledBackAt !== null) {
    return;
  }

  const snapshotRows = JSON.parse(run.snapshotBeforeJSON) as Array<Record<string, unknown>>;

  store.db.run("DELETE FROM entity_terms");
  for (const row of snapshotRows) {
    store.db.run(
      `INSERT INTO entity_terms
        (id, canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt, supersedes)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        row.id,
        row.canonicalTerm,
        row.aliases,
        row.category,
        row.confidence,
        row.origin,
        row.sourceEventIds,
        row.createdAt,
        row.updatedAt,
        row.supersedes,
      ]
    );
  }

  const now = Date.now();
  store.db.run("UPDATE memory_consolidation_runs SET rolledBackAt = ? WHERE id = ?", [now, runId]);
  store.db.run("UPDATE episodic_events SET consolidatedAt = NULL WHERE consolidatedAt = ?", [run.ranAt]);
}
