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
  DeepSeek call, and light memory-term context injection).
- `src/agent/` — `/agent/run` (the Agent mode's tool-calling loop —
  `loop.ts` — and MCP client — `mcpClient.ts`).
- `src/asr/` — `/asr/transcribe`; proxies to the persistent local
  MLX-Whisper python process (`whisper/serve.py`) over its own Unix socket.
- `src/memory/` — the entity-dictionary `MemoryStore` (SQLite-backed),
  periodic consolidation (`consolidator.ts`), and the read-only
  `/memory/terms` / `/memory/consolidation-runs` endpoints.
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
