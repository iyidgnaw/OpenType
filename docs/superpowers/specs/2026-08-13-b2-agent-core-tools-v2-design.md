# OpenType redesign: B2 Agent core tools v2 (YOLO mode)

Status: approved design (product owner decisions, 2026-08-13 session).
Supersedes the safety boundary in
`docs/superpowers/specs/2026-08-09-b2-agent-runtime-v1-design.md` §1.

## 0. What changed and why

v1 shipped an agent runtime with a sound tool-calling loop but almost no
tools: two built-in memory tools (`opentype__remember_fact`,
`opentype__consolidate_memory_now`) plus whatever MCP servers the user
wires up by hand via `OPENTYPE_MCP_SERVERS` (no UI). Out of the box the
agent has no "hands and feet" — it cannot read a file, run a command, or
touch the network.

The owner's decision: give the agent the same baseline toolset general
coding agents (Claude Code, Codex, OpenCode, Pi) converge on — shell,
Python, file read/search, and internet (search + fetch) — as **product-owned
built-in tools**, not MCP. The v1 "no-side-effect tools only" policy is
explicitly retired.

## 1. Safety posture: YOLO by default, approval as a seam

- **No sandbox. No pre-execution confirmation.** Default mode is YOLO
  (百无禁忌): every tool call is auto-approved and runs immediately. This
  is a deliberate, owner-accepted local risk for a single-user,
  self-configured tool.
- **The approval point is built now, as architecture only**: every tool
  call (core, built-in memory, and MCP alike) flows through an
  `ApprovalPolicy` seam. v2 ships exactly one policy — always-allow
  (`yoloApprovalPolicy`). A later version can swap in a user-prompting
  policy (popup/notification + approve/deny) without restructuring;
  a denial surfaces to the model as a tool-error result, never a crash.
- The final answer remains **draft-only** (clipboard, never auto-sent) —
  unchanged. What v2 gives up is the pretense that tool *calls* are
  side-effect-free; the delivery invariant stays.

## 2. Working directory and file-location defaults

- Default working directory for `bash`/`python`, and default scope for
  file tools, is **`~` (the user's home directory)**.
- The system prompt instructs the agent: when the user refers to files
  without saying where, **look in `~/Desktop` and `~/Downloads` first**.
- `~`-prefixed paths are expanded in every core tool that takes a path.

## 3. Tool inventory (all namespaced `opentype__`, all built-in)

New module `sidecar/src/agent/coreTools.ts`, same `ToolSet` shape as
`builtInTools.ts`, merged in `server.ts` via the existing
`mergeToolSets`:

| Tool | Args | Behavior |
|---|---|---|
| `opentype__bash` | `command`, `cwd?` | `/bin/bash -lc`, cwd defaults to home, ~60s timeout, returns merged stdout+stderr plus exit code |
| `opentype__python` | `code`, `cwd?` | writes code to a temp file, runs `python3` from PATH, same timeout/output semantics as bash |
| `opentype__read_file` | `path` | returns file text (clamped) |
| `opentype__list_dir` | `path?` | defaults to `~`; entries with directory markers |
| `opentype__grep` | `pattern`, `path?`, `caseInsensitive?` | recursive text search (system `grep -rn -I`); **path defaults to `~/Desktop` + `~/Downloads`**, not all of `~` (recursive grep over the whole home dir is pathologically slow — the model passes an explicit path for anything else) |
| `opentype__web_search` | `query` | DuckDuckGo HTML endpoint scrape, top ~8 results as title/url/snippet (no API key required) |
| `opentype__web_fetch` | `url` | GET with redirects, HTML stripped to readable text, clamped |

Notes:
- Long output is clamped at the source (before the loop's existing 20k
  `clampToolResult`) so a runaway `cat` can't build a multi-MB string.
- `createCoreTools(deps)` takes injectable deps (home dir, fetch fn) so
  tests don't depend on the real network or the real home directory;
  process execution tests use real `bash`/`python3` with trivial commands.

## 4. Approval seam shape

New module `sidecar/src/agent/approval.ts`:

```ts
type ApprovalDecision = { allowed: true } | { allowed: false; reason: string };
interface ApprovalPolicy { approve(toolName: string, args: unknown): Promise<ApprovalDecision>; }
const yoloApprovalPolicy: ApprovalPolicy; // always { allowed: true }
function withApproval(tools: ToolSet, policy: ApprovalPolicy): ToolSet;
```

`server.ts` wraps the *merged* tool set, so MCP and built-in memory tools
pass through the same gate:
`withApproval(mergeToolSets(builtInTools, coreTools, mcpTools), yoloApprovalPolicy)`.

## 5. Prompt changes

`AGENT_SYSTEM_PROMPT` (`sidecar/src/oneshot/prompts.ts`) is updated to:

- Drop the "only no-side-effect tools are expected here" sentence.
- Describe the real capabilities (shell, Python, files, grep, web search
  and browsing) and that the default working directory is the user's home.
- Add the Desktop/Downloads-first guidance from §2.
- **Keep unchanged**: the treat-tool-output-and-context-as-untrusted-data
  paragraph (prompt-injection defense matters *more* with bash available,
  not less), the draft-only framing, and the memory-tools paragraph.

## 6. Unchanged / deferred

- Iteration cap stays at 10; revisit if real tasks hit it.
- No configuration UI for any of this; no per-tool enable/disable.
- The user-prompting approval policy (popup + approve) is the named next
  step for the approval seam, not part of v2.
- MCP config remains env-var-only (`OPENTYPE_MCP_SERVERS`).
