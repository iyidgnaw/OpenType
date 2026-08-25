import { clearContextUsageLog } from "../oneshot/contextDebugLog";
import { ApiError, type Route } from "../router";
import type {
  EntityCategory,
  EntityTermPatch,
  MemoryStore,
  RecordEpisodicEventInput,
} from "./MemoryStore";
import { rollbackRun, runConsolidation, upsertEntityTerm, type CallLLM } from "./consolidator";

const ENTITY_CATEGORIES: EntityCategory[] = ["person", "project", "term", "org"];

/**
 * The three modes today (design §3.2). Mirrors `ENTITY_CATEGORIES` above:
 * not validation for its own sake, but because this is now the one choke
 * point every episodic write passes through, so a typo or a future
 * Swift-side refactor sending a wrong mode string is caught here instead of
 * writing silently and only surfacing downstream (the recent-activity
 * renderer, or a consolidation pass) with no link back to the write that
 * caused it.
 */
const EPISODIC_MODES = ["transcribe", "ask", "agent"] as const;
type EpisodicMode = (typeof EPISODIC_MODES)[number];

/**
 * Parses an `:id` segment of a `/memory/*<...>/:id<...>` path, counting back
 * from the end. Defaults to the last segment (`segmentsFromEnd = 1`), which
 * is every pre-existing call site (`/memory/terms/:id`, etc., where `:id` IS
 * the last segment) -- unchanged byte-for-byte. `/memory/consolidation-runs/
 * :id/rollback` has a literal segment *after* the id, so that route passes
 * `segmentsFromEnd: 2`. A malformed id (`Number("not-an-id")` is NaN) is a
 * 400, not a 404: letting NaN reach the store would read as "no such row"
 * and report a client mistake as a missing record.
 */
function parseIdParam(req: Request, segmentsFromEnd = 1): number {
  const { pathname } = new URL(req.url);
  const parts = pathname.split("/");
  const raw = parts[parts.length - segmentsFromEnd] ?? "";
  const id = Number(raw);
  if (raw.trim().length === 0 || !Number.isInteger(id)) {
    throw new ApiError("invalid_id", 400);
  }
  return id;
}

function requireStringArray(value: unknown, field: string): string[] {
  if (!Array.isArray(value) || value.some((entry) => typeof entry !== "string")) {
    throw new ApiError(`${field}_must_be_a_string_array`, 400);
  }
  return value as string[];
}

function requireNonEmptyString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new ApiError(`${field}_is_required`, 400);
  }
  return value.trim();
}

/**
 * `GET /memory/events`'s own default/ceiling (design §3.6, §3.7): 200 for
 * both. SQLite reads a negative `LIMIT` as "unbounded", and this endpoint
 * sits directly on `episodic_events` -- a table that, since this batch,
 * holds every dictation the user has ever made -- so an un-clamped
 * `?limit=-1` would hand back the entire table in one response. Any `limit`
 * that is not a positive integer (absent, non-numeric, zero, negative, or
 * non-integer) falls back to the default; anything above the ceiling clamps
 * down to it. `opentype__read_history` (`agent/readHistoryTool.ts`) clamps
 * the same *shape* but different *numbers* (default 10, ceiling 50) on
 * purpose -- that tool bounds how much reaches a model's context, this route
 * bounds a list a person scrolls through, and 200 already reads as "enough
 * for one screenful of history" for that use.
 */
const EVENTS_DEFAULT_LIMIT = 200;
const EVENTS_LIMIT_CEILING = 200;

function clampEventsLimit(raw: string | null): number {
  const value = Number(raw);
  if (raw === null || !Number.isInteger(value) || value <= 0) {
    return EVENTS_DEFAULT_LIMIT;
  }
  return Math.min(value, EVENTS_LIMIT_CEILING);
}

