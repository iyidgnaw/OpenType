#!/bin/zsh
#
# OpenType installer. Works two ways:
#
#   curl -fsSL https://raw.githubusercontent.com/iyidgnaw/OpenType/main/scripts/install-release.sh | zsh
#   ./install.sh          # uses the OpenType.app sitting next to it
#
# zsh rather than sh: this uses zsh parameter expansion, and zsh is macOS's
# default shell, so it is always present on any Mac that can run OpenType.
#
# The second form is how it ships inside the release archive. Either way it is
# safe to re-run.
#
# What it does:
#   1. checks this Mac can run OpenType at all
#   2. gets OpenType.app -- from next to this script, or from the latest release
#   3. installs python@3.12 and ffmpeg via Homebrew
#   4. copies the app into /Applications and clears the download quarantine
#   5. builds the local speech-recognition environment inside the app
#   6. re-signs the app, because step 5 changed its contents
#
# Step 5 exists because a Python virtual environment hardcodes absolute paths to
# the interpreter that created it, so it cannot be shipped prebuilt -- it has to
# be created on the machine that will run it. It lands at about 1.1 GB; most of
# that is mlx-whisper's dependency tree, not mlx-whisper itself, which is under
# 2 MB. The speech model is separate again: ~460 MB fetched into
# ~/.cache/huggingface the first time something is actually transcribed.
#
# Options:
#   --dest DIR        install into DIR instead of /Applications (for testing)
#   --skip-whisper    no local speech recognition; configure a remote service in the app
#
# Everything below lives inside main(), called on the last line. When this file
# is piped straight into a shell, a connection that drops halfway would
# otherwise leave the shell executing whatever fragment of the script arrived --
# with the body in a function, a truncated download simply never runs.

set -euo pipefail

REPO="iyidgnaw/OpenType"
API_LATEST="https://api.github.com/repos/$REPO/releases/latest"

step() { print -P "%F{cyan}==>%f $1"; }
ok()   { print -P "  %F{green}ok%f  $1"; }
warn() { print -P "  %F{yellow}!!%f  $1" >&2; }
die()  { print -P "%F{red}error:%f $1" >&2; exit 1; }

usage() {
  cat <<'USAGE'
OpenType installer.

  curl -fsSL <url> | zsh          fetch the latest release and install it
  ./install.sh                    install the OpenType.app next to this script

Options:
  --dest DIR        install into DIR instead of /Applications
  --skip-whisper    skip local speech recognition (use a remote service instead)
  -h, --help        show this
USAGE
}

# Resolves the directory holding this script, or nothing when piped into a
# shell (where $0 is the shell itself, not a file we can locate).
script_directory() {
  local candidate=${(%):-%N}
  [[ -f $candidate ]] || return 0
  print -r -- ${candidate:A:h}
}

# Downloads the latest release archive and echoes the path to the app inside it.
# Everything lands in $1, a caller-owned temp dir, so the caller can clean up.
fetch_release() {
  local workdir=$1

  step "Finding the latest release" >&2
  local url
  url=$(curl -fsSL --max-time 60 "$API_LATEST" \
    | awk -F'"' '/browser_download_url/ && /macos-arm64\.zip/ { print $4; exit }') \
    || die "could not reach GitHub to look up the latest release.
  Check your network, or download it by hand from
  https://github.com/$REPO/releases/latest"

  [[ -n $url ]] || die "the latest release has no macOS archive attached.
  Report this at https://github.com/$REPO/issues"

  ok "${url:t}" >&2

  step "Downloading" >&2
  curl -fL --progress-bar --max-time 900 -o "$workdir/OpenType.zip" "$url" \
    || die "download failed. Re-run to retry."

  ditto -x -k "$workdir/OpenType.zip" "$workdir/unpacked" \
    || die "the downloaded archive could not be expanded -- it may be truncated.
  Re-run to download it again."

  local app
  app=$(find "$workdir/unpacked" -maxdepth 2 -name "OpenType.app" -print -quit)
  [[ -n $app ]] || die "no OpenType.app inside the downloaded archive."
  print -r -- "$app"
}

