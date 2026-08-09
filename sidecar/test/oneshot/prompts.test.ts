import { describe, expect, test } from "bun:test";
import { AGENT_SYSTEM_PROMPT } from "../../src/oneshot/prompts";

describe("AGENT_SYSTEM_PROMPT", () => {
  test("tells the model when to call remember_fact, including the Chinese 记住 trigger", () => {
    expect(AGENT_SYSTEM_PROMPT).toContain("remember_fact");
    expect(AGENT_SYSTEM_PROMPT).toContain("记住");
  });

  test("tells the model when to call consolidate_memory_now, including a Chinese trigger", () => {
    expect(AGENT_SYSTEM_PROMPT).toContain("consolidate_memory_now");
    expect(AGENT_SYSTEM_PROMPT).toMatch(/整理|回顾/);
  });
});
