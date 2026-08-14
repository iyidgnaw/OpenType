<div align="center">

<img src="docs/assets/icon.png" width="128" alt="OpenType">

# OpenType

[中文](README.md) · **English**

A local-first AI voice-input tool for macOS. Hold a hotkey, talk, and release — what you said is transcribed, answered, or handed to an agent to carry out. Speech recognition runs entirely on your Mac by default, so plain dictation needs no API key and no network.

**[Features and usage → opentype-site.vercel.app](https://opentype-site.vercel.app/)**

</div>

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/iyidgnaw/OpenType/main/scripts/install-release.sh | zsh
```

It fetches the latest release itself, installs the app to `/Applications`,
installs the dependencies, builds the local speech-recognition environment
inside the app bundle, and re-signs the app. Safe to re-run — a second run
keeps a working speech environment rather than rebuilding it. Pass
`--skip-whisper` to use a remote transcription service instead (through a pipe
that is `| zsh -s -- --skip-whisper`).

Want to read it before running it — which is a good habit with any install
script:

```bash
curl -fsSL https://raw.githubusercontent.com/iyidgnaw/OpenType/main/scripts/install-release.sh -o install.sh
less install.sh && zsh install.sh
```

You can also download the zip (~23 MB) from
[Releases](https://github.com/iyidgnaw/OpenType/releases/latest) and run the
`./install.sh` inside it — same script; when it finds an OpenType.app beside
it, it uses that instead of downloading again.

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

**Prefer not to babysit this?** Hand the prompt in
[`docs/onboarding/coding-agent-setup-prompt.md`](docs/onboarding/coding-agent-setup-prompt.md)
to Claude Code, Codex, or Cursor and it will walk you through downloading,
installing, permissions, and the setup wizard.

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
