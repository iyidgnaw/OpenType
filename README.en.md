# OpenType

[中文](README.md) · **English**

OpenType is a local-first AI voice-input tool for macOS that turns spontaneous
speech into text you can use right away. Hold a hotkey, talk, and release — and
what you said is transcribed, answered, or handed to an agent to carry out.

> There were once iOS and Android clients, meant to share one behavioral
> contract with macOS. After the macOS app was rewritten from zero, both were
> removed outright — a product decision, not an oversight. This repository is
> macOS only.

The full user guide is [in Chinese](USER_GUIDE.md).

## Install

Download `OpenType-<version>-macos-arm64.zip` (~24 MB) from
[Releases](https://github.com/iyidgnaw/OpenType/releases/latest), unzip it, and
run this from inside the unzipped folder:

```bash
./install.sh
```

It installs the app to `/Applications`, installs `python@3.12` and `ffmpeg` via
Homebrew, builds the local speech-recognition environment inside the app
bundle, and re-signs the app. It is safe to re-run — a second run keeps a
working speech environment rather than rebuilding it. Pass `--skip-whisper` to
skip local recognition and configure a remote transcription service in the app
instead.

**Prefer not to babysit this?** Hand the prompt in
[`docs/onboarding/coding-agent-setup-prompt.md`](docs/onboarding/coding-agent-setup-prompt.md)
to Claude Code, Codex, or Cursor, and it will walk you through downloading,
installing, granting the two macOS permissions, and the in-app setup wizard.
That prompt covers what a script cannot, including the two choices worth
making before anything is installed (local or remote speech-to-text, and which
LLM provider).

> The release is ad-hoc signed and **not notarized by Apple**. `install.sh`
> clears the download quarantine flag for you, so a normal install shows no
> Gatekeeper warning — but that also means you are trusting this repository's
> author. If you would rather not, build from source instead.

### Requirements

- **An Apple Silicon Mac.** Local speech recognition is built on Apple's MLX,
  which has no Intel build. There is no workaround.
- **macOS 13 (Ventura) or newer.**
- **[Homebrew](https://brew.sh)**, for local recognition (it installs Python
  and ffmpeg). Not needed if you only use a remote transcription service.
- **Disk:** ~74 MB for the app, ~1.1 GB for the local speech environment (most
  of that is mlx-whisper's dependency tree; mlx-whisper itself is under 2 MB),
  plus a ~460 MB speech model downloaded to `~/.cache/huggingface` the first
  time you transcribe. That download happens once and is not a hang.
- **An LLM API key only for Ask and Agent modes.** Plain dictation needs no key
  and no network at all.

### Build from source (contributors)

```bash
git clone https://github.com/iyidgnaw/OpenType.git
cd OpenType
./scripts/setup.sh
```

[`scripts/setup.sh`](scripts/setup.sh) is idempotent: it checks the machine,
installs `bun` / `python@3.12` / `ffmpeg` via Homebrew, builds the local
Whisper venv, and produces `dist/OpenType.app`. Beyond the requirements above
it needs **Xcode command line tools** (`xcode-select --install`); a full
checkout with build artifacts takes about 3.4 GB.

| Flag | Effect |
|---|---|
| `--skip-whisper` | skip the local Whisper environment |
| `--no-build` | install dependencies only |
| `--check` | verify and report, change nothing |

Cut a release with [`scripts/build-release.sh`](scripts/build-release.sh). It
builds the app, **strips the local Whisper venv** (a venv hardcodes absolute
paths to the interpreter that created it, so it cannot run on another machine —
`install.sh` rebuilds it on the target instead), re-signs, and packs a zip.

## What it does

Three modes, switched from the menu bar. Each recording locks in the mode it
started with.

| Mode | You say | You get |
|---|---|---|
| **Transcribe** | anything | exactly what you said, as text. No model rewrites it. |
| **Ask** | a question | an answer in the voice panel. It can search and read the web. |
| **Agent** | a task | the task actually carried out — shell, Python, files, web, opening documents. |

- **Transcribe has two variants.** *Direct* writes the text out immediately.
  *Review* parks it in an editable floating panel first, where you can type
  corrections, or select a span and press the hotkey again to correct it by
  voice ("that's wrong, it should be PayPal") — the model rewrites only the
  selected span. `⌘↩` commits, `Esc` cancels.
- **Speech recognition is local or remote.** Local uses MLX-Whisper, fully
  offline, Apple Silicon only. Remote speaks OpenAI's audio-transcription
  protocol against any base URL, so self-hosted compatible servers work too.
  Switch any time in Settings; both have a Test Connection button.
- **LLM providers are configurable:** Anthropic (Messages API) or any
  OpenAI-compatible endpoint (DeepSeek, OpenAI itself, self-hosted). Enter a
  URL and key, hit Test Connection, then pick from the model list it fetches
  rather than typing a model name blind.
- **Q&A and Agent each get their own tab,** with real multi-turn continuation:
  open a past conversation and speak again in that mode and it continues that
  thread rather than starting over.
- **Configurable global hotkey:** hold left `Option`, hold `fn`, double-tap
  `Ctrl` / `Option` / `Shift`, or a chord like `⌃⇧Space`.
- **Menu-bar native.** Clicking the status item opens a compact mode switcher
  only. The main window is opened separately; opening it adds a Dock icon and
  makes the app `Cmd+Tab`-switchable, and closing it returns to menu-bar-only.
- **Local long-term memory:** the sidecar keeps an entity dictionary (terms,
  aliases, referents) plus free-text "owner facts". Say "remember …" to the
  agent to write to either. Viewable read-only in Settings.
- **Every result goes to the clipboard.** Auto-inserting into the focused text
  field is an extra step controlled by a setting, and only Transcribe honors
  it — Ask stays in the panel, Agent is draft-only.
- **Full audit trail:** every recognition, every correction, and every
  completion or cancellation is appended to a local immutable JSONL log. The
  raw audio itself is not kept.

## First run

Two permissions are required, and the app is useless without both:

1. **Microphone** — to record your voice.
2. **Accessibility** — to read selected text and write results back into the
   app you're using.

macOS normally prompts. If you miss it, go to System Settings → Privacy &
Security; Accessibility in particular usually has to be switched on by hand.

If neither speech recognition nor an LLM provider has been configured, opening
the main window starts a setup wizard (Test Connection plus model picking).
Everything it configures can be changed later under Settings.

## About Agent mode

Agent mode really does run shell commands, Python, and file operations, **with
no sandbox and without asking you to confirm anything first**. That is a
deliberate choice by the author for his own machine, not an oversight — but it
means Agent mode acts on a spoken instruction, including when you didn't quite
mean it. There is a known defect here too: pressing Stop does not reliably
prevent already-queued tool calls from running. Judge accordingly; Transcribe
and Ask involve none of this.

The agent's final written answer is always a draft — copied to your clipboard,
never sent anywhere on your behalf.

## Privacy

- Audio is processed on your Mac by MLX-Whisper by default and sent nowhere. It
  only leaves the machine if you switch speech recognition to a remote service
  you configured yourself. The temporary audio file is deleted after
  recognition.
- Recognized text is sent to your configured LLM provider only in `ask` and
  `agent` modes. `transcribe` never touches an LLM. The context sent to the
  model includes **every owner fact you told the agent to remember** — injected
  wholesale, not filtered by relevance (only facts from untrusted, non-owner
  sources are excluded). The sidecar also appends each `ask`/`agent` input
  (truncated to ~200 characters) to a local `context-debug.log`, which is not
  cleared by "reset input history".
- The live caption preview during recording uses Apple's on-device recognizer
  and is only a preview; the final result always comes from a fresh pass by
  whichever Whisper you configured.
- Provider API keys are stored by the sidecar in its local data directory as
  `chmod 600` plaintext JSON — never in the repository, logs, or history, and
  echoed back only masked. This is not the hardware-isolated Keychain; the
  trust boundary is your macOS account.
- History, Q&A/Agent conversations, and audit logs live under
  `~/Library/Application Support/OpenType/`, across two separate SQLite
  databases (`memory.sqlite3` on the Swift side, `opentype.sqlite3` on the
  sidecar side). History can be reset from Settings.
- Every recognition, correction, completion, and cancellation is appended to a
  local immutable `audit-events.v1.jsonl`, unaffected by resetting history.
- Agent results are drafts on the clipboard. Nothing is ever sent, posted, or
  executed outward on your behalf.

## Architecture

macOS is a **Swift shell + TypeScript sidecar** split. Swift owns recording,
hotkeys, Accessibility, delivery, and local storage; every actual speech
recognition and text generation call goes to a local `sidecar/` (Bun) child
process over a Unix socket. Nothing in Swift talks to a cloud provider
directly.

- [`CLAUDE.md`](CLAUDE.md) — the authoritative architecture reference, and what
  a coding agent should read first.
- [`sidecar/README.md`](sidecar/README.md) — sidecar endpoints, env vars, layout.
- [`docs/`](docs/) — design specs, reference notes, and code reviews.

```bash
swift build                                   # debug build
swift test                                    # Swift tests
./scripts/build-app.sh                        # release build -> dist/OpenType.app

cd sidecar && bun install && bun test         # sidecar tests
```

Note that each `build-app.sh` run leaves a ~57 MB `.bun-build` temp file in
`sidecar/`. They're gitignored but not cleaned up, so sweep them occasionally
with `rm -f sidecar/.*.bun-build`.

## License

[MIT](LICENSE)
