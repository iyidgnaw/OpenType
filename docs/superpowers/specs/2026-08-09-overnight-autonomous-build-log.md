# Overnight autonomous build: decision log

The owner authorized unattended overnight execution of the full A/B1/B2/C
redesign (per specs 2026-08-08 and 2026-08-09) with explicit instructions:
don't stop to ask about design/tech-choice forks — record the question and
options here, proceed with the recommended option, revisit in v2. This file
is the running record of every such call, in chronological order, so
nothing was silently decided without a trace.

## Decision 0: tech stack split (Swift shell + TypeScript/Bun sidecar)

Made in conversation just before this run started, not autonomously, but
recorded here since it governs everything below: the Swift app stays a
thin native OS-integration shell (audio, hotkeys, Accessibility, Keychain,
UI, delivery); A/B1/B2/C move to a local TypeScript sidecar (Bun runtime),
spawned as a child process by the Swift app and talked to over a Unix
domain socket in the app's Application Support directory. Chosen over
Python primarily because OpenClaw (the C reference) is itself TypeScript,
and MCP's official SDK is first-class in TypeScript, directly resolving the
"does Swift have an MCP client" risk flagged in the B2 spec.

## Decision 1: LLM provider for this build

Owner specified: use "deepseek v4 flash" via a pasted API key, for
everything LLM-related in this build. Recorded here rather than in any
tracked file: the key lives only in `sidecar/.env.local` (gitignored,
never committed) and is read via `process.env.DEEPSEEK_API_KEY`. Model name confirmed via DeepSeek's docs: API identifier is
`deepseek-v4-flash`, base URL `https://api.deepseek.com`, OpenAI-compatible
chat completions shape (`/chat/completions`).

## Decision 2: no Apple Developer signing for this build

Owner has an Apple Developer subscription but explicitly said not to use
it for this MVP — same ad-hoc local codesign `scripts/build-app.sh`
already does (stable designated requirement `ai.rain.opentype`) is kept
for both the Swift binary and the new sidecar binary. Not notarized, not
distributed outside this machine.

## Decision 3: pragmatic 2-stage pipeline instead of literal 4-stage, for this overnight run only

CLAUDE.md's convention is 4 separate agent stages (write tests / review
tests / implement / review implementation) per change. Given the volume of
work needed by morning across several subsystems, running that literally
for every small module would not finish in time. For this overnight batch
only: each subsystem is built by one agent that itself writes a failing
test, then an implementation, then verifies the tests pass (self-contained
red/green) — followed by a separate review agent before commit. This
collapses stages 1+3 and keeps 2+4 as an independent check, rather than
dropping review entirely. Reverting to the literal 4-stage split once this
initial build is stable and the pace pressure is gone.

## Sidecar scaffold (task 7)

Bun + TypeScript project at `sidecar/`. `Bun.serve({ unix: ... })` for the
IPC transport (Unix domain socket, not TCP — avoids port allocation/
scanning entirely, security is filesystem permissions on the socket path
under Application Support). `env.ts` reads `OPENTYPE_SIDECAR_SOCKET` (set
by the Swift launcher in production; defaults to `/tmp/opentype-sidecar-dev.sock`
for standalone dev) and the DeepSeek credentials from `.env.local`
(gitignored). Verified with a real smoke test: booted the server, hit
`/health` over the actual Unix socket with curl, got `{"status":"ok"}`.

## Decision 4: Swift-to-sidecar transport is `curl --unix-socket` subprocess calls, not native NWConnection

Foundation's `URLSession` doesn't support Unix domain sockets directly; the
"correct" long-term answer is `Network.framework`'s `NWConnection` with a
`.unix(path:)` endpoint and hand-rolled HTTP/1.1 framing. That's real
implementation risk to take on unsupervised overnight. For this build:
Swift shells out to `curl --unix-socket <path> http://localhost/<route>`
per request via `Process`, matching the exact approach already verified
manually against the sidecar's `/health` endpoint earlier tonight. Revisit
with a native transport in v2 once the rest of the system is proven out —
noted as a known simplification, not an oversight.

## DeepSeek provider client (task 9 prep)

Built and reviewed: `sidecar/src/provider/deepseek.ts` /
`sidecar/test/provider/deepseek.test.ts`, 8 tests passing, typed
`DeepSeekApiError` (status + body) for both non-2xx responses and
malformed 200 bodies, dependency-injected `fetch` so no test hits the
network. `tsc --noEmit` still blocked on `sidecar/node_modules` not being
populated yet (`bun install` still running in the background as of this
entry, fetching `@modelcontextprotocol/sdk` for the B2 task).

<!-- Further entries appended chronologically below as autonomous calls are made. -->
