/**
 * Writes `docs/tool-catalog.md` from the live tool descriptors (T9 of
 * docs/superpowers/specs/2026-08-13-dsh-borrowings-plan.md §10).
 *
 *   bun run scripts/gen-tool-catalog.ts           # write
 *   bun run scripts/gen-tool-catalog.ts --check   # verify freshness, exit 1 on drift
 *
 * The rendering itself lives in `src/agent/toolCatalog.ts` so it sits in the
 * tested tree; this file is only the CLI and the wiring that instantiates the
 * tool sets.
 */
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { createCoreTools } from "../src/agent/coreTools";
import { createBuiltInTools } from "../src/agent/builtInTools";
import { mergeToolSets } from "../src/agent/toolSets";
import { renderToolCatalog } from "../src/agent/toolCatalog";
import { openDatabase } from "../src/memory/db";
import { MemoryStore } from "../src/memory/MemoryStore";

const OUTPUT = join(import.meta.dir, "..", "..", "docs", "tool-catalog.md");

/**
 * Instantiate both built-in sets purely to read their descriptors.
 *
 * The dependencies are inert on purpose: an in-memory database and a
 * throwing `callLLM`, because generating documentation must never touch the
 * user's real memory database or issue a provider call. Schemas do not depend
 * on either.
 */
function builtInDescriptors(): unknown[] {
  const store = new MemoryStore(openDatabase(":memory:"));
  const callLLM = async () => {
    throw new Error("gen-tool-catalog does not call the model");
  };
  return mergeToolSets(createCoreTools({}), createBuiltInTools({ store, callLLM })).openAiTools;
}

async function main(): Promise<void> {
  const rendered = renderToolCatalog(builtInDescriptors());
  const check = process.argv.includes("--check");

  if (check) {
    const current = await readFile(OUTPUT, "utf8").catch(() => undefined);
    if (current === rendered) {
      console.log(`gen-tool-catalog: ${OUTPUT} is up to date.`);
      return;
    }
    console.error(
      current === undefined
        ? `gen-tool-catalog: ${OUTPUT} is missing. Run: bun run scripts/gen-tool-catalog.ts`
        : `gen-tool-catalog: ${OUTPUT} is stale. Run: bun run scripts/gen-tool-catalog.ts`
    );
    process.exitCode = 1;
    return;
  }

  await mkdir(dirname(OUTPUT), { recursive: true });
  await writeFile(OUTPUT, rendered, "utf8");
  console.log(`gen-tool-catalog: wrote ${OUTPUT}`);
}

await main();
