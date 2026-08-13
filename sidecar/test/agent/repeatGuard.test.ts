import { describe, expect, test } from "bun:test";
import { createRepeatGuard } from "../../src/agent/repeatGuard";

/**
 * T3 of the dsh-borrowings plan
 * (docs/superpowers/specs/2026-08-13-dsh-borrowings-plan.md §8).
 *
 * The loop's only protection against a degenerate model was its 10-iteration
 * cap: a model re-running the identical grep burned every step and returned
 * "ran out of steps". This nudges it at configured run lengths and otherwise
 * stays out of the way.
 *
 * Ported from dsh's repeat-tool-reminder, including the five judgements in
 * its README that are each the answer to a specific trap.
 */

describe("createRepeatGuard", () => {
  test("stays silent below the first threshold", () => {
    const guard = createRepeatGuard();

    expect(guard.observe("opentype__grep", '{"pattern":"x"}')).toBeUndefined();
    expect(guard.observe("opentype__grep", '{"pattern":"x"}')).toBeUndefined();
  });

  test("fires at the first threshold", () => {
    const guard = createRepeatGuard();

    guard.observe("opentype__grep", '{"pattern":"x"}');
    guard.observe("opentype__grep", '{"pattern":"x"}');

    expect(guard.observe("opentype__grep", '{"pattern":"x"}')).toBeDefined();
  });

  test("fires only at exactly the configured run lengths", () => {
    const guard = createRepeatGuard({ thresholds: [3, 5] });
    const fired: number[] = [];

    for (let call = 1; call <= 8; call++) {
      if (guard.observe("opentype__bash", '{"command":"ls"}') !== undefined) {
        fired.push(call);
      }
    }

    // Past the highest threshold the chain goes quiet: reminders are keyed to
    // exact counts, so a model that ignores them is not nagged forever.
    expect(fired).toEqual([3, 5]);
  });

  test("a different call resets the chain", () => {
    const guard = createRepeatGuard();

    guard.observe("opentype__grep", '{"pattern":"x"}');
    guard.observe("opentype__grep", '{"pattern":"x"}');
    guard.observe("opentype__grep", '{"pattern":"DIFFERENT"}');

    expect(guard.observe("opentype__grep", '{"pattern":"x"}')).toBeUndefined();
  });

  test("treats argument objects differing only in key order as identical", () => {
    const guard = createRepeatGuard();

    guard.observe("opentype__bash", '{"command":"ls","cwd":"/tmp"}');
    guard.observe("opentype__bash", '{"cwd":"/tmp","command":"ls"}');

    expect(guard.observe("opentype__bash", '{"command":"ls","cwd":"/tmp"}')).toBeDefined();
  });

  test("an excluded tool is TRANSPARENT to the chain, not a reset", () => {
    // The trap this closes: a bookkeeping call interleaved into a loop would
    // otherwise launder it. grep/remember/grep/remember/grep is still three
    // consecutive greps.
    const guard = createRepeatGuard({ exclude: ["opentype__remember_fact"] });

    guard.observe("opentype__grep", '{"pattern":"x"}');
    guard.observe("opentype__remember_fact", '{"content":"noted"}');
    guard.observe("opentype__grep", '{"pattern":"x"}');
    guard.observe("opentype__remember_fact", '{"content":"noted again"}');

    expect(guard.observe("opentype__grep", '{"pattern":"x"}')).toBeDefined();
  });

  test("an excluded tool never triggers a reminder about itself", () => {
    const guard = createRepeatGuard({ exclude: ["opentype__remember_fact"] });

    for (let call = 0; call < 10; call++) {
      expect(guard.observe("opentype__remember_fact", '{"content":"x"}')).toBeUndefined();
    }
  });

  test("the first reminder is a short generic nudge", () => {
    const guard = createRepeatGuard();
    guard.observe("opentype__grep", '{"pattern":"x"}');
    guard.observe("opentype__grep", '{"pattern":"x"}');

    const reminder = guard.observe("opentype__grep", '{"pattern":"x"}')!;

    expect(reminder.toLowerCase()).toContain("repeating");
    expect(reminder).not.toContain("consecutive_calls");
  });

  test("later reminders name the tool, the count and the arguments", () => {
    const guard = createRepeatGuard({ thresholds: [2, 3] });
    guard.observe("opentype__grep", '{"pattern":"needle"}');
    guard.observe("opentype__grep", '{"pattern":"needle"}');

    const reminder = guard.observe("opentype__grep", '{"pattern":"needle"}')!;

    expect(reminder).toContain("opentype__grep");
    expect(reminder).toContain("3");
    expect(reminder).toContain("needle");
  });

  test("caps the arguments PREVIEW without weakening detection", () => {
    // Detection must compare the FULL canonical string: two calls that differ
    // only past the preview cap are genuinely different calls, and treating
    // them as identical would nag a model that IS making progress.
    // [2, 3] because the FIRST threshold is the short generic nudge; the
    // arguments preview only appears from the second threshold onward.
    const guard = createRepeatGuard({ thresholds: [2, 3], argumentsPreviewChars: 50 });
    const long = (tail: string) => JSON.stringify({ command: `${"a".repeat(600)}${tail}` });

    guard.observe("opentype__bash", long("ONE"));
    expect(guard.observe("opentype__bash", long("TWO"))).toBeUndefined();

    guard.observe("opentype__bash", long("TWO"));
    const reminder = guard.observe("opentype__bash", long("TWO"))!;
    expect(reminder).toContain("truncated");
    expect(reminder.length).toBeLessThan(600);
  });

  test("chains unparseable arguments instead of crashing", () => {
    const guard = createRepeatGuard({ thresholds: [2] });

    guard.observe("opentype__bash", "not json at all");

    expect(guard.observe("opentype__bash", "not json at all")).toBeDefined();
  });

  test("keeps separate chains per guard instance", () => {
    // One guard per run: a chain must never leak between agent runs.
    const first = createRepeatGuard({ thresholds: [2] });
    const second = createRepeatGuard({ thresholds: [2] });

    first.observe("opentype__grep", "{}");
    second.observe("opentype__grep", "{}");

    expect(second.observe("opentype__grep", "{}")).toBeDefined();
    expect(first.observe("opentype__grep", "{}")).toBeDefined();
  });

  test("a reminder never replaces the tool result it follows", async () => {
    // The tool result must stay the tool's own output so the step log and any
    // audit of it remain faithful; the nudge is a separate message.
    const { runAgentLoop } = await import("../../src/agent/loop");
    const seen: unknown[][] = [];
    let call = 0;

    const result = await runAgentLoop(
      { task: "loop please" },
      {
        chat: async (messages) => {
          seen.push(messages.map((message) => ({ ...message })));
          call += 1;
          if (call > 4) {
            return { content: "giving up" };
          }
          return {
            content: null,
            toolCalls: [
              {
                id: `call-${call}`,
                type: "function",
                function: { name: "opentype__grep", arguments: '{"pattern":"x"}' },
              },
            ],
          };
        },
        tools: {
          openAiTools: [],
          callTool: async () => ({ content: "TOOL OUTPUT VERBATIM" }),
        },
        repeatGuard: createRepeatGuard({ thresholds: [3] }),
      }
    );

    expect(result.result).toBe("giving up");
    const final = seen.at(-1)!;
    const toolMessages = final.filter(
      (message) => (message as { role: string }).role === "tool"
    );
    expect(toolMessages.length).toBe(4);
    for (const message of toolMessages) {
      expect((message as { content: string }).content).toBe("TOOL OUTPUT VERBATIM");
    }
    const reminders = final.filter(
      (message) =>
        (message as { role: string }).role === "user" &&
        String((message as { content: string }).content).includes("repeating")
    );
    expect(reminders.length).toBe(1);
  });

  test("rejects a nonsensical threshold list at construction", () => {
    // Fail loud rather than silently falling back to defaults: a typo'd
    // config that quietly disables the guard is worse than no guard.
    expect(() => createRepeatGuard({ thresholds: [] })).toThrow();
    expect(() => createRepeatGuard({ thresholds: [1] })).toThrow();
    expect(() => createRepeatGuard({ thresholds: [3, 3] })).toThrow();
    expect(() => createRepeatGuard({ argumentsPreviewChars: 0 })).toThrow();
  });
});
