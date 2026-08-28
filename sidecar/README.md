# OpenType sidecar

A local TypeScript/Bun HTTP server (over a Unix socket) that owns everything
the macOS app doesn't do itself: text generation (DeepSeek by default, or a
user-configured Anthropic/OpenAI-compatible provider — see `src/provider/`),
ASR (local MLX-Whisper by default, or a user-configured remote provider —
see `src/asr/`), and the long-term memory/entity-dictionary store. The Swift
app (`Sources/OpenType/SidecarClient.swift`) spawns this as a child process
and talks to it exclusively over `curl` against the socket — see the repo
root `CLAUDE.md` for how this fits into the overall macOS architecture.

## Run it standalone

```bash
cd sidecar
bun install
bun run src/server.ts     # same as `bun run dev`
```

By default it listens on `/tmp/opentype-sidecar-dev.sock` and reads/writes
its SQLite DB at `sidecar/.data/opentype.sqlite3`. Useful env vars (see
`src/env.ts` for the full list and defaults):

- `DEEPSEEK_API_KEY` — required for `/oneshot/ask` and `/agent/run` to
  actually produce text; without it, DeepSeek calls fail at request time
  (the server still starts and `/health` still responds).
- `DEEPSEEK_MODEL` / `DEEPSEEK_BASE_URL` — override the default
  `deepseek-v4-flash` model / `https://api.deepseek.com`.
- `OPENTYPE_SIDECAR_SOCKET` — override the Unix socket path.
- `OPENTYPE_SIDECAR_DB_PATH` — override the SQLite DB path.
- `OPENTYPE_MCP_SERVERS` — JSON config for Agent-mode MCP tool servers (see
  `src/agent/mcpClient.ts`); omit to run Agent mode with no MCP servers
  connected (the built-in tools are always available regardless). Since
  P2-13 this is only the **zero-config dev fallback**: the saved config in
  `mcp-servers.json` (written through `/config/mcp`, see `src/agent/
  mcpConfigStore.ts`) wins whenever the user has ever saved anything, and
  wins entirely — env servers are never merged in, so removing your last
  saved server means "no MCP servers" rather than silently reinstating
  these. An env var alone never reports as configured.
- `OPENTYPE_WHISPER_PYTHON_BIN` / `OPENTYPE_WHISPER_SCRIPT_PATH` — override
  the MLX-Whisper python interpreter/script path; only needed for the
  packaged app (dev mode uses the relative `whisper-env/`/`whisper/`
  checked into this directory as-is).
- `OPENTYPE_AGENT_APPROVAL` — `"yolo"` (default) or `"prompt"`. Controls
  whether `/agent/run` prompts before running a destructive shell/python call
  (`rm`, `git reset --hard`, etc. — see `src/agent/commandRisk.ts`). The
  owner's explicit product stance (usability over safety —
  `docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md`
  §0) is `yolo`: no prompting, ever, by default. `prompt` restores the
  previous always-prompt-on-destructive behavior. Any unrecognised value
  falls back to `yolo`, not `prompt`.
- `OPENTYPE_SKILLS_DIR` — override the built-in skill root (see "Skills"
  below); mainly useful for pointing a dev server at a different skill
  directory without touching the bundled `sidecar/skills/`. Does not affect
  the other two skill roots (`~/.opentype/skills`, `~/.claude/skills`),
  which are never overridable — see `src/skills/skillRoots.ts`. A packaged
  `.app` launch sets this automatically (`SidecarClient.swift`'s
  `bundledSkillsAndAgentsEnvironment`, pointed at the `Contents/Resources/skills`
  `build-app.sh` bundles) — `import.meta.dir`, which is what the built-in
  default without this override resolves against, points into a
  `bun build --compile` binary's embedded virtual filesystem rather than a
  real directory beside it, so without this the packaged app would find zero
  built-in skills.
- `OPENTYPE_AGENTS_DIR` — override the built-in agent-definition root (see
  "Agent definitions" below); same purpose and same caveat as
  `OPENTYPE_SKILLS_DIR` above — only the built-in root moves, the other two
  agent roots (`~/.opentype/agents`, `~/.claude/agents`) are never
  overridable, and it has no effect on the (separate, shorter) root list
  `AGENTS.md` global instructions use — see `src/agent/agentRoots.ts`. Also
  set automatically for a packaged launch, same mechanism as
  `OPENTYPE_SKILLS_DIR` above.

