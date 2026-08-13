import { describe, expect, test } from "bun:test";
import { mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { renderSpilledResult, saveSpill, spillOrClamp } from "../../src/agent/spill";

/**
 * T2 of the dsh-borrowings plan
 * (docs/superpowers/specs/2026-08-13-dsh-borrowings-plan.md §7).
 *
 * Today an oversized tool result is DISCARDED (`clampToolResult`): the model
 * is told it was truncated and given no way whatsoever to reach the rest.
 * Spill keeps the full text on disk and hands back a preview plus a path the
 * agent can reopen with the tools it already has.
 */

async function tempRoot(): Promise<string> {
  return mkdtemp(join(tmpdir(), "opentype-spill-test-"));
}

describe("saveSpill", () => {
  test("writes the full text and returns its path", async () => {
    const root = await tempRoot();
    const text = "x".repeat(50_000);

    const path = await saveSpill(text, { toolName: "opentype__bash", runId: "run-1" }, root);

    expect(path).not.toBeNull();
    expect(await readFile(path!, "utf8")).toBe(text);
  });

  test("creates the artifact owner-only (0600) and its directory 0700", async () => {
    const root = await tempRoot();

    const path = await saveSpill("body", { toolName: "opentype__grep", runId: "run-2" }, root);

    expect(path).not.toBeNull();
    expect((await stat(path!)).mode & 0o777).toBe(0o600);
    expect((await stat(join(root, "run-2"))).mode & 0o777).toBe(0o700);
  });

  test("never lets a tool name escape the spill root", async () => {
    const root = await tempRoot();

    const path = await saveSpill("body", { toolName: "../../etc/passwd", runId: "run-3" }, root);

    expect(path).not.toBeNull();
    expect(path!.startsWith(root)).toBe(true);
    expect(path).not.toContain("..");
  });

  test("two saves from the same tool and run do not collide", async () => {
    const root = await tempRoot();
    const source = { toolName: "opentype__bash", runId: "run-4" };

    const first = await saveSpill("first", source, root);
    const second = await saveSpill("second", source, root);

    expect(first).not.toBe(second);
    expect(await readFile(first!, "utf8")).toBe("first");
    expect(await readFile(second!, "utf8")).toBe("second");
  });

  test("groups runs without an id under a shared bucket rather than failing", async () => {
    const root = await tempRoot();

    const path = await saveSpill("body", { toolName: "opentype__web_fetch" }, root);

    expect(path).not.toBeNull();
    expect(path!.startsWith(root)).toBe(true);
  });

  test("returns null instead of throwing when the root is unusable", async () => {
    const root = await tempRoot();
    // A regular file where the root directory must be: mkdir will fail.
    const blocked = join(root, "blocked");
    await writeFile(blocked, "not a directory");

    const path = await saveSpill("body", { toolName: "opentype__bash", runId: "r" }, blocked);

    expect(path).toBeNull();
  });
});

describe("renderSpilledResult", () => {
  const text = `${"H".repeat(400)}${"M".repeat(9_000)}${"T".repeat(400)}`;
  const rendered = renderSpilledResult(text, "/tmp/spill/run/abc-bash.txt");

  test("keeps a head and a tail of the original", () => {
    expect(rendered.startsWith("HHH")).toBe(true);
    expect(rendered).toContain("TTT");
  });

  test("states the true total size and the path", () => {
    expect(rendered).toContain(String(text.length));
    expect(rendered).toContain("/tmp/spill/run/abc-bash.txt");
  });

  test("tells the model HOW to retrieve the rest, with real tool names", () => {
    // dsh's rule: the locator is opaque, so the retrieval hint -- not the
    // model's own guess about what a path means -- is what makes it usable.
    expect(rendered).toContain("opentype__read_file");
    expect(rendered).toContain("opentype__grep");
  });

  test("is much smaller than the original", () => {
    expect(rendered.length).toBeLessThan(text.length / 2);
  });
});

describe("the retrieval path spill promises", () => {
  test("the agent's own read_file tool can reopen a spilled artifact", async () => {
    // This is the whole justification for spilling instead of truncating: the
    // locator must be usable by a tool the agent already has. A path the
    // agent cannot open would be no better than the discarded tail.
    const { createCoreTools } = await import("../../src/agent/coreTools");
    const root = await tempRoot();
    const body = `${"needle-start".padEnd(40, "-")}\nmiddle\n${"needle-end".padEnd(40, "-")}`;

    const path = await saveSpill(body, { toolName: "opentype__bash", runId: "run-r" }, root);
    expect(path).not.toBeNull();

    const result = await createCoreTools({}).callTool("opentype__read_file", { path });

    expect(result.content).toContain("needle-start");
    expect(result.content).toContain("needle-end");
  });
});

describe("spillOrClamp", () => {
  const short = "small result";
  const long = "y".repeat(40_000);

  test("passes a result under the limit through untouched", async () => {
    const out = await spillOrClamp(short, {
      maxInline: 20_000,
      save: async () => "/should/not/be/used",
    });

    expect(out).toBe(short);
  });

  test("spills an oversized result and points at the artifact", async () => {
    const out = await spillOrClamp(long, {
      maxInline: 20_000,
      save: async () => "/tmp/spill/run/abc-bash.txt",
    });

    expect(out).toContain("/tmp/spill/run/abc-bash.txt");
    expect(out).toContain("opentype__read_file");
    expect(out.length).toBeLessThan(long.length);
  });

  test("falls back to truncation when saving fails, still as a SUCCESS", async () => {
    // Best-effort, per dsh's spill policy: a storage failure must never turn
    // a tool call that actually succeeded into an error result.
    const out = await spillOrClamp(long, { maxInline: 20_000, save: async () => null });

    expect(out).toContain("...[truncated]");
    expect(out).not.toContain("Error");
    expect(out.length).toBeLessThanOrEqual(20_000 + 32);
  });

  test("falls back to truncation when saving throws", async () => {
    const out = await spillOrClamp(long, {
      maxInline: 20_000,
      save: async () => {
        throw new Error("ENOSPC");
      },
    });

    expect(out).toContain("...[truncated]");
    expect(out).not.toContain("ENOSPC");
  });

  test("works with no save function at all (pure clamp)", async () => {
    const out = await spillOrClamp(long, { maxInline: 20_000 });

    expect(out).toContain("...[truncated]");
  });
});
