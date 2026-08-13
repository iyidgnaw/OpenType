import { describe, expect, test } from "bun:test";
import { AGENT_SYSTEM_PROMPT, ASK_SYSTEM_PROMPT } from "../../src/oneshot/prompts";

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

/**
 * B2 core tools v2 prompt changes
 * (docs/superpowers/specs/2026-08-13-b2-agent-core-tools-v2-design.md §5):
 * the v1 "no-side-effect tools only" framing is retired, the prompt now
 * describes real capabilities with the home directory as the default working
 * location and Desktop/Downloads-first file guidance -- while the
 * prompt-injection-defense (UNTRUSTED) paragraph and the memory-tools
 * paragraph must survive unchanged.
 */
describe("AGENT_SYSTEM_PROMPT (core tools v2)", () => {
  test("no longer claims only side-effect-free tools are connected", () => {
    expect(AGENT_SYSTEM_PROMPT).not.toContain("no side effects");
  });

  test("names the home directory as the default working location", () => {
    // Contract: the implementation is expected to include the literal phrase
    // "home directory" when describing where the agent works by default.
    expect(AGENT_SYSTEM_PROMPT).toContain("home directory");
  });

  test("tells the agent to look in Desktop and Downloads first for unlocated files", () => {
    expect(AGENT_SYSTEM_PROMPT).toContain("Desktop");
    expect(AGENT_SYSTEM_PROMPT).toContain("Downloads");
  });

  test("keeps the prompt-injection defense (UNTRUSTED) and the memory-tools guidance", () => {
    expect(AGENT_SYSTEM_PROMPT).toContain("UNTRUSTED");
    expect(AGENT_SYSTEM_PROMPT).toContain("remember_fact");
  });
});

/**
 * B2 open-file + ask-web prompt changes
 * (docs/superpowers/specs/2026-08-13-b2-open-file-and-ask-web-design.md):
 * §1 -- AGENT_SYSTEM_PROMPT gains open_file guidance: when the user asks to
 * open, preview, play, or "看一下" a file, the agent should find it and call
 * `opentype__open_file` -- opening it for the user IS the requested outcome,
 * not just reporting the path.
 * §2 -- the ask prompt gains web-capability guidance, and (new contract) the
 * UNTRUSTED-data defense: checked 2026-08-13, the current ASK_SYSTEM_PROMPT
 * has NO untrusted-data paragraph at all, and once Ask can fetch arbitrary
 * web pages that content is prompt-injection surface #1, so the defense is
 * added rather than preserved.
 */
describe("AGENT_SYSTEM_PROMPT (open_file, open-file design §1)", () => {
  test("tells the agent to call open_file to open/preview/play files for the user, not just report the path", () => {
    expect(AGENT_SYSTEM_PROMPT).toContain("open_file");
    expect(AGENT_SYSTEM_PROMPT).toMatch(/preview|play/i);
  });
});

describe("ASK_SYSTEM_PROMPT (web, ask-web design §2)", () => {
  test("mentions the web search capability", () => {
    expect(ASK_SYSTEM_PROMPT).toMatch(/web/i);
    expect(ASK_SYSTEM_PROMPT).toMatch(/search/i);
  });

  test("treats web content as UNTRUSTED data (prompt-injection defense)", () => {
    expect(ASK_SYSTEM_PROMPT).toContain("UNTRUSTED");
  });

  test("still frames Ask as the one mode that answers the question directly", () => {
    // Guard, green before and after: the web extension must not displace the
    // mode's identity as a direct, concise answerer.
    expect(ASK_SYSTEM_PROMPT).toMatch(/answer/i);
  });
});
