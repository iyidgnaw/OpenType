# Install OpenType on this Mac

You are installing OpenType, a local-first macOS voice-input app, for the
person you are working with. Work through this in order. Where a step says to
ask them something, actually ask and wait for an answer — do not guess or pick
a default on their behalf.

## 1. Check this Mac can run it

OpenType needs an **Apple Silicon** Mac (its speech recognition is built on
Apple's MLX, which has no Intel build) running **macOS 13 Ventura or newer**.

```bash
uname -m && sw_vers -productVersion
```

`uname -m` must print `arm64`. If it prints `x86_64`, stop and tell them this
Mac cannot run OpenType — there is no workaround.

## 2. Ask them two questions

Do not proceed until both are answered.

**a) Where should speech recognition run — on this Mac, or a remote service?**

- **On this Mac** (the default, and what most people want): free, private,
  works offline. Setup installs Homebrew's `python@3.12` and `ffmpeg` and
  builds a ~1.1 GB Python environment, so it adds a few minutes and a couple
  of GB of disk. The first transcription then downloads a ~460 MB speech
  model, once.
- **A remote service**: nothing extra installed now, but afterwards they must
  paste a transcription API URL and key into the app, and transcription is
  **noticeably slower** because every recording is uploaded and comes back
  over the network.

If they don't know what this means, tell them to take the default.

**b) Which LLM provider, and do they have an API key ready?**

This is needed only for the Ask and Agent modes — plain dictation works with no
key at all, so "none for now" is a perfectly good answer. The app has its own
setup wizard with a real Test Connection and model picker, so you do not
configure this yourself; just confirm they have a key ready (Anthropic, OpenAI,
DeepSeek, or any OpenAI-compatible endpoint) so they are not stuck mid-wizard.

**Also tell them this before anything is installed:** Agent mode runs shell
commands and file operations with **no sandbox and no confirmation prompt**,
and its Stop button is known not to reliably halt tool calls that are already
queued. They should hear that before it is on their machine, not after.

## 3. Run the installer

If they chose on-device recognition in step 2a:

```bash
curl -fsSL https://opentype-site.vercel.app/install | zsh
```

If they chose a remote service:

```bash
curl -fsSL https://opentype-site.vercel.app/install | zsh -s -- --skip-whisper
```

Passing the flag explicitly matters: run without it and the script asks the
question itself, which it cannot do when there is no terminal attached to your
shell — it will quietly take the default instead.

The script fetches the latest release, installs the app to `/Applications`,
installs the dependencies, builds the speech environment, and re-signs the app.
It prints a numbered step for each phase. It is safe to re-run, and re-running
keeps a working speech environment rather than rebuilding it.

If they ask to read it before it runs, show it to them — that is their call,
not yours:

```bash
curl -fsSL https://opentype-site.vercel.app/install -o /tmp/opentype-install.sh
```

**Two things not to do when troubleshooting:**

- Do not substitute a bare `python3` if it complains about `python@3.12`. The
  system Python is 3.9 and Xcode's bundled one is also wrong; this software
  needs 3.12 or newer. Install Homebrew's `python@3.12` properly instead.
- Do not work around a signature error by stripping the signature. macOS ties
  microphone and accessibility permissions to it, and an app with a broken
  signature may refuse to open.

If something fails in a way the script's own error message doesn't cover, stop
and tell them exactly what broke and what you tried, rather than silently
working around it.

## 4. Walk them through permissions

```bash
open /Applications/OpenType.app
```

Two permissions are required, and the app is useless without both:

- **Microphone** — to record their voice.
- **Accessibility** — to read selected text and insert results into whatever
  app they are using.

macOS normally prompts. If it doesn't, or they dismiss one, send them to
System Settings → Privacy & Security; Accessibility in particular usually has
to be switched on by hand there. Tell them what to click.

Then confirm the menu bar icon appeared. OpenType runs menu-bar-only with no
Dock icon until its main window is opened; opening that window gives it a Dock
icon and makes it `Cmd+Tab`-switchable, and closing it returns to
menu-bar-only. "Quit OpenType" is in the menu bar popover.

## 5. Walk them through the in-app wizard

Nothing is configured yet, so opening the main window shows a first-run setup
wizard covering the same two choices from step 2: the speech-to-text source,
then optionally an LLM provider — enter the key, hit Test Connection, and pick
a model from the list once it succeeds.

**If they chose a remote transcription service, this step is mandatory** —
nothing on their Mac can transcribe until they enter the URL and key under
语音识别 and Test Connection succeeds.

Note that the app's interface is currently **Chinese only**, and tell them so
up front if they don't read Chinese.

## 6. Wrap up

Tell them explicitly that everything configured today — speech source, LLM
provider, hotkey style — is editable later from Settings, and that nothing
requires reinstalling to change.

Then offer to have them try a recording end to end. If they chose on-device
recognition, remind them the very first transcription downloads the speech
model, so one long pause there is expected and is not a hang.

---

<sub>Source and issues: https://github.com/iyidgnaw/OpenType — this file is
served at https://opentype-site.vercel.app/agent and is meant to be fetched and
followed directly by a coding agent. Keep it self-contained: anything an agent
needs must be in the text above, not in a link it has to chase.</sub>
