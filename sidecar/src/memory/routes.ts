import type { Route } from "../router";
import type { MemoryStore } from "./MemoryStore";

/**
 * Read-only routes backing the Settings "Memory" panel (design §4.1): the
 * current entity dictionary and the consolidation run log. Both are plain
 * reads off MemoryStore — no chat client involved, unlike the oneshot routes.
 */
export function buildMemoryRoutes(store: MemoryStore): Route[] {
  return [
    {
      method: "GET",
      path: "/memory/terms",
      handler: () => Response.json({ terms: store.allTerms() }),
    },
    {
      method: "GET",
      path: "/memory/consolidation-runs",
      handler: () => Response.json({ runs: store.listConsolidationRuns() }),
    },
  ];
}
