import type { Route } from "../router";
import type { MemoryStore } from "./MemoryStore";
import { runConsolidation, type CallLLM } from "./consolidator";

/**
 * Read-only routes backing the Settings "Memory" panel (design §4.1): the
 * current entity dictionary and the consolidation run log. Both are plain
 * reads off MemoryStore — no chat client involved, unlike the oneshot routes.
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
  ];
}
