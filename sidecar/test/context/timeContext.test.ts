import { describe, expect, test } from "bun:test";
import { buildTimeContext } from "../../src/context/timeContext";

/**
 * T4 of the dsh-borrowings plan
 * (docs/superpowers/specs/2026-08-13-dsh-borrowings-plan.md §6).
 *
 * The product is voice input, so the model is constantly handed relative
 * time ("明天", "刚才", "这周", "下周三") with no anchor whatsoever. These
 * tests pin the anchor's exact rendered shape, because that string reaches
 * the model verbatim (docs/model-context-inventory.md).
 */
describe("buildTimeContext", () => {
  const fixed = new Date("2026-08-13T15:20:15Z");

  test("renders date, offset, IANA zone and weekday for an explicit zone", () => {
    const line = buildTimeContext(fixed, "Asia/Shanghai");

    // 2026-08-13T15:20:15Z is 2026-08-13 23:20:15 +08:00, a Thursday.
    expect(line).toContain("2026-08-13");
    expect(line).toContain("23:20:15");
    expect(line).toContain("+08:00");
    expect(line).toContain("Asia/Shanghai");
    expect(line).toContain("Thursday");
  });

  test("resolves the same instant into a different zone's local date", () => {
    // Los Angeles is 2026-08-13 08:20:15 -07:00 — same instant, and still
    // Thursday, so use a zone where the DATE itself differs to prove the
    // rendering is zone-local rather than UTC with a label pasted on.
    const line = buildTimeContext(new Date("2026-08-13T20:30:00Z"), "Pacific/Auckland");

    // 2026-08-13T20:30:00Z is 2026-08-14 08:30 +12:00 in Auckland: next day.
    expect(line).toContain("2026-08-14");
    expect(line).toContain("+12:00");
    expect(line).toContain("Friday");
  });

  test("appends an ask-the-user instruction when the zone cannot be resolved", () => {
    const line = buildTimeContext(fixed, "Not/AZone");

    expect(line.toLowerCase()).toContain("could not be determined");
    expect(line.toLowerCase()).toContain("ask the user");
  });

  test("still reports a usable timestamp when the zone is unresolvable", () => {
    // Degrading to "no time at all" would be worse than degrading to UTC:
    // the model can still order events, it just must not assume the user's
    // local calendar day.
    const line = buildTimeContext(fixed, "Not/AZone");

    expect(line).toContain("2026-08-13");
    expect(line).toContain("Current time:");
  });

  test("is deterministic for a fixed instant and zone", () => {
    expect(buildTimeContext(fixed, "Asia/Shanghai")).toBe(
      buildTimeContext(fixed, "Asia/Shanghai")
    );
  });

  test("defaults to the ambient zone when none is supplied", () => {
    // Not asserting WHICH zone (that depends on the host), only that the
    // omitted-argument form still produces a complete, non-degraded line.
    const line = buildTimeContext(fixed);

    expect(line).toContain("Current time:");
    expect(line).toContain("2026-08-1");
    expect(line.toLowerCase()).not.toContain("could not be determined");
  });
});
