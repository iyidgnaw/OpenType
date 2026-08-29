import { describe, expect, test } from "bun:test";
import { chmod, mkdtemp, readdir, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRunLog, readRunLog, RUN_LOG_RETENTION } from "../../src/agent/runLog";

/**
 * Stage-1 (TDD red) coverage for the run-log retention cap.
 *
 * `run-logs/` (`sidecar/src/agent/runLog.ts`) accumulates one `<runId>.jsonl`
 * file per agent run, forever -- no cap, no rotation, nothing in the product
 * ever deletes it. Owner decision (see the batch's design note): keep the
 * newest `RUN_LOG_RETENTION` (50) files, pruning oldest-by-mtime-first, and
 * do the prune scan only when a run's FIRST event creates a brand-new file
 * -- not on every append, which would stat the directory on every progress
 * tick of a long-running agent loop.
 *
 * THE MISSING SURFACE (stage 3 builds this; nothing here builds it):
 *
 *     // sidecar/src/agent/runLog.ts
 *     export const RUN_LOG_RETENTION = 50;
 *
 * and `createRunLog(root).append(runId, event)` gains a prune step that:
 *   - runs only when `runId` has no in-memory `nextSeq` entry yet (i.e. this
 *     is the first event this `RunLog` instance has seen for that run --
 *     matching how `nextSeq` already distinguishes "first" from "later"
 *     appends for the seq-numbering feature above it in this same file);
 *   - lists the existing `*.jsonl` files in `root`, and if there are already
 *     `RUN_LOG_RETENTION` or more, deletes the oldest-by-mtime ones so that
 *     once the new run's file is written, exactly `RUN_LOG_RETENTION` files
 *     remain;
 *   - is wrapped in its own failure isolation, separate from the existing
 *     write's try/catch, so a prune failure (unreadable directory, a
 *     permissions error, anything) can never stop the event itself from
 *     being written -- `append` must keep its current "never rejects"
 *     contract (see the sibling `runLog.test.ts`'s "never throws when the
 *     root is unusable").
 *
 * Every test below builds its own temp root (`mkdtemp`) -- never the real
 * data dir -- following this directory's existing convention
 * (`runLog.test.ts`'s `tempRoot()`).
 */

async function tempRoot(): Promise<string> {
  return mkdtemp(join(tmpdir(), "opentype-runlog-retention-test-"));
}

/**
 * Seeds one `<runId>.jsonl` file directly on disk (bypassing `createRunLog`
 * entirely) with an explicit mtime, so ordering in these tests is pinned by
 * an explicit timestamp rather than by real-wall-clock write-order timing.
 */
async function seedRunLogFile(root: string, runId: string, mtimeMs: number): Promise<void> {
  const path = join(root, `${runId}.jsonl`);
  await writeFile(
    path,
    `${JSON.stringify({ runId, seq: 0, time: mtimeMs, type: "done", detail: "seed" })}\n`,
    { encoding: "utf8" }
  );
  const seconds = mtimeMs / 1000;
  await utimes(path, seconds, seconds);
}

async function jsonlFileNames(root: string): Promise<string[]> {
  const entries = await readdir(root);
  return entries.filter((name) => name.endsWith(".jsonl")).sort();
}

describe("run-log retention cap (RUN_LOG_RETENTION)", () => {
  test("the cap is 50", () => {
    expect(RUN_LOG_RETENTION).toBe(50);
  });

  test("at the cap: starting one more run prunes exactly the oldest file, leaving RUN_LOG_RETENTION total", async () => {
    const root = await tempRoot();
    const base = Date.now();
    for (let i = 0; i < RUN_LOG_RETENTION; i++) {
      // Strictly increasing mtimes: existing-0 is the oldest.
      await seedRunLogFile(root, `existing-${i}`, base + i * 1000);
    }

    const log = createRunLog(root);
    await log.append("new-run", { type: "done", detail: "d" });

    const files = await jsonlFileNames(root);
    expect(files.length).toBe(RUN_LOG_RETENTION);
    expect(files).not.toContain("existing-0.jsonl");
    for (let i = 1; i < RUN_LOG_RETENTION; i++) {
      expect(files).toContain(`existing-${i}.jsonl`);
    }
    expect(files).toContain("new-run.jsonl");
  });

  test("under the cap: 3 existing files, a 4th run leaves 4 files, nothing deleted", async () => {
    const root = await tempRoot();
    const base = Date.now();
    await seedRunLogFile(root, "a", base);
    await seedRunLogFile(root, "b", base + 1_000);
    await seedRunLogFile(root, "c", base + 2_000);

    const log = createRunLog(root);
    await log.append("d", { type: "done", detail: "d" });

    const files = await jsonlFileNames(root);
    expect(files).toEqual(["a.jsonl", "b.jsonl", "c.jsonl", "d.jsonl"]);
  });

  test("pruning happens only on the FIRST event of a new run, never on a later append to the same run", async () => {
    const root = await tempRoot();
    const log = createRunLog(root);

    // First event ever for "run-once" on this RunLog instance: allowed to
    // prune (root starts empty, nothing to prune yet), creates the file.
    await log.append("run-once", { type: "thinking", detail: "1" });

    // Push the directory well over the cap for a reason that has nothing to
    // do with "run-once": RUN_LOG_RETENTION extra pre-existing files, all
    // older than run-once's own file. If a second append to "run-once"
    // re-scanned and pruned, at least one of these would be evicted.
    const base = Date.now() - 100_000;
    for (let i = 0; i < RUN_LOG_RETENTION; i++) {
      await seedRunLogFile(root, `unrelated-${i}`, base + i * 10);
    }
    const beforeSecondAppend = await jsonlFileNames(root);
    expect(beforeSecondAppend.length).toBe(RUN_LOG_RETENTION + 1); // +run-once.jsonl

    // A SECOND event for the SAME run must not trigger another prune scan.
    await log.append("run-once", { type: "done", detail: "2" });

    const afterSecondAppend = await jsonlFileNames(root);
    expect(afterSecondAppend).toEqual(beforeSecondAppend);
  });

  test("a prune failure does not stop the event from being written (isolation from the write path)", async () => {
    const root = await tempRoot();
    const base = Date.now();
    // Over the cap, so the next new run has something to prune (and thus
    // something for pruning to fail at).
    for (let i = 0; i < RUN_LOG_RETENTION; i++) {
      await seedRunLogFile(root, `existing-${i}`, base + i * 1_000);
    }
    // Directory permission trick: write+execute (create a new file) but NOT
    // read (list/stat existing entries) on `root`. A listing-based prune
    // (readdir, to sort candidates by mtime) throws EACCES, while creating
    // a brand-new, previously-unnamed file in the same directory still
    // succeeds -- isolating "pruning failed" from "the write itself
    // failed". Verified against this runtime directly: `readdir` throws
    // under 0o300 while `appendFile` of a new file still succeeds.
    await chmod(root, 0o300);

    try {
      const log = createRunLog(root);
      await expect(
        log.append("new-run", { type: "done", detail: "still written" })
      ).resolves.toBeUndefined();
    } finally {
      // Restore so the temp directory can be listed/cleaned up normally.
      await chmod(root, 0o700);
    }

    const entries = await readRunLog(root, "new-run");
    expect(entries.length).toBe(1);
    expect(entries[0]!.detail).toBe("still written");
  });
});
