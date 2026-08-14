<div align="center">

<img src="docs/assets/icon.png" width="128" alt="OpenType">

# OpenType

**English** · [中文](README.zh-CN.md)

A local-first AI voice-input tool for macOS. Hold a hotkey, talk, and release — what you said is transcribed, answered, or handed to an agent to carry out. Speech recognition runs entirely on your Mac by default, so plain dictation needs no API key and no network.

**[Features and usage → opentype-site.vercel.app](https://opentype-site.vercel.app/)**

</div>

## Install

Paste this into Terminal:

```bash
curl -fsSL https://opentype-site.vercel.app/install | zsh
```

It fetches the latest release itself, installs the app to `/Applications`,
installs the dependencies, builds the local speech-recognition environment, and
re-signs the app — reporting a numbered step for each phase. Safe to re-run: a
second run keeps a working speech environment rather than rebuilding it.

It asks **where speech recognition should run**: on this Mac by default (free,
offline, private, but it adds a few minutes and about 1.1 GB of Python), or on
a remote service (nothing extra now, but you must then paste a transcription
API URL and key into the app, and every recording is uploaded, so it is
noticeably slower). Press Return for the default if you're not sure.

You can also hand this sentence to Claude Code, Codex, or Cursor and let it do
the whole thing, permissions and in-app wizard included:

> Please fetch the instructions at https://opentype-site.vercel.app/agent and
> follow them to install OpenType on this Mac for me

Want to read the script first — a good habit with any install script:

```bash
curl -fsSL https://opentype-site.vercel.app/install -o install.sh
less install.sh && zsh install.sh
```

The zip attached to a [release](https://github.com/iyidgnaw/OpenType/releases/latest)
holds only the app itself. Install through the script above: it has to build
the Python environment on your machine (see "Build from source" for why).

Two things are left that only you can do:

1. **Grant Microphone and Accessibility permissions** — both are required.
   macOS normally prompts; if you miss it, go to System Settings → Privacy &
   Security. Accessibility in particular usually has to be switched on by hand.
2. **Finish the in-app setup wizard** — pick your speech-to-text source, and
   add an LLM API key if you want Ask and Agent modes.

The first transcription downloads a ~460 MB speech model. That happens once,
and a long pause there is not a crash.

> The release is ad-hoc signed and **not notarized by Apple**. `install.sh`
> clears the download quarantine flag for you, so a normal install shows no
> Gatekeeper warning — but that also means you are trusting this repository's
> author. If you would rather not, build from source instead.

For a walkthrough of each mode and how to configure the hotkey, see the
[user guide](USER_GUIDE.md) — currently written in Chinese only.

## Requirements

- **An Apple Silicon Mac.** Local speech recognition is built on Apple's MLX,
  which has no Intel build. There is no workaround.
- **macOS 13 (Ventura) or newer.**
- **[Homebrew](https://brew.sh)** for local recognition — `install.sh` uses it
  to install `python@3.12` and `ffmpeg`. Not needed if you only use a remote
  transcription service.
- **Disk:** ~74 MB for the app, ~1.1 GB for the local speech environment, and
  ~460 MB more for the model.
- **An LLM API key** only for Ask and Agent modes; plain dictation needs none.

## Build from source

```bash
git clone https://github.com/iyidgnaw/OpenType.git
cd OpenType
./scripts/setup.sh
```

[`scripts/setup.sh`](scripts/setup.sh) is idempotent: it checks the machine,
installs dependencies, builds the Whisper venv, and produces
`dist/OpenType.app`. `--check` verifies without changing anything. Beyond the
requirements above it needs **Xcode command line tools**. Cut a release with
[`scripts/build-release.sh`](scripts/build-release.sh).

Architecture and development conventions are in [`CLAUDE.md`](CLAUDE.md).

## About Agent mode

Agent mode really does run shell commands, Python, and file operations, **with
no sandbox and without asking you to confirm anything first** — a deliberate
choice by the author for his own machine. Known defect: pressing Stop does not
reliably prevent already-queued tool calls from running. Transcribe and Ask
involve none of this. The agent's written answer is always a draft, copied to
your clipboard and never sent anywhere on your behalf.

## License

[MIT](LICENSE)