## Test

```bash
cd sidecar
bun test
```

## Build the bundled binary

```bash
cd sidecar
bun run build   # -> dist/opentype-sidecar, a standalone compiled binary
```

`scripts/build-app.sh` (repo root) does this as part of assembling
`dist/OpenType.app`; you shouldn't normally need to run it by hand unless
you're debugging packaging specifically.

## Layout

- `src/server.ts` — process entry point; wires up the DB, DeepSeek client,
  MCP tools, and local Whisper process, then starts `Bun.serve`.
- `src/router.ts` — tiny method+path router used by `buildApp`.
- `src/oneshot/` — `/oneshot/ask` (the "Ask" mode's system prompt, one-shot
  LLM call via the resolved provider — DeepSeek by default, or the
  user-configured provider — and light memory-context injection). Memory
  context is assembled by `memoryContext.ts` (`buildKnownTermsContext`:
  entity terms mentioned in the input, plus **all** owner-origin owner_facts
  unconditionally — see the memory note below) and its usage is logged to a
  local file by `contextDebugLog.ts` (see `OPENTYPE_CONTEXT_LOG_PATH`).
- `src/agent/` — `/agent/run` (the Agent mode's tool-calling loop —
  `loop.ts` — and MCP client — `mcpClient.ts`). `coreTools.ts` supplies the
  built-in "hands and feet" toolset (shell, Python, file read/list/search,
  web search/fetch, `open_file`) plus, since the 2026-08-28 first-party-tools
  batch (design §2), five file-write tools: `write_file`, `edit_file`
  (exact-string find/replace), `move_file` (never silently overwrites an
  existing destination), `trash` (moves into `~/.Trash` instead of deleting,
  with sequential ` 2`/` 3`/... suffixes on a name collision rather than
  clobbering what's already there), and `glob` (recursive filename search,
  skipping `.git`/`node_modules`/`Library`/dot-directories, capped by the
  exported `GLOB_DEFAULT_LIMIT`, 200). `approval.ts` is the approval seam
  those tool calls flow through (`withApproval`); which policy `/agent/run`
  applies per run — auto-allow (`yoloApprovalPolicy`, the default) or the
  human-prompting one (`createPromptingApprovalPolicy`, gated on
  `classifyCommandRisk` in `commandRisk.ts`) — is controlled by
  `OPENTYPE_AGENT_APPROVAL` (see above; design §2.1). `builtInTools.ts`
  supplies two **always-available** built-in tools (`remember_fact`,
  `consolidate_memory_now`); `toolSets.ts` merges them with `coreTools.ts`
  and any connected MCP tools, so Agent mode can always call at least those
  two even with no MCP server configured. `mcpConfigStore.ts` persists the
  user's MCP servers
  (`mcp-servers.json`, next to the SQLite DB, `0600`, same atomic-write /
  self-healing conventions as `provider/configStore.ts` — and the same
  documented plaintext tradeoff, since a server's `env`/`headers` routinely
  carry real tokens) and owns the saved-beats-env precedence
  (`resolveMcpServers`); `mcpConfigRoutes.ts` is the HTTP surface over it:
  `GET /config/mcp` (list, `{configured, source, servers}` — secrets only
  ever as `envMasked`/`headersMasked`), `POST /config/mcp` (create),
  `PUT /config/mcp/:name` (replace, not patch), `DELETE /config/mcp/:name`,
  and `POST /config/mcp/test` (connect a candidate, report the tools it
  exposes, save nothing). On a write, a submitted secret equal to the mask of
  the stored value for that same server+key means "unchanged" — resolution is
  scoped to the addressed server and to that one key, never a search across
  the config, which would make the mask a read primitive for other servers'
  credentials. Connections are established at boot, so a saved change applies
  from the next sidecar start. `agentDefinitions.ts` + `agentRoots.ts` are
  the Agent-definitions subsystem (design §4,
  `docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md`)
  — see "Agent definitions" below — which is what lets `POST /agent/run`
  take an optional `agentName` (an unknown one is a 400) and adds
  `GET /agent/definitions`.
