import { ApiError, type Route } from "../router";
import type { EntityCategory, EntityTermPatch, MemoryStore } from "./MemoryStore";
import { runConsolidation, upsertEntityTerm, type CallLLM } from "./consolidator";

const ENTITY_CATEGORIES: EntityCategory[] = ["person", "project", "term", "org"];

/**
 * Parses the trailing `:id` segment of a `/memory/*<...>/:id` path. A malformed
 * id (`Number("not-an-id")` is NaN) is a 400, not a 404: letting NaN reach the
 * store would read as "no such row" and report a client mistake as a missing
 * record.
 */
function parseIdParam(req: Request): number {
  const { pathname } = new URL(req.url);
  const raw = pathname.split("/").pop() ?? "";
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
export function buildMemoryRoutes(store: MemoryStore, callLLM: CallLLM): Route[] {
  return [
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
      // Lists EVERY owner fact regardless of origin (owner/untrusted/agent/
      // system) — the opposite requirement to prompt injection, which only
      // surfaces "owner" facts. Exposing all origins here is what lets a user
      // find a poisoned (non-owner) fact to delete it (P1-12).
      method: "GET",
      path: "/memory/owner-facts",
      handler: () => Response.json({ ownerFacts: store.allOwnerFacts() }),
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
  ];
}