/**
 * Routes backing the Settings "Memory" panel (design §4.1): the entity
 * dictionary and the consolidation run log. The reads are plain reads off
 * MemoryStore — no chat client involved, unlike the oneshot routes — and the
 * `POST`/`PUT`/`DELETE /memory/terms` trio is the panel's editing surface
 * (P0-4), so a user can fix or remove a term the machine got wrong instead of
 * only looking at it.
 *
 * `POST /memory/consolidate-now` is the one write/side-effecting route here:
 * a manual trigger for consolidation ("dreaming"), reachable both from the
 * Settings "Memory" panel's button (`Views.swift`'s `MemoryPanelView`) and
 * from the `consolidate_memory_now` built-in agent tool
 * (`agent/builtInTools.ts`) -- both call this same `runConsolidation`
 * bypass path, so "run it now" behaves identically whether triggered by
 * voice or by clicking a button.
 */
export function buildMemoryRoutes(
  store: MemoryStore,
  callLLM: CallLLM,
  /**
   * Backs `DELETE /memory/context-log` (the exit for
   * `oneshot/contextDebugLog.ts`'s `clearContextUsageLog`), which
   * `AppModel.resetHistory()` (`Sources/OpenType/AppModel.swift`) calls so
   * 「重置输入历史」 actually clears `context-debug.log`. Trailing and optional,
   * mirroring `server.ts`'s `buildApp` convention for `spillRoot?`/
   * `runLogRoot?`, so every pre-existing 2-arg call site keeps compiling.
   * When omitted -- a sidecar assembled without a context log path -- the
   * route still exists but reports "nothing to delete" rather than
   * crashing or silently no-opping on an unconfigured path it might
   * mistake for a real one.
   */
  contextLogPath?: string
): Route[] {
  return [
    {
      // The single write point for episodic events (design §3.2). Swift
      // calls this once, at delivery time, once mode/frontmost-app/final-
      // delivered-text are all known -- facts no sidecar route can
      // reconstruct on its own. This replaces three former writers
      // (`/asr/transcribe`, `/oneshot/ask`, `/agent/run`), each of which only
      // ever knew half of what a row needs; see
      // `test/memory/episodicWiring.test.ts` for the proof those three no
      // longer write.
      method: "POST",
      path: "/memory/events",
      handler: async (req) => {
        const body = (await req.json()) as Partial<RecordEpisodicEventInput>;

        if (typeof body.mode !== "string" || !EPISODIC_MODES.includes(body.mode as EpisodicMode)) {
          throw new ApiError("invalid_mode", 400);
        }
        // Inherited from `recordDictation`, the writer this endpoint
        // replaces (asr/routes.ts, now deleted): an accidental hotkey press
        // produces a silent recording with nothing learnable in it, and five
        // of them would otherwise satisfy `shouldConsolidate`'s gate and
        // burn a real LLM consolidation call on nothing. The guard now lives
        // here rather than in any one caller, because this is the single
        // path every write passes through -- a guard placed in a caller has
        // to be re-remembered by every future caller; a guard placed here
        // cannot be forgotten by any of them.
        if (typeof body.rawTranscript !== "string" || body.rawTranscript.trim().length === 0) {
          throw new ApiError("raw_transcript_is_required", 400);
        }

        const eventId = store.recordEpisodicEvent({
          mode: body.mode,
          rawTranscript: body.rawTranscript,
          correctedTranscript: body.correctedTranscript ?? body.rawTranscript,
          effectiveInput: body.effectiveInput ?? null,
          selectedContext: body.selectedContext ?? null,
          result: body.result ?? null,
          applicationName: body.applicationName ?? "Unknown",
          origin: body.origin ?? "owner",
          conversationId: body.conversationId ?? null,
        });
        return Response.json({ eventId });
      },
    },
    {
      // The dictation history page's whole data source (design §3.7), once
      // Swift's local `history.json` is deleted (plan Task 8): newest-first,
      // the opposite order from `MemoryStore.recentEvents`, which returns
      // oldest-first because a model reads best when the last line is the
      // most recent -- a list a person scrolls reads top-down from newest.
      // Deliberately its own query rather than a call to `recentEvents` for
      // that reason: reusing it would either give the UI the wrong order or
      // require reversing its result, which is the same "one query per
      // reader with its own contract" reasoning `recentEvents`'s own doc
      // comment gives for not sharing a query with `consolidationCandidates`.
      //
      // `mode` is filtered in the SQL WHERE clause, before LIMIT is applied
      // -- filtering after limiting could return an empty page while
      // matching rows still exist further back in the table.
      method: "GET",
      path: "/memory/events",
      handler: (req) => {
        const url = new URL(req.url);
        const limit = clampEventsLimit(url.searchParams.get("limit"));
        const mode = url.searchParams.get("mode");

        const where = mode ? "WHERE mode = ?" : "";
        const args: (string | number)[] = mode ? [mode, limit] : [limit];
        const events = store.db
          .query(
            `SELECT * FROM episodic_events
             ${where}
             ORDER BY createdAt DESC, id DESC
             LIMIT ?`
          )
          .all(...args);
        return Response.json({ events });
      },
    },
    {
      // Backs a single row's delete affordance on the dictation history
      // page. A second delete of the same id is a 404, matching the
      // `/memory/terms/:id` and `/memory/owner-facts/:id` convention this
      // file already uses -- deleting nothing is not success.
      method: "DELETE",
      path: "/memory/events/:id",
      handler: (req) => {
        const id = parseIdParam(req);
        const result = store.db.run("DELETE FROM episodic_events WHERE id = ?", [id]);
        if (result.changes === 0) {
          throw new ApiError("event_not_found", 404);
        }
        return Response.json({ deleted: true });
      },
    },
    {
      // Backs the Settings/Memory panel's "重置输入历史" (reset input
      // history) button, alongside the existing `DELETE /memory/context-log`.
      // Touches `episodic_events` only -- the dictionary the user hand-
      // edited (`entity_terms`), the owner facts remembered about them
      // (`owner_facts`), and the conversations still visible in the sessions
      // list (`conversations`/`conversation_messages`) all live in other
      // tables and must survive a history reset untouched.
      method: "DELETE",
      path: "/memory/events",
      handler: () => {
        const result = store.db.run("DELETE FROM episodic_events");
        return Response.json({ deleted: result.changes });
      },
    },
    {
      method: "GET",
      path: "/memory/terms",
      handler: () => Response.json({ terms: store.allTerms() }),
    },
    {
      // The dictionary panel's "add a term" action. Goes through
      // `upsertEntityTerm` rather than a plain INSERT so a term the user types
      // that collides with an existing canonical/alias merges into it instead
      // of starting a rival row -- which also means the response may carry an
      // *existing* term (`merged: true`), not the one that was posted.
      //
      // `confidence` and `origin` are pinned here, never read off the body:
      // this endpoint means "the owner typed this", and threading a
      // client-claimed provenance through would make the `origin` badge
      // (P1-12) worthless. Being "owner" also promotes a merged-into
      // `untrusted` row -- see `promoteOrigin` in consolidator.ts.
      method: "POST",
      path: "/memory/terms",
      handler: async (req) => {
        const body = (await req.json()) as Record<string, unknown>;
        const canonicalTerm = requireNonEmptyString(body.canonicalTerm, "canonicalTerm");
        const aliases =
          body.aliases === undefined ? [] : requireStringArray(body.aliases, "aliases");

        let category: EntityCategory = "term";
        if (body.category !== undefined) {
          if (!ENTITY_CATEGORIES.includes(body.category as EntityCategory)) {
            throw new ApiError("invalid_category", 400);
          }
          category = body.category as EntityCategory;
        }

        const { term, merged } = upsertEntityTerm(store, store.allTerms(), {
          canonicalTerm,
          aliases,
          category,
          confidence: 1.0,
          sourceEventIds: [],
          origin: "owner",
        });
        return Response.json({ term, merged });
      },
    },
    {
      method: "PUT",
      path: "/memory/terms/:id",
      handler: async (req) => {
        const id = parseIdParam(req);
        const body = (await req.json()) as Record<string, unknown>;

        const patch: EntityTermPatch = {};
        if (body.canonicalTerm !== undefined) {
          patch.canonicalTerm = requireNonEmptyString(body.canonicalTerm, "canonicalTerm");
        }
        if (body.aliases !== undefined) {
          patch.aliases = requireStringArray(body.aliases, "aliases");
        }
        if (body.confidence !== undefined) {
          const confidence = body.confidence;
          if (typeof confidence !== "number" || !Number.isFinite(confidence)
            || confidence < 0 || confidence > 1) {
            // Rejected rather than clamped, matching `updateEntityTerm`: a 1.5
            // is a caller bug, and storing 1.0 for it would hide that behind a
            // value the user never chose.
            throw new ApiError("confidence_must_be_between_0_and_1", 400);
          }
          patch.confidence = confidence;
        }

        const term = store.updateEntityTerm(id, patch);
        if (!term) {
          throw new ApiError("term_not_found", 404);
        }
        return Response.json({ term });
      },
    },
    {
      method: "DELETE",
      path: "/memory/terms/:id",
      handler: (req) => {
        const id = parseIdParam(req);
        if (!store.deleteEntityTerm(id)) {
          throw new ApiError("term_not_found", 404);
        }
        return Response.json({ deleted: true });
      },
    },
    {
      method: "GET",
      path: "/memory/consolidation-runs",
      handler: () => Response.json({ runs: store.listConsolidationRuns() }),
    },
    {
      method: "POST",
      path: "/memory/consolidate-now",
      handler: async () => {
        const result = await runConsolidation(store, callLLM);
        return Response.json({ result });
      },
    },
    {
      // The 回滚 button's HTTP exit. `rollbackRun` (consolidator.ts) already
      // does the actual work -- restore `entity_terms` from the run's
      // pre-run snapshot, transactionally -- this route is only what makes
      // it reachable, plus the two things `rollbackRun` deliberately does
      // NOT take responsibility for:
      //
      //   1. `rollbackRun` restores a FULL-TABLE snapshot, not a diff, so
      //      undoing anything but the newest still-active run would erase
      //      whatever a later run added while leaving that later run's row
      //      claiming `rolledBackAt: null` -- the run log would lie about
      //      what's actually in the store. So a run here is eligible only
      //      if every run that ran after it (by `ranAt`) has already been
      //      rolled back -- a stack, popped from the top only. This guard
      //      runs BEFORE `rollbackRun` is called at all: a 409 that had
      //      already mutated the table would be worse than no guard. It is
      //      skipped for a run that is already rolled back -- `rollbackRun`
      //      no-ops on those regardless of what's above them, so there is
      //      nothing to protect and a repeat POST stays a harmless 200
      //      rather than an order error.
      //   2. `rollbackRun` throws a plain `Error` (not `ApiError`) for an
      //      unknown run id, which would otherwise surface as an uncaught
      //      500 -- translated to a 404 here instead.
      method: "POST",
      path: "/memory/consolidation-runs/:id/rollback",
      handler: (req) => {
        const id = parseIdParam(req, 2);

        const runsBefore = store.listConsolidationRuns(); // ranAt DESC, newest first
        const target = runsBefore.find((r) => r.id === id);
        if (target && target.rolledBackAt === null) {
          const blockedByALaterActiveRun = runsBefore.some(
            (r) => r.ranAt > target.ranAt && r.rolledBackAt === null
          );
          if (blockedByALaterActiveRun) {
            throw new ApiError("rollback_out_of_order", 409);
          }
        }

        try {
          rollbackRun(store, id);
        } catch {
          throw new ApiError("consolidation_run_not_found", 404);
        }

        const run = store.listConsolidationRuns().find((r) => r.id === id);
        return Response.json({ run });
      },
    },
    {
      // Lists EVERY owner fact regardless of origin (owner/untrusted/agent/
      // system) — the opposite requirement to prompt injection, which only
      // surfaces "owner" facts. Exposing all origins here is what lets a user
      // find a poisoned (non-owner) fact to delete it (P1-12).
      method: "GET",
      path: "/memory/owner-facts",
      handler: () => Response.json({ ownerFacts: store.allOwnerFacts() }),
    },
    {
      // "I read this and I vouch for it" — the action that lets a user *clear*
      // a provenance flag rather than only delete the fact carrying it.
      //
      // Provenance exists so the user can review what an agent planted from
      // untrusted context (P1-12). A label the user cannot clear after
      // reviewing is noise, and a user who learns the label never goes away
      // learns to ignore it — which costs exactly the signal it was added for.
      // Until this route existed the panel's only answer to a fact that was
      // flagged but *correct* was to delete it, which throws away something
      // true to silence a warning.
      //
      // The direction is fixed: this route only ever writes `"owner"`.
      // `store.confirmOwnerFact` has no target-origin parameter to demote
      // through, and a body that names some other origin is refused outright
      // rather than ignored — a caller stating an intent this route will not
      // honour should hear about it, not be silently given a different one.
      // Same rule, same reason as `promoteOrigin` in consolidator.ts.
      method: "PATCH",
      path: "/memory/owner-facts/:id",
      handler: async (req) => {
        const id = parseIdParam(req);

        // The body is optional — the route has exactly one effect, so naming it
        // is redundant. When it *is* named it has to agree.
        const raw = await req.text();
        if (raw.trim().length > 0) {
          const body = JSON.parse(raw) as Record<string, unknown>;
          if (body.origin !== undefined && body.origin !== "owner") {
            throw new ApiError("origin_must_be_owner", 400);
          }
        }

        const ownerFact = store.confirmOwnerFact(id);
        if (!ownerFact) {
          throw new ApiError("owner_fact_not_found", 404);
        }
        return Response.json({ ownerFact });
      },
    },
    {
      method: "DELETE",
      path: "/memory/owner-facts/:id",
      handler: (req) => {
        // Same id handling as the entity-term routes above (400 malformed /
        // 404 unknown), rather than the older "parse whatever, always answer
        // deleted: true" — both live behind one panel, so a delete that
        // silently did nothing would be indistinguishable from one that worked.
        const id = parseIdParam(req);
        if (!store.deleteOwnerFact(id)) {
          throw new ApiError("owner_fact_not_found", 404);
        }
        return Response.json({ deleted: true });
      },
    },
    {
      // Closes docs/superpowers/specs/2026-08-09-current-system-state.md
      // §11's "context-debug.log has no governance" gap, the "not cleared
      // by the reset input history action" third (permissions and rotation
      // are `contextDebugLog.ts`'s own governance, applied on every write).
      //
      // Unlike the id-addressed term/owner-fact deletes above, this route
      // has no "unknown id" concept: it clears a file that may or may not
      // exist, so idempotent-clear-of-nothing is success (200), not a 404 --
      // matching `clearContextUsageLog`'s own no-op contract.
      method: "DELETE",
      path: "/memory/context-log",
      handler: () => {
        // No configured path (a sidecar assembled without one, e.g. an
        // older test-only assembly) means there is nothing on disk this
        // route could ever have written -- report the same success a real
        // clear-of-nothing would, rather than crashing or fabricating a 404
        // for a resource concept this route doesn't have.
        if (contextLogPath) {
          clearContextUsageLog(contextLogPath);
        }
        return Response.json({ deleted: true });
      },
    },
  ];
}