- `src/resources/` — `frontmatter.ts` (small hand-rolled parser for the
  `---\nkey: value\n---\n<body>` block `SKILL.md`/agent `.md` files use — no
  YAML dependency added) and `resourceStore.ts` (generic multi-root
  discovery: ordered roots, first-root-wins on a name collision, a missing
  root skipped silently, a short injectable-clock TTL cache in place of
  file-watching hot reload). Shared machinery, not skill-specific — see its
  own doc comment for the `layout: "directory" | "file"` split between a
  skill (a directory containing a marker file) and an agent definition (a
  flat `<name>.md`).
- `src/skills/` — the Skill subsystem (first-party tools/skills/agents
  design §3,
  `docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md`):
  a skill is a directory containing `SKILL.md` with `name`/`description`
  frontmatter and a Markdown procedure body — the exact format Claude Code
  uses, so an existing Claude Code skill directory works here unmodified.
  `skillRoots.ts` resolves the three-root discovery order (see "Skills"
  below); `skillStore.ts` (`createSkillStore`) does the actual TTL-cached
  discovery on top of `resourceStore.ts`, plus `renderSkillIndex` (the
  always-resident `name: description` index injected into every `/agent/run`
  call, clamped to 40 entries / ~4000 chars with a visible truncation
  notice); `skillTool.ts` is `opentype__load_skill`, the tool that expands
  one index entry into its full `SKILL.md` body on demand (progressive
  disclosure — the index alone costs ~200 tokens unused). Ask mode never
  sees this tool or the index: its toolset is a fixed web-only allowlist.
- `src/asr/` — `/asr/transcribe`; proxies to the persistent local
  MLX-Whisper python process (`whisper/serve.py`) over its own Unix socket.
  `dictionaryBias.ts` feeds the entity dictionary back into recognition from
  this one place: `buildInitialPrompt` biases the local decoder toward known
  canonical spellings via `initial_prompt` (sent as a percent-encoded query
  parameter, since headers must be latin-1 safe and the terms are routinely
  CJK), and `applyAliasCorrections` rewrites known alias → canonical in the
  transcript afterwards — the latter on both the local and remote backends,
  since a remote provider never sees our prompt.
- `src/memory/` — the entity-dictionary + owner-facts `MemoryStore`
  (SQLite-backed), consolidation (`consolidator.ts`), and the memory HTTP
  routes: read-only `GET /memory/terms` / `GET /memory/consolidation-runs`,
  the write endpoint `POST /memory/consolidate-now` (runs consolidation
  immediately, same code path as the `consolidate_memory_now` agent tool),
  and owner-facts management `GET /memory/owner-facts` /
  `PATCH /memory/owner-facts/:id` / `DELETE /memory/owner-facts/:id`. The
  `PATCH` is "the user read this and vouches for it": it promotes the fact's
  `origin` to `owner` and takes no arguments beyond the id, so it can only ever
  move provenance one way — a body naming any other origin is a 400, not a
  demotion. Without it, the panel's only answer to a flagged-but-correct fact
  was to delete it, and a provenance flag the user can never clear is noise
  they learn to ignore. `startupConsolidation.ts` is the
  `shouldConsolidate` gate's automatic caller (P1-7): `main()` arms one check
  5 minutes after the server starts serving, and if the gate opens (≥12h since
  the last run, ≥5 unconsolidated events) it runs one pass. One check per
  launch, never two at once, and any failure is logged and swallowed. The
  route + agent tool above still force a pass regardless of the gate. Its raw
  material is the `episodic_events` table, which `/agent/run`,
  `/asr/transcribe` and `/oneshot/ask` all append to (best-effort — a memory
  write must never fail the request that produced it) — **but `transcribe`
  rows are recorded only, never consolidated**: "plain dictation never reaches
  an LLM" is a product promise and consolidation is a real model call, so the
  exclusion (`CONSOLIDATION_EXCLUDED_MODES`) is enforced in
  `MemoryStore.consolidationCandidates()`, the single selection query, rather
  than in the prompt builder. The gate counts `consolidationCandidateCount()`
  (eligible rows only) so excluded material can't hold it permanently open.
  Also
  `conversations.ts`/`conversationRoutes.ts` — a separate `conversations`/
  `conversation_messages` table pair (same SQLite file, different concern:
  turn-by-turn chat history, not a fact/term store) backing the macOS Q&A/
  Agent tabs' multi-turn continuation via `GET /conversations?kind=ask|agent`
  and `GET /conversations/:id`, and an optional `conversationId` accepted by
  `/oneshot/ask` and `/agent/run` to continue a specific thread.
