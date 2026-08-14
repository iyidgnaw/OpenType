# OpenType install prompt (for a new user's coding agent)

Status: a ready-to-copy prompt, not a design doc. This file's job is the
literal text inside the fenced block below — a new user pastes it into their
own coding agent (Claude Code, Codex, Cursor, etc.) to get OpenType installed
and configured on their Mac. Everything outside the fence is context for
whoever maintains this file, not part of the prompt itself.

## Why a prompt instead of a normal install doc

Users install from a release archive, so there is no build step — but there is
still a real setup tail: Homebrew dependencies, a Python environment that has
to be created on the target machine, two macOS permission grants, and an
in-app provider wizard. That is enough moving parts that handing it to an
agent beats walking a non-engineer through it by hand.

## Relationship to the scripts

`install.sh` ships inside the release archive and does the mechanical work
(dependencies, install to /Applications, build the local speech environment,
re-sign). This prompt does not restate its commands — an agent running one
audited script is far more reliable than an agent improvising, and it keeps
this file from drifting out of sync with the installer.

What stays in the prompt is what a script cannot do: the two questions that
change what gets installed, failure triage, macOS permissions, and driving the
in-app wizard.

Building from source is a separate path for contributors, covered by the
repo's `README.md` and `scripts/setup.sh` — not by this prompt.

---

## The prompt

```
You're installing OpenType, a local-first macOS voice-input app, for me on this Mac. Work through this step by step. Where a step says to ask me something, actually ask and wait — don't guess or pick a default on my behalf.

## 1. Check this Mac can run it

OpenType needs an Apple Silicon Mac (its speech recognition uses Apple's MLX, which has no Intel build) running macOS 13 or newer. Check with `uname -m` (expect arm64) and `sw_vers -productVersion`. If this Mac is Intel, stop and tell me — there is no workaround.

## 2. Ask me two questions before installing anything

Don't proceed past this step until I've answered both:

**a) Speech-to-text: local or remote?**
- **Local** runs entirely on this Mac — private, free, no API key, works offline. Setup installs Homebrew's python@3.12 plus ffmpeg and builds a ~1.1 GB Python environment, so budget a few minutes and a couple of GB of disk. The first transcription then downloads a ~460 MB speech model, once. This is the default and what most people want.
- **Remote** calls a hosted transcription API instead, and needs a base URL and API key that I'll enter in the app later. If I pick this, pass `--skip-whisper` to the installer in step 4 and skip the Python setup entirely.

**b) LLM provider: which one, and do I have an API key ready?**
Only the Ask and Agent modes need this — plain dictation works with no key at all, so "none for now" is a fine answer. The app has its own setup wizard with a real Test Connection and model picker, so you don't need to configure it yourself; just confirm I have a key ready (Anthropic, OpenAI, DeepSeek, or any OpenAI-compatible endpoint) so I'm not stuck mid-wizard.

Also tell me now, before installing: Agent mode runs shell commands and file operations with no sandbox and no confirmation prompt, and its Stop button is known not to reliably halt tool calls that are already queued. I should hear that before it's on my machine, not after.

## 3. Download the release

Get the latest release archive from https://github.com/iyidgnaw/OpenType/releases/latest — the asset is named `OpenType-<version>-macos-arm64.zip`. Download it and unzip it (use `ditto -x -k <zip> <dir>` rather than a GUI unarchiver, so the app's code signature survives intact).

Inside you'll find `OpenType.app`, `install.sh`, and `INSTALL.md`.

## 4. Run the installer

From inside the unzipped folder:

    ./install.sh

Add `--skip-whisper` if I chose remote speech-to-text in step 2.

It installs the app to /Applications, installs Homebrew's python@3.12 and ffmpeg if missing, builds the local speech environment inside the app bundle, and re-signs the app. It's safe to re-run, and re-running keeps a working speech environment rather than rebuilding it.

Read its output. Its error messages are written to be actionable and each one names the fix. Two things NOT to do when troubleshooting:
- Don't substitute a bare `python3` if it complains about python@3.12. The system Python is 3.9 and Xcode's bundled one is also wrong; this software needs 3.12 or newer. Install Homebrew's python@3.12 properly instead.
- Don't skip the re-signing step or try to work around a signature error by deleting the signature. macOS ties microphone and accessibility permissions to it, and an app with a broken signature may refuse to open.

If something fails in a way its error message doesn't cover, stop and tell me exactly what broke and what you tried, rather than silently working around it.

## 5. Walk me through permissions

Open the app (`open /Applications/OpenType.app`), then guide me through granting both required permissions:
- **Microphone** — to record my voice.
- **Accessibility** — to read selected text and insert results into whatever app I'm using.

macOS should prompt. If it doesn't, or I dismiss one, send me to System Settings → Privacy & Security; Accessibility in particular usually has to be enabled by hand there. Tell me what to click.

Then confirm with me that the menu bar icon appeared. OpenType runs menu-bar-only with no Dock icon until its main window is opened; opening that window gives it a Dock icon and makes it Cmd+Tab-switchable, and closing it returns to menu-bar-only. "Quit OpenType" is in the menu bar popover.

## 6. Walk me through the in-app wizard

Nothing is configured yet, so opening the main window should show a first-run setup wizard covering the same two choices from step 2: pick the speech-to-text source (entering URL and key if remote), then optionally pick an LLM provider, enter its key, hit Test Connection, and choose a model once it succeeds.

This is the same UI as Settings' "语音识别" / "AI 模型" sections — note that the app's interface is currently Chinese only, and tell me that up front if I don't read Chinese.

## 7. Wrap up

Tell me explicitly that everything configured today — speech source, LLM provider, hotkey style — is editable later from Settings, and that nothing requires reinstalling to change.

Then offer to have me try a recording end to end, and remind me that the very first transcription downloads the speech model, so one long pause there is expected and is not a hang.
```
