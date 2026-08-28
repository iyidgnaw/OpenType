# Built-in agent definitions

This directory is the built-in root `resolveAgentRoots` resolves first (see
`sidecar/src/agent/agentRoots.ts`), and the built-in root
`resolveGlobalInstructionRoots` also reads an optional `AGENTS.md` from.

It ships empty on purpose (first-party tools/skills/agents design §7,
`docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md`):
this batch's specialised, voice-triggered behavior is carried by the six
built-in *skills* (`sidecar/skills/`), not by shipped agent personas -- named
agents are an extension point for the user to drop their own `<name>.md`
files into (here, `~/.opentype/agents/`, or a `~/.claude/agents/` directory
already written for Claude Code), not a product-owned feature set.

Drop a Claude-Code-compatible subagent file here to ship one as a built-in:

```
sidecar/agents/writer.md
---
name: writer
description: Writes warm, concise emails and messages
tools: read_file, write_file
---
(system-prompt body)
```

`OPENTYPE_AGENTS_DIR` overrides this root entirely (see `sidecar/README.md`).