- `src/transcribe/` — `POST /transcribe/correct`, backing macOS's Review
  transcribe-mode: takes the full current text, a UTF-16 offset selection
  range, and a spoken correction instruction, returns the replacement for
  that span (the caller splices it back in by offset). Takes an **optional**
  `MemoryStore` — without it this is the same pure correction logic it has
  always been; with it (as `server.ts` wires it), a correction that looks
  like a term fix rather than a prose rewrite is also learned into
  `entity_terms` as `alias → canonicalTerm` and echoed back as `learned`, so
  the next transcription gets that term right. `learnCorrection.ts` is the
  pure gate deciding which corrections qualify; learning is best-effort and
  can never fail the correction itself.
- `src/provider/` — the LLM provider abstraction: `deepseek.ts` (the
  original, still-used env-based zero-config default client),
  `openaiCompatible.ts`/`anthropic.ts` (the two provider types a user can
  explicitly configure), `registry.ts` (dispatches by type),
  `configStore.ts` (persists the saved Whisper/LLM config as local plaintext
  JSON), and `routes.ts` (the `/config/*` HTTP surface Settings and the
  onboarding wizard call). See
  `docs/superpowers/specs/2026-08-09-current-system-state.md` §10 for the
  full design and why plaintext-JSON over Keychain.