main() {
  local dest_dir="/Applications"
  local skip_whisper=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --dest) shift; [ $# -gt 0 ] || die "--dest needs a directory"; dest_dir=$1 ;;
      --skip-whisper) skip_whisper=1 ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown argument '$1' (try --help)" ;;
    esac
    shift
  done

  # --- 1. Can this Mac run it? -------------------------------------------

  step "Checking this Mac"

  [ "$(uname -s)" = "Darwin" ] || die "OpenType is macOS-only."

  [ "$(uname -m)" = "arm64" ] || die "OpenType requires an Apple Silicon Mac.
  Its speech recognition is built on Apple's MLX framework, which has no Intel
  build. There is no workaround on this machine."
  ok "Apple Silicon"

  local macos_major
  macos_major=$(sw_vers -productVersion | cut -d. -f1)
  [ "$macos_major" -ge 13 ] || die "macOS 13 (Ventura) or newer required,
  found $(sw_vers -productVersion)."
  ok "macOS $(sw_vers -productVersion)"

  if [ "$skip_whisper" = "0" ] && ! command -v brew >/dev/null 2>&1; then
    die "Homebrew not found, and it's how this installer gets Python and ffmpeg.
  Install it from https://brew.sh and re-run, or re-run with --skip-whisper to
  set up a remote transcription service in the app instead."
  fi

  # --- 2. Get the app ----------------------------------------------------

  local workdir="" app_src="" here
  here=$(script_directory)

  if [[ -n $here && -d $here/OpenType.app ]]; then
    app_src="$here/OpenType.app"
    ok "using the OpenType.app next to this script"
  else
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/opentype-install.XXXXXX")
    # The temp dir holds a ~23 MB download; clear it however we exit.
    trap "rm -rf '$workdir'" EXIT INT TERM
    app_src=$(fetch_release "$workdir")
  fi

  local app_dest="$dest_dir/OpenType.app"

  # --- 3. Dependencies ---------------------------------------------------

  if [ "$skip_whisper" = "0" ]; then
    step "Installing dependencies"

    if brew --prefix python@3.12 >/dev/null 2>&1; then
      ok "python@3.12"
    else
      brew install python@3.12
      ok "python@3.12 installed"
    fi

    # mlx_whisper shells out to ffmpeg to decode audio. The app adds the
    # standard Homebrew locations to PATH when it launches the speech process,
    # because an app started from Finder inherits a minimal PATH without them.
    if command -v ffmpeg >/dev/null 2>&1; then
      ok "ffmpeg"
    else
      brew install ffmpeg
      ok "ffmpeg installed"
    fi
  fi

  # --- 4. Install the app ------------------------------------------------

  step "Installing OpenType.app to $dest_dir"

  mkdir -p "$dest_dir"

  # Reinstalling replaces the whole bundle, which would throw away a working
  # speech environment inside it. Set it aside first and put it back after, so
  # an upgrade doesn't reinstall over a gigabyte of Python packages.
  local stash=""
  if [ -x "$app_dest/Contents/Resources/whisper-env/bin/python3" ]; then
    if "$app_dest/Contents/Resources/whisper-env/bin/python3" -c "import mlx_whisper" >/dev/null 2>&1; then
      stash=$(mktemp -d "${TMPDIR:-/tmp}/opentype-venv.XXXXXX")
      mv "$app_dest/Contents/Resources/whisper-env" "$stash/whisper-env"
      ok "kept the existing speech environment for reuse"
    fi
  fi

  [ -d "$app_dest" ] && rm -rf "$app_dest"
  ditto "$app_src" "$app_dest"

  # A downloaded archive carries a quarantine flag that makes macOS refuse to
  # open an app that isn't notarized. This build is ad-hoc signed, so clear it.
  xattr -dr com.apple.quarantine "$app_dest" 2>/dev/null || true
  ok "installed"

  if [ -n "$stash" ] && [ -d "$stash/whisper-env" ]; then
    mv "$stash/whisper-env" "$app_dest/Contents/Resources/whisper-env"
    rmdir "$stash" 2>/dev/null || true
    ok "restored the existing speech environment"
  fi

  # --- 5. Local speech recognition ---------------------------------------

  local venv_dir="$app_dest/Contents/Resources/whisper-env"

  if [ "$skip_whisper" = "1" ]; then
    step "Skipping local speech recognition (--skip-whisper)"
    warn "configure a remote transcription service in the app's setup wizard"
  elif "$venv_dir/bin/python3" -c "import mlx_whisper" >/dev/null 2>&1; then
    step "Local speech recognition already set up"
    ok "reused"
  else
    step "Building the local speech environment (installs ~1.1 GB, takes a few minutes)"

    # Resolve Homebrew's python3.12 explicitly. A bare `python3` is the classic
    # mistake here: it resolves to the system Python 3.9, or to Xcode's bundled
    # one, and this stack needs 3.12 or newer.
    local brew_prefix python_bin="" candidate
    brew_prefix=$(brew --prefix python@3.12 2>/dev/null || true)
    for candidate in "$brew_prefix/bin/python3.12" "/opt/homebrew/bin/python3.12"; do
      [ -x "$candidate" ] && { python_bin=$candidate; break; }
    done
    [ -n "$python_bin" ] || die "Homebrew's python3.12 not found even after installing it.
  Try 'brew reinstall python@3.12' and re-run. Do not substitute a bare
  'python3' -- the system interpreter is too old for this software."

    rm -rf "$venv_dir"
    "$python_bin" -m venv --copies "$venv_dir"
    "$venv_dir/bin/pip" install --upgrade pip >/dev/null
    "$venv_dir/bin/pip" install mlx-whisper

    "$venv_dir/bin/python3" -c "import mlx_whisper" >/dev/null 2>&1 \
      || die "the speech environment was built but doesn't work.
  Re-run this installer; if it fails again, report it at
  https://github.com/$REPO/issues"
    ok "local speech recognition ready"
  fi

  # --- 6. Re-sign --------------------------------------------------------
  #
  # Adding the venv changed the bundle's contents, which invalidates its code
  # signature. An app with a broken signature can be refused at launch, and
  # macOS binds microphone / accessibility permissions to the signature, so
  # this has to match what the build used: the same stable designated
  # requirement, and the inner sidecar binary signed on its own (signing it
  # via --deep on the outer app corrupts it).

  step "Re-signing the app"
  codesign --force --sign - "$app_dest/Contents/Resources/opentype-sidecar"
  codesign --force --sign - \
    --requirements '=designated => identifier "ai.rain.opentype"' \
    "$app_dest"
  codesign --verify --strict "$app_dest" \
    || die "the installed app fails signature verification -- macOS will likely
  refuse to open it. Re-run this installer."
  ok "signature valid"

  # --- Done --------------------------------------------------------------

  cat <<EOF

$(print -P "%F{green}OpenType is installed.%f")  $app_dest

Three things left, and only you can do them:

  1. Open it:   open "$app_dest"

  2. Grant two permissions when macOS asks. Both are required:
       - Microphone     — to hear you
       - Accessibility  — to type the result into whatever app you're using
     If you miss the prompts, go to System Settings -> Privacy & Security.
     Accessibility almost always has to be switched on by hand there.

  3. Finish the setup wizard in the app: pick your speech-to-text source, and
     add an LLM API key if you want the Ask and Agent modes. Plain dictation
     needs no key and no network.

The first time you actually transcribe something, it downloads a ~460 MB
speech model. That happens once, and a long pause there is not a crash.

EOF
}

main "$@"
