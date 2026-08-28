import { describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { createSkillStore, renderSkillIndex, type Skill } from "../../src/skills/skillStore";

/**
 * A skill is a DIRECTORY containing SKILL.md (design §3.1). skillStore.ts is
 * expected to sit on top of resourceStore.ts's generic multi-root discovery
 * (resourceStore.test.ts covers first-root-wins/TTL/missing-root at that
 * layer) configured with entryFileName "SKILL.md"; these tests only cover
 * behavior specific to skills: the three-root discovery order being INJECTED
 * rather than hardcoded to real paths, ignoring a non-skill directory, and
 * the rendered index's format/clamp/empty-set rules (design §3.3).
 *
 * Roots are always temp dirs -- never the real `~/.opentype/skills` or
 * `~/.claude/skills` -- so this suite proves injection, not the real
 * three-root default wiring (that wiring belongs to whatever assembles
 * `createSkillStore` in `server.ts`, out of scope here).
 */

function mkTempDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "opentype-skillstore-"));
}

function writeSkill(root: string, dirName: string, name: string, description: string, body: string): void {
  const dir = path.join(root, dirName);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(
    path.join(dir, "SKILL.md"),
    ["---", `name: ${name}`, `description: ${description}`, "---", body].join("\n")
  );
}

function skill(patch: Partial<Skill>): Skill {
  return {
    name: "s",
    description: "d",
    body: "b",
    root: "/tmp/root",
    path: "/tmp/root/s/SKILL.md",
    ...patch,
  };
}

describe("createSkillStore", () => {
  test("discovers skills from an injected, ordered list of roots, first root winning on collision", () => {
    const rootA = mkTempDir();
    const rootB = mkTempDir();
    const rootC = mkTempDir();
    writeSkill(rootA, "only-a", "only-a", "d", "b");
    writeSkill(rootB, "shared", "shared", "from B", "BODY B");
    writeSkill(rootC, "shared", "shared", "from C", "BODY C");

    // Order matters: rootB before rootC means rootB's "shared" wins, proving
    // the store honors whatever order it's given rather than any fixed
    // built-in/user/compat path names (which never appear in this test).
    const store = createSkillStore({ roots: [rootA, rootB, rootC] });
    const names = store.list().map((s) => s.name).sort();
    expect(names).toEqual(["only-a", "shared"]);

    const shared = store.list().find((s) => s.name === "shared");
    expect(shared?.body).toBe("BODY B");
  });

  test("a directory without SKILL.md is ignored", () => {
    const root = mkTempDir();
    fs.mkdirSync(path.join(root, "not-a-skill"), { recursive: true });
    fs.writeFileSync(path.join(root, "not-a-skill", "README.md"), "not a skill");
    writeSkill(root, "real-skill", "real-skill", "d", "b");

    const store = createSkillStore({ roots: [root] });

    expect(store.list().map((s) => s.name)).toEqual(["real-skill"]);
  });

  describe("renderSkillIndex", () => {
    test("one line per skill of the form 'name: description'", () => {
      const out = renderSkillIndex([
        skill({ name: "find-and-open", description: "Use when the user asks to find a file" }),
        skill({ name: "organize-files", description: "Use when the user asks to tidy up a folder" }),
      ]);

      expect(out).toBe(
        [
          "find-and-open: Use when the user asks to find a file",
          "organize-files: Use when the user asks to tidy up a folder",
        ].join("\n")
      );
    });

    test("clamps to at most 40 skills and says so when it truncates", () => {
      const many: Skill[] = Array.from({ length: 50 }, (_, i) =>
        skill({ name: `skill-${i}`, description: "short desc" })
      );

      const out = renderSkillIndex(many);
      expect(out).toBeDefined();
      const lines = (out as string).split("\n");

      // At most 40 real entry lines, plus whatever truncation-notice line(s)
      // the implementation adds -- either way the count of skill-N lines is bounded.
      const entryLines = lines.filter((l) => l.startsWith("skill-"));
      expect(entryLines.length).toBeLessThanOrEqual(40);

      // The truncation must be VISIBLE, never silent: something in the
      // rendered text must say more were left out.
      const mentionsTruncation = /more|truncat|\+\s*\d+/i.test(out as string);
      expect(mentionsTruncation).toBe(true);
    });

    test("clamps to ~4000 characters even with fewer than 40 skills, and says so", () => {
      const long: Skill[] = Array.from({ length: 10 }, (_, i) =>
        skill({ name: `long-skill-${i}`, description: "x".repeat(1000) })
      );

      const out = renderSkillIndex(long) as string;
      // 10 * (~1020 chars/line) would be ~10,200 chars unclamped -- well past
      // the ~4000 char budget design §3.3 sets, so this must have truncated
      // on SIZE even though the skill count (10) is nowhere near the 40 cap.
      expect(out.length).toBeLessThan(4_500);
      expect(/more|truncat|\+\s*\d+/i.test(out)).toBe(true);
    });

    test("an empty set of skills renders as falsy (undefined/empty), not an empty header block", () => {
      // The loop must be able to do `if (input.skills) { ... }` and skip the
      // field entirely -- a rendered-but-empty header ("Skills:\n") would be
      // truthy and would inject a useless block into every request.
      const out = renderSkillIndex([]);
      expect(out).toBeFalsy();
    });

    test("both caps fire together and the truncation notice reports the TRUE total omitted, not just one cap's share", () => {
      // 100 skills is well past the 40-entry cap on its own. Each
      // description is 500 chars, so even the 40 entries the count cap alone
      // would allow through (40 * ~509 chars =~ 20,360) blow the ~4000 char
      // budget many times over -- this input is specifically chosen so BOTH
      // clamps are load-bearing: the count slice narrows 100 -> 40, then the
      // char budget narrows that 40 further, down to whatever actually fits.
      // A coherence bug here (each clamp tracking its own omission count and
      // the two not summing correctly) is exactly the silent-truncation
      // failure mode design §3.3 exists to prevent -- a notice with the
      // wrong number is worse than no notice, since it looks trustworthy.
      const total = 100;
      const many: Skill[] = Array.from({ length: total }, (_, i) =>
        skill({ name: `skill-${i}`, description: "x".repeat(500) })
      );

      const out = renderSkillIndex(many);
      expect(out).toBeDefined();
      const lines = (out as string).split("\n");
      const entryLines = lines.filter((l) => /^skill-\d+: /.test(l));

      // Proves the char cap is the one actually binding here (not the count
      // cap alone) -- if only the 40-entry cap applied, entryLines.length
      // would be exactly 40, which the char budget cannot fit.
      expect(entryLines.length).toBeGreaterThan(0);
      expect(entryLines.length).toBeLessThan(40);

      const noticeMatch = (out as string).match(/\+(\d+) more/);
      expect(noticeMatch).not.toBeNull();
      const claimedOmitted = Number(noticeMatch?.[1]);

      // The number in the notice must equal what was ACTUALLY left out of
      // the index (100 minus however many entries really rendered) -- not
      // just the count-cap's own 60, and not just the char-cap's own share.
      const trueOmitted = total - entryLines.length;
      expect(claimedOmitted).toBe(trueOmitted);

      // Still within budget (with headroom for the notice line itself).
      expect((out as string).length).toBeLessThan(4_500);
    });
  });
});
