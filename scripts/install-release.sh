#!/bin/zsh
#
# OpenType installer. Ships inside the release archive as install.sh, next to
# OpenType.app, and is what a user (or their coding agent) runs after
# unzipping. Safe to re-run.
#
# What it does:
#   1. checks this Mac can run OpenType at all
#   2. installs python@3.12 and ffmpeg via Homebrew
#   3. copies OpenType.app into /Applications and clears the download quarantine
#   4. builds the local speech-recognition environment inside the app
#   5. re-signs the app, because step 4 changed its contents
#
# Step 4 exists because a Python virtual environment hardcodes absolute paths
# to the interpreter that created it, so it cannot be shipped prebuilt -- it
# has to be created on the machine that will run it. It lands at about 1.1 GB;
# most of that is mlx-whisper's dependency tree, not mlx-whisper itself, which
# is under 2 MB. The speech model is separate again: ~460 MB fetched into
# ~/.cache/huggingface the first time something is actually transcribed.
#
# Usage:
#   ./install.sh                  # install to /Applications
#   ./install.sh --dest DIR       # install into DIR instead (for testing)
#   ./install.sh --skip-whisper   # no local speech recognition; you'll configure
#                                 # a remote transcription service in the app
#
set -euo pipefail

script_path=${0:A}
here=${script_path:h}

dest_dir="/Applications"
skip_whisper=0

usage() {
  awk 'NR>2 && /^#/ { sub(/^# ?/, ""); print; next } NR>2 { exit }' "$script_path"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dest) shift; [ $# -gt 0 ] || { echo "error: --dest needs a directory" >&2; exit 2; }; dest_dir=$1 ;;
    --skip-whisper) skip_whisper=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
done

step() { print -P "%F{cyan}==>%f $1"; }
ok()   { print -P "  %F{green}ok%f  $1"; }
warn() { print -P "  %F{yellow}!!%f  $1" >&2; }
die()  { print -P "%F{red}error:%f $1" >&2; exit 1; }

app_src="$here/OpenType.app"
app_dest="$dest_dir/OpenType.app"

[ -d "$app_src" ] || die "OpenType.app not found next to this script.
  Run install.sh from inside the unzipped release folder, without moving it."

# --- 1. Can this Mac run it? --------------------------------------------

step "Checking this Mac"

[ "$(uname -s)" = "Darwin" ] || die "OpenType is macOS-only."

[ "$(uname -m)" = "arm64" ] || die "OpenType requires an Apple Silicon Mac.
  Its speech recognition is built on Apple's MLX framework, which has no
  Intel build. There is no workaround on this machine."
ok "Apple Silicon"

macos_major=$(sw_vers -productVersion | cut -d. -f1)
[ "$macos_major" -ge 13 ] || die "macOS 13 (Ventura) or newer required,
  found $(sw_vers -productVersion)."
ok "macOS $(sw_vers -productVersion)"

if [ "$skip_whisper" = "0" ] && ! command -v brew >/dev/null 2>&1; then
  die "Homebrew not found, and it's how this installer gets Python and ffmpeg.
  Install it from https://brew.sh and re-run, or re-run with --skip-whisper to
  set up a remote transcription service in the app instead."
fi

# --- 2. Dependencies -----------------------------------------------------

if [ "$skip_whisper" = "0" ]; then
  step "Installing dependencies"

  if brew --prefix python@3.12 >/dev/null 2>&1; then
    ok "python@3.12"
  else
    brew install python@3.12
    ok "python@3.12 installed"
  fi

  # mlx_whisper shells out to ffmpeg to decode audio. The app adds the standard
  # Homebrew locations to PATH when it launches the speech process, because an
  # app started from Finder inherits a minimal PATH that would not find it.
  if command -v ffmpeg >/dev/null 2>&1; then
    ok "ffmpeg"
  else
    brew install ffmpeg
    ok "ffmpeg installed"
  fi
fi

# --- 3. Install the app --------------------------------------------------

step "Installing OpenType.app to $dest_dir"

mkdir -p "$dest_dir"

# Reinstalling replaces the whole bundle, which would throw away a working
# speech environment inside it. Set it aside first and put it back after, so
# an upgrade doesn't re-download several hundred MB of Python packages.
stash=""
if [ -x "$app_dest/Contents/Resources/whisper-env/bin/python3" ]; then
  if "$app_dest/Contents/Resources/whisper-env/bin/python3" -c "import mlx_whisper" >/dev/null 2>&1; then
    stash=$(mktemp -d "${TMPDIR:-/tmp}/opentype-venv.XXXXXX")
    mv "$app_dest/Contents/Resources/whisper-env" "$stash/whisper-env"
    ok "kept the existing speech environment for reuse"
  fi
fi

if [ -d "$app_dest" ]; then
  rm -rf "$app_dest"
fi
ditto "$app_src" "$app_dest"

# A downloaded archive carries a quarantine flag that makes macOS refuse to
# open an app that isn't notarized. This build is ad-hoc signed, so clear it.
xattr -dr com.apple.quarantine "$app_dest" 2>/dev/null || true
ok "installed"

if [ -n "$stash" ] && [ -d "$stash/whisper-env" ]; then
  mv "$stash/whisper-env" "$app_dest/Contents/Resources/whisper-env"
  rmdir "$stash" 2>/dev/null || true
  stash=""
  ok "restored the existing speech environment"
fi

# --- 4. Local speech recognition ----------------------------------------

venv_dir="$app_dest/Contents/Resources/whisper-env"

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
  brew_prefix=$(brew --prefix python@3.12 2>/dev/null || true)
  python_bin=""
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
  https://github.com/iyidgnaw/OpenType/issues"
  ok "local speech recognition ready"
fi

# --- 5. Re-sign ----------------------------------------------------------
#
# Adding the venv changed the bundle's contents, which invalidates its code
# signature. An app with a broken signature can be refused at launch, and
# macOS binds microphone / accessibility permissions to the signature, so this
# has to match what the build used: the same stable designated requirement,
# and the inner sidecar binary signed on its own (signing it via --deep on the
# outer app corrupts it).

step "Re-signing the app"
codesign --force --sign - "$app_dest/Contents/Resources/opentype-sidecar"
codesign --force --sign - \
  --requirements '=designated => identifier "ai.rain.opentype"' \
  "$app_dest"
codesign --verify --strict "$app_dest" \
  || die "the installed app fails signature verification -- macOS will likely
  refuse to open it. Re-run this installer."
ok "signature valid"

# --- Done ----------------------------------------------------------------

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
