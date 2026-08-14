# OpenType setup prompt (for a new user's coding agent)

Status: a ready-to-copy prompt, not a design doc. This file's job is the
literal text inside the fenced block below — a new user pastes it into their
own coding agent (Claude Code, Codex, etc.) to get OpenType built, installed
and configured on their Mac. Everything outside the fence is context for
whoever maintains this file, not part of the prompt itself.

## Why a prompt instead of a normal install doc

OpenType has no packaged release (see the root `README.md`) — installing means
clone and build from source, which involves enough real steps (Xcode CLI tools,
Homebrew, a Python venv pinned to the right interpreter, ffmpeg, code signing,
two macOS permission grants) that walking a non-engineer through it by hand
doesn't scale. A coding agent can drive all of it directly.

## Relationship to `scripts/setup.sh`

The mechanical work now lives in `scripts/setup.sh`, which is idempotent and
has a non-mutating `--check` mode. This prompt deliberately does **not**
re-specify the commands the script already runs — an agent executing one
audited script is far more reliable than an agent improvising a dozen shell
commands, and it keeps this file from drifting out of sync with the build.

What stays in the prompt is the part a script can't do: asking the user the two
questions that change what gets installed, interpreting failures, walking them
through macOS permissions, and driving the in-app wizard. The prompt also tells
the agent to read `CLAUDE.md` / `sidecar/README.md` for current provider and
env-var specifics rather than hardcoding them here, since that surface changes.

If `setup.sh` grows or loses a flag, update the fenced prompt to match.

---

## The prompt

```
You're setting up OpenType, a local-first macOS voice-input app, for me on this Mac. Work through this step by step. Where a step says to ask me something, actually ask and wait — don't guess or pick a default on my behalf.

## 1. Clone and orient

Clone https://github.com/iyidgnaw/OpenType.git (or the SSH form, git@github.com:iyidgnaw/OpenType.git, if I have SSH keys set up).

Then read the repo's README.md and CLAUDE.md before doing anything else. CLAUDE.md is the authoritative architecture and build reference — if anything below disagrees with it, CLAUDE.md wins and you should tell me about the discrepancy.

## 2. Ask me two questions before installing anything

Don't proceed past this step until I've answered both:

**a) Speech-to-text: local or remote?**
- **Local** runs entirely on this Mac via MLX-Whisper — private, free, no API key, works offline. Requires Apple Silicon. Downloads a ~460 MB model the first time I actually transcribe something, and the first request after each launch has a few seconds of model-loading delay. This is the default and what most people want.
- **Remote** calls a hosted transcription API instead, and needs a base URL and API key that I'll enter in the app later. If I pick this, pass `--skip-whisper` to the setup script in step 3.

**b) LLM provider: which one, and do I have an API key ready?**
This is only needed for Ask and Agent modes — plain dictation works without any key, so "none for now" is a valid answer. The app has its own setup wizard for this with a real Test Connection and model picker, so you don't need to configure it yourself; just confirm I have a key ready (Anthropic, OpenAI, DeepSeek, or any OpenAI-compatible endpoint) so I'm not stuck mid-wizard. Check CLAUDE.md and sidecar/README.md for the current supported provider list in case it changed.

Also tell me now, before we start, that Agent mode runs shell commands and file operations with no sandbox and no confirmation prompt, and that its Stop button is known not to reliably halt already-queued tool calls. I should know that before I install it, not after.

## 3. Run the setup script

From the repo root:

    ./scripts/setup.sh

Add `--skip-whisper` if I chose remote speech-to-text in step 2.

The script checks prerequisites, installs bun / python@3.12 / ffmpeg via Homebrew, builds the local Whisper environment, and builds dist/OpenType.app. It's idempotent, so re-running it after fixing a problem is safe and cheap.

Expect it to take a while — it downloads several hundred MB of Python packages and does a full release build. It needs network access for both, plus for SwiftPM to resolve dependencies on the first build.

**If it fails, read its error message carefully — they're written to be actionable and each names the fix.** Two things NOT to do when troubleshooting:
- Don't fall back to a bare `python3` if the script complains about `python@3.12`. The system Python is 3.9 and Xcode's bundled one is also wrong; this stack's floor is 3.12 (scipy requires >=3.12). Install Homebrew's python@3.12 properly instead.
- Don't skip ffmpeg. MLX-Whisper shells out to it to decode audio, and its absence produces a confusing runtime failure much later rather than an install error. This is a real, previously-hit bug.

If something fails in a way the error message doesn't cover, stop and tell me exactly what broke and what you tried, rather than working around it silently.

## 4. Verify before moving on

Run:

    ./scripts/setup.sh --check

This changes nothing and reports the state of every piece. Everything should report ok (local Whisper lines will be skipped if I chose remote). Don't move on with a failing check — a broken speech environment is much harder to diagnose once it's wrapped inside the packaged app.

## 5. Install and launch

    cp -R dist/OpenType.app /Applications/
    open /Applications/OpenType.app

Running it from /Applications rather than dist/ keeps macOS permissions stable across future rebuilds.

## 6. Walk me through first-run permissions

Two permissions are required, and the app is useless without both:
- **Microphone** — to record my voice.
- **Accessibility** — to read selected text and insert results into whatever app I'm using.

macOS should prompt. If it doesn't, or I dismiss one, send me to System Settings → Privacy & Security; Accessibility in particular usually has to be enabled by hand there. Tell me what to click.

Then confirm with me that the menu bar icon appeared. OpenType runs menu-bar-only with no Dock icon until its main window is opened; opening that window gives it a Dock icon and makes it Cmd+Tab-switchable, and closing it goes back to menu-bar-only. "Quit OpenType" is in the menu bar popover.

## 7. Walk me through the in-app wizard

Nothing is configured yet, so opening the main window should show a first-run setup wizard covering the same two choices from step 2: pick the speech-to-text source (entering URL and key if remote), then optionally pick an LLM provider, enter its key, hit Test Connection, and choose a model once it succeeds.

This is the same UI as Settings' "语音识别" / "AI 模型" sections — note that the app's interface is currently Chinese only, and tell me that up front if I don't read Chinese.

## 8. Wrap up

Tell me explicitly that everything configured today — speech source, LLM provider, hotkey style — is editable later from Settings, and that nothing here requires reinstalling to change.

Then offer to have me try a recording end to end, and remind me the very first transcription downloads the ~460 MB model, so a long pause there is expected exactly once and is not a hang.
```
