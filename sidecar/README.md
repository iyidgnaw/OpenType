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
  `src/agent/mcpClient.ts`); omit to run Agent mode with no tools connected.
- `OPENTYPE_WHISPER_PYTHON_BIN` / `OPENTYPE_WHISPER_SCRIPT_PATH` — override
  the MLX-Whisper python interpreter/script path; only needed for the
  packaged app (dev mode uses the relative `whisper-env/`/`whisper/`
  checked into this directory as-is).

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
  `loop.ts` — and MCP client — `mcpClient.ts`). `builtInTools.ts` supplies
  two **always-available** built-in tools (`remember_fact`,
  `consolidate_memory_now`); `toolSets.ts` merges them with any connected MCP
  tools, so Agent mode can always call at least those two even with no MCP
  server configured.
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
  `DELETE /memory/owner-facts/:id`. `startupConsolidation.ts` is the
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