- `src/asr/` also has `remoteWhisperClient.ts` — the remote-Whisper backend
  (OpenAI's `/audio/transcriptions` shape) an explicitly-configured Whisper
  provider routes through instead of the local process below.
- `whisper/serve.py` + `whisper-env/` — the local MLX-Whisper python server
  and its bundled virtualenv (still the default ASR backend).

See `docs/superpowers/specs/2026-08-09-current-system-state.md` for the
full as-built system description (all endpoints, request/response shapes,
and known gaps) and `docs/superpowers/specs/` more broadly for how this
design evolved.

## Skills

Agent-mode-only (design §3,
`docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md`).
A skill is a directory containing `SKILL.md`:

```
sidecar/skills/organize-files/SKILL.md
---
name: organize-files
description: Use when the user asks to tidy up, sort, or archive a folder
---
(procedure body, written for the model)
```

This is the Claude Code skill format, unmodified — no private extensions —
so an existing Claude Code skill directory can be dropped in and used as-is.

Three roots are searched, in order, first root wins a name collision (the
same directory name across roots is fine; what collides is the frontmatter
`name`):

1. **Built-in** — the `sidecar/skills/` directory bundled with this repo
   (six shipped skills: `find-and-open`, `organize-files`,
   `meeting-notes-to-todos`, `data-analysis`, `document-summary`,
   `draft-message`). Overridable via `OPENTYPE_SKILLS_DIR` (see above).
2. **User** — `~/.opentype/skills/`, this product's own writable per-user
   skill directory.
3. **Compat** — `~/.claude/skills/`, read-only, always last. This is never
   written to and can never shadow a built-in or user skill of the same
   name — a skill written for Claude Code should just work here, but it
   should never silently override something OpenType-owned.

Discovery is re-read from disk with a short (5s) TTL cache rather than
watched for changes (design §5's deliberate "no hot reload" call) — editing
a `SKILL.md` file takes effect on the next `/agent/run` call, no restart
needed, typically within a few seconds.

Only an always-resident **index** (`name: description`, one line per skill,
clamped to 40 entries / ~4000 chars with a visible truncation notice if it
overflows) reaches the model on every Agent-mode request; the full
`SKILL.md` body only reaches it if the model calls `opentype__load_skill`
with that skill's name. Ask mode never sees either — its toolset is a fixed
web-only allowlist that doesn't include `load_skill`.

## Agent definitions

Agent-mode-only (design §4,
`docs/superpowers/specs/2026-08-28-first-party-tools-skills-and-agents-design.md`).
An agent definition is a single Claude-Code-compatible subagent file —
`<name>.md`, no directory, no marker file:

```
sidecar/agents/writer.md
---
name: writer
description: Writes warm, concise emails and messages
tools: read_file, write_file
model: opus
---
(system-prompt body)
```

`tools` (comma-separated, optional) narrows what this agent's run can call —
accepts our own bare/prefixed names (`bash`, `opentype__bash`) and Claude
Code's capitalised convention (`Read`, `Bash`) interchangeably, so a file
copied straight from Claude Code doesn't need editing. `model` is parsed but
deliberately **ignored** — this product has exactly one, globally-configured
LLM provider; per-agent model switching is out of scope for this batch. An
unrecognised frontmatter field never fails the whole file to load.

A `README.md` sitting directly in an agent-definition root (e.g. the
built-in `sidecar/agents/README.md` placeholder below) never registers as an
entry — `resourceStore.ts`'s `"file"`-layout discovery excludes any file
named `README.md` (case-insensitively), by the file's own name, regardless
of what's inside it. A README documenting the format of a directory of
definitions is a convention, not a definition; without this exclusion a
user's own `~/.opentype/agents/README.md` would silently become a callable
agent named "README" running its own prose as a system prompt. This applies
only to the `"file"` layout (agent definitions) — Skills' `"directory"`
layout never enumerates loose files inside a skill directory at all, so a
`README.md` next to a `SKILL.md` was never at risk.

Discovery uses the same three-root, first-root-wins, 5s-TTL machinery as
Skills above (`src/resources/resourceStore.ts`'s `layout: "file"` mode, see
`src/agent/agentRoots.ts`'s `resolveAgentRoots`):

1. **Built-in** — `sidecar/agents/` (ships empty; see that directory's own
   `README.md`). Overridable via `OPENTYPE_AGENTS_DIR` (see above).
2. **User** — `~/.opentype/agents/`.
3. **Compat** — `~/.claude/agents/`, read-only, always last.

**Selecting an agent** (design §4.4) has two paths:

- **Voice prefix** (zero UI, the primary path) — the task's own leading text
  addresses an agent by `name` or its optional `displayName` alias:
  `用<name>` / `使用<name>` / `让<name>` / `叫<name>` / `<name>，` / `@<name>`,
  case- and whitespace-insensitive. A match strips that leading address off
  before the rest of the task ever reaches the model; a name appearing
  mid-sentence or at the end (a mention, not an address) never matches.
- **Explicit `agentName`** on the `POST /agent/run` body — takes precedence
  over any voice prefix. An unrecognised name is a 400 with that name in the
  message. The task's own prefix is still stripped if (and only if) it
  addresses that same, explicitly-named agent — never a different one.

A selected agent's system prompt is `AGENT_SYSTEM_PROMPT` (the harness's own
base prompt, including its UNTRUSTED-data defense) with the agent's own
body **appended**, never substituted — a user-authored `.md` file cannot
turn off the base prompt's own defenses no matter what it says. `tools`
narrows the tool set the same run sees, applied before the per-run
`ask_user` tool is added in, so an agent's allowlist can never remove that
harness-level escape hatch. `GET /agent/definitions` lists every discovered
agent's name/description/source-root/tools for a future UI or for debugging.

**`AGENTS.md` global instructions** (design §4.5) are a separate, unnamed,
always-on mechanism: any root's `AGENTS.md`, if present, is appended after
the agent body (or directly after the base prompt, if no agent was
selected) — every root that has one, in root order, not first-root-wins.
Crucially, this uses a **different, shorter** root list than agent discovery
above (`resolveGlobalInstructionRoots`, `src/agent/agentRoots.ts`): built-in
+ `~/.opentype` only — **`~/.claude` is deliberately excluded**. An agent or
skill imported from `~/.claude` is opt-in (the model has to name it before
it matters), but `AGENTS.md` is unnamed and always-on; including
`~/.claude/AGENTS.md` here would silently inject the user's *coding*
instructions (written for Claude Code) into every voice-dictation task. Same
directory tree, two different consent models.
