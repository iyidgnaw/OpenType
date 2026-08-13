/**
 * Tests for `filterToolSet` (B2 open-file + ask-web design,
 * docs/superpowers/specs/2026-08-13-b2-open-file-and-ask-web-design.md §2):
 * a small helper in `src/agent/toolSets.ts` that narrows a ToolSet to an
 * allowlist of tool names. This is how `/oneshot/ask` gets its web-only
 * toolset (exactly `opentype__web_search` + `opentype__web_fetch`) out of
 * the full merged set.
 *
 * Contract these tests pin (for stage 3):
 * - `filterToolSet(set, names)` returns a ToolSet whose `openAiTools` are
 *   exactly the descriptors for `names` -- the original descriptor objects,
 *   unmodified, in the stated order;
 * - the filtered set's `callTool` routes kept names through to the source
 *   set with name and args intact;
 * - `callTool` throws /unknown tool/i for any name NOT in `names` -- even
 *   one the source set could serve -- matching `mergeToolSets`'s routing
 *   contract for unknown names;
 * - it composes with `withApproval`: filtering an approval-wrapped set
 *   keeps the gate, since routing goes through the wrapped `callTool`.
 *
 * `filterToolSet` is pulled off a namespace import (not a named import) so
 * this file still loads while the export does not exist yet: each test then
 * fails cleanly on "filterToolSet is not a function" instead of the whole
 * file failing at module-link time (which would misreport unrelated tests).
 */
import { describe, expect, test } from "bun:test";
import * as os from "node:os";
import * as toolSetsModule from "../../src/agent/toolSets";
import type { ToolSet } from "../../src/agent/toolSets";
import { createCoreTools } from "../../src/agent/coreTools";
import { withApproval, yoloApprovalPolicy } from "../../src/agent/approval";

const filterToolSet = (
  toolSetsModule as { filterToolSet?: (set: ToolSet, names: string[]) => ToolSet }
).filterToolSet as (set: ToolSet, names: string[]) => ToolSet;

const WEB_SEARCH = "opentype__web_search";
const WEB_FETCH = "opentype__web_fetch";

function descriptor(name: string): { type: string; function: { name: string } } {
  return { type: "function", function: { name } };
}

function makeSet(
  names: string[],
  onCall?: (name: string, args: unknown) => string
): { set: ToolSet; invocations: Array<{ name: string; args: unknown }> } {
  const invocations: Array<{ name: string; args: unknown }> = [];
  const set: ToolSet = {
    openAiTools: names.map(descriptor),
    callTool: async (name, args) => {
      invocations.push({ name, args });
      return { content: onCall ? onCall(name, args) : `source handled ${name}` };
    },
  };
  return { set, invocations };
}

describe("filterToolSet", () => {
  test("is exported from src/agent/toolSets", () => {
    expect(typeof filterToolSet).toBe("function");
  });

  test("openAiTools contains exactly the named descriptors, unmodified, in order", () => {
    // Source order deliberately interleaves a non-web tool between the two
    // web tools; the filtered result is exactly [web_search, web_fetch].
    const { set } = makeSet([WEB_SEARCH, "opentype__bash", WEB_FETCH]);

    const filtered = filterToolSet(set, [WEB_SEARCH, WEB_FETCH]);

    expect(filtered.openAiTools).toEqual([descriptor(WEB_SEARCH), descriptor(WEB_FETCH)]);
  });

  test("callTool routes a kept name through to the source set with name and args intact", async () => {
    const { set, invocations } = makeSet(
      [WEB_SEARCH, WEB_FETCH, "opentype__bash"],
      (name) => `served ${name}`
    );
    const filtered = filterToolSet(set, [WEB_SEARCH, WEB_FETCH]);

    const result = await filtered.callTool(WEB_SEARCH, { query: "opentype sidecar" });

    expect(result.content).toBe(`served ${WEB_SEARCH}`);
    expect(invocations).toEqual([{ name: WEB_SEARCH, args: { query: "opentype sidecar" } }]);
  });

  test("callTool throws 'Unknown tool' for a filtered-out name the source set could serve", async () => {
    const { set, invocations } = makeSet(["opentype__bash", WEB_SEARCH, WEB_FETCH]);
    const filtered = filterToolSet(set, [WEB_SEARCH, WEB_FETCH]);

    await expect(filtered.callTool("opentype__bash", { command: "echo hi" })).rejects.toThrow(
      /unknown tool/i
    );
    // The source set must never see the filtered-out call.
    expect(invocations).toEqual([]);
  });

  test("callTool throws 'Unknown tool' for a name no set ever had", async () => {
    const { set } = makeSet([WEB_SEARCH, WEB_FETCH]);
    const filtered = filterToolSet(set, [WEB_SEARCH, WEB_FETCH]);

    await expect(filtered.callTool("opentype__no_such_tool", {})).rejects.toThrow(/unknown tool/i);
  });

  test("a web-only set filtered from the real core tools (approval-wrapped) still fetches via the injected fetchFn, and bash is unreachable", async () => {
    const fetched: string[] = [];
    const fetchFn = (async (input: unknown) => {
      fetched.push(String(input));
      return new Response("<html><body><p>Visible body text.</p></body></html>", {
        status: 200,
        headers: { "content-type": "text/html" },
      });
    }) as unknown as typeof fetch;
    const core = createCoreTools({ homeDir: os.tmpdir(), fetchFn });

    const filtered = filterToolSet(withApproval(core, yoloApprovalPolicy), [
      WEB_SEARCH,
      WEB_FETCH,
    ]);

    expect(
      filtered.openAiTools.map((t) => (t as { function: { name: string } }).function.name)
    ).toEqual([WEB_SEARCH, WEB_FETCH]);

    const result = await filtered.callTool(WEB_FETCH, { url: "https://example.com/x" });
    expect(fetched).toEqual(["https://example.com/x"]);
    expect(result.content).toContain("Visible body text.");

    await expect(filtered.callTool("opentype__bash", { command: "echo hi" })).rejects.toThrow(
      /unknown tool/i
    );
  });
});
