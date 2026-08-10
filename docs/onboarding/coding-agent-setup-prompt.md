# OpenType setup prompt (for a new user's coding agent)

Status: a ready-to-copy prompt, not a design doc. This file's job is the
literal text inside the fenced block below — hand it to a new user, who pastes
it into their own coding agent (Claude Code, Codex, etc.) to get OpenType
built, installed, and configured on their Mac. Everything outside the fence
is context for whoever is maintaining this file, not part of the prompt
itself.

## Why a prompt instead of a normal install doc

OpenType has no packaged release yet (see the root `README.md`'s delivery
status) — install currently means clone + build from source, which involves
enough real steps (Xcode CLI tools, Homebrew, a Python venv pinned to the
right interpreter, ffmpeg, first-run permissions) that walking a non-engineer
through it by hand doesn't scale. A coding agent can drive all of that
directly instead of the user copy-pasting shell commands themselves.

## Keeping this in sync

This prompt intentionally tells the coding agent to *check* `CLAUDE.md` /
`sidecar/README.md` / `sidecar/src/env.ts` for current provider/env-var
specifics rather than hardcoding them here, since that surface is under
active development (see `docs/superpowers/specs/2026-08-09-current-system-state.md`
§10) and would go stale fast otherwise. The parts that *are* hardcoded below
(the local-Whisper venv/ffmpeg steps) are hardcoded deliberately — they're
the two real, previously-hit bugs this session found (see
`docs/superpowers/specs/2026-08-09-current-system-state.md` §4 and its build
notes), not surface that's expected to change soon. If `sidecar/whisper-env`'s
layout or the venv bootstrap path in `scripts/build-app.sh` ever changes,
update the fenced prompt below to match.

## The repo is currently private

The clone step below will fail for anyone not already added as a GitHub
collaborator on `iyidgnaw/OpenType`. Whoever hands this prompt out needs to
grant access first.

---

## The prompt

```
You're setting up OpenType, a local-first macOS voice-input app, for me on this Mac. Work through this step by step, and ask me questions where noted rather than guessing or picking a default on my behalf.

## 1. Prerequisites

Confirm/install before proceeding:
- macOS on Apple Silicon (MLX-Whisper, the local speech-recognition engine, requires it)
- Xcode command line tools: `xcode-select -p` (install via `xcode-select --install` if missing)
- Homebrew, with `bun` and `python@3.12` installed: `brew install oven-sh/bun/bun python@3.12` if missing
- I have git access to the private repo below — I may need to accept a GitHub collaborator invite first

## 2. Clone and orient

Clone git@github.com:iyidgnaw/OpenType.git (use the https form if I don't have SSH keys set up: https://github.com/iyidgnaw/OpenType.git). Then read CLAUDE.md at the repo root in full before doing anything else — it's the authoritative build/architecture reference and takes precedence over anything below if they disagree.

## 3. Ask me two questions before setting anything up

Ask me directly — don't assume defaults, and don't proceed past this step until I've answered both:

**a) Speech-to-text (Whisper): local or remote?**
- **Local** runs entirely on this Mac via MLX-Whisper — private, free, needs Apple Silicon, and the first real transcription request has a one-time multi-second delay while the model loads (don't mistake that for a hang). This is the default and what most people want.
- **Remote** calls a hosted transcription API instead — needs a base URL and an API key from me, entered later in the app itself. If I pick this, skip section 4 below (no local Whisper environment needed) and go straight to section 5.

**b) LLM provider: which one, and do I have an API key ready?**
The app now has its own in-app setup wizard for this (real Test Connection + model picking, not just an env file) — you don't need to configure it yourself. Just confirm I have a key ready for whichever provider I want (Anthropic, OpenAI, DeepSeek, or another OpenAI-compatible endpoint), so I'm not stuck mid-wizard later. Check `CLAUDE.md` and `sidecar/README.md` for the current list of supported provider types in case this has changed since this prompt was written.

## 4. Set up local Whisper (only if I chose "local" above)

This is the step most likely to silently go wrong, so follow it exactly and verify each part — don't just run the commands and assume success:

```bash
cd sidecar
/opt/homebrew/bin/python3.12 -m venv whisper-env
```

Use the explicit `/opt/homebrew/bin/python3.12` path, NOT a bare `python3`. On many Macs, plain `python3` silently resolves to Xcode's bundled interpreter (`/Applications/Xcode.app/Contents/Developer/usr/bin/python3`) instead of Homebrew's — it's an old, fragile version tied to wherever Xcode happens to be installed, and mlx-whisper has broken against it before. If `/opt/homebrew/bin/python3.12` doesn't exist, that means `brew install python@3.12` from step 1 didn't complete — go back and fix that first rather than falling back to plain `python3`.

```bash
whisper-env/bin/pip install mlx-whisper
brew install ffmpeg
```

`mlx_whisper.transcribe()` shells out to `ffmpeg` — this is a real, previously-hit failure mode, not a hypothetical. You do NOT need to manually add ffmpeg to any PATH: OpenType's sidecar automatically searches `/opt/homebrew/bin`, `/opt/homebrew/sbin`, and `/usr/local/bin` when it spawns the local Whisper process, specifically because GUI-launched (`open`-launched) apps inherit a minimal PATH that wouldn't otherwise include it. As long as `brew install ffmpeg` put it in one of those three standard locations (it will, by default), this just works — but if `which ffmpeg` doesn't show one of those three paths, flag it to me rather than assuming it'll be found.

Before building the full app, verify the venv actually works on its own:

```bash
whisper-env/bin/python3 -c "import mlx_whisper; print('ok')"
```

If this fails, stop and fix it here — don't proceed to a full app build with a broken ASR environment, since the failure will be much harder to diagnose once it's wrapped inside the packaged app.

## 5. Build and install

From the repo root:

```bash
./scripts/build-app.sh
open dist/OpenType.app
```

If the build script warns about a missing `sidecar/whisper-env`, that means section 4 wasn't completed (expected if I chose "remote" Whisper) — otherwise go back and fix it.

## 6. First-run permissions

Tell me to grant these when macOS prompts (or via System Settings → Privacy & Security if I miss the prompt):
- Microphone (to record my voice)
- Accessibility (to read/write text in whatever app I'm using)

Confirm the app's menu bar status icon appears. OpenType runs menu-bar-only by default (no Dock icon) until its main window is opened, at which point it gets a Dock icon and becomes Cmd+Tab-switchable; closing that window returns it to menu-bar-only. There's a labelled "Quit OpenType" action in both the menu bar popover and the main window if I need to fully quit it.

## 7. In-app setup wizard

Since nothing is configured yet, opening OpenType's main window should show a first-run setup wizard covering exactly the two choices from section 3 — walk me through it: pick Whisper mode (and if remote, enter the URL/key), then pick an LLM provider, enter its base URL and API key, hit Test Connection, and pick a model from the list once it succeeds. This is the same UI as Settings' "语音识别"/"AI 模型" sections, so anything set here can be changed later from Settings too — nothing in this whole setup is permanent or requires reinstalling to change.

## 8. Wrap up

Tell me explicitly that everything configured today — Whisper source, LLM provider, hotkey style — is editable later from the app's own Settings, and ask if I want to try recording something to confirm the whole pipeline actually works end to end.

If anything fails at any step, don't guess past it or silently work around it — tell me exactly what broke, what you tried, and ask before trying something more invasive.
```
