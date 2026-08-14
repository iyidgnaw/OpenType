#!/bin/zsh
#
# One-shot, idempotent setup for a fresh clone of OpenType.
#
# Safe to re-run: every step checks whether it is already done and skips it if
# so, so this doubles as a repair/verify pass on an existing checkout. Nothing
# here is destructive -- if something is present but broken, the script says so
# and tells you the exact command to fix it rather than deleting it for you.
#
# Usage:
#   ./scripts/setup.sh                 # full setup: deps + local Whisper + build the .app
#   ./scripts/setup.sh --skip-whisper  # skip the local MLX-Whisper venv (remote-Whisper users)
#   ./scripts/setup.sh --no-build      # install dependencies only, don't build the .app
#   ./scripts/setup.sh --check         # verify an existing setup, change nothing
#
set -euo pipefail

# Captured at top level: inside a zsh function `$0` is the function's own name,
# not the script path, so usage() cannot re-derive either of these itself.
script_path=${0:A}
project_dir=${script_path:h:h}
cd "$project_dir"

skip_whisper=0
no_build=0
check_only=0

# Prints the header comment block (skipping the shebang) as the help text, so
# usage and the file's own documentation can never drift apart.
usage() {
  awk 'NR>2 && /^#/ { sub(/^# ?/, ""); print; next } NR>2 { exit }' "$script_path"
}

for arg in "$@"; do
  case "$arg" in
    --skip-whisper) skip_whisper=1 ;;
    --no-build) no_build=1 ;;
    --check) check_only=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$arg' (try --help)" >&2; exit 2 ;;
  esac
done

step()  { print -P "%F{cyan}==>%f $1"; }
ok()    { print -P "  %F{green}ok%f  $1"; }
skip()  { print -P "  %F{yellow}--%f  $1"; }
warn()  { print -P "  %F{yellow}!!%f  $1" >&2; }
die()   { print -P "%F{red}error:%f $1" >&2; exit 1; }

# In --check mode every mutating action becomes a reported failure instead, so
# the script can be used as a pure diagnostic by a setup agent.
needs() {
  if [ "$check_only" = "1" ]; then
    die "$1 (run ./scripts/setup.sh without --check to fix)"
  fi
}

# --- 1. Preflight: things we cannot install for you ----------------------

step "Checking prerequisites"

[ "$(uname -s)" = "Darwin" ] || die "OpenType is macOS-only (found $(uname -s))."

if [ "$(uname -m)" != "arm64" ]; then
  die "OpenType requires an Apple Silicon Mac. The local speech-recognition
  engine (MLX-Whisper) is built on Apple's MLX framework, which has no Intel
  build -- there is no workaround on this machine."
fi
ok "Apple Silicon"

macos_major=$(sw_vers -productVersion | cut -d. -f1)
if [ "$macos_major" -lt 13 ]; then
  die "macOS 13 (Ventura) or newer required, found $(sw_vers -productVersion)."
fi
ok "macOS $(sw_vers -productVersion)"

if ! xcode-select -p >/dev/null 2>&1; then
  die "Xcode command line tools not installed. Run:  xcode-select --install
  then re-run this script once the installer finishes."
fi
ok "Xcode command line tools"

command -v swift >/dev/null 2>&1 || die "swift not found on PATH even though
  Xcode command line tools are installed -- try 'sudo xcode-select --reset'."
ok "swift $(swift --version 2>/dev/null | head -1 | sed -E 's/.*version ([0-9.]+).*/\1/')"

if ! command -v brew >/dev/null 2>&1; then
  die "Homebrew not found. Install it from https://brew.sh, then re-run this
  script. (Homebrew is how this script installs bun, python@3.12 and ffmpeg.)"
fi
ok "Homebrew"

# --- 2. Homebrew packages ------------------------------------------------

step "Checking Homebrew packages"

ensure_brew_pkg() {
  local formula=$1 probe=$2 why=$3
  if eval "$probe" >/dev/null 2>&1; then
    ok "$formula"
    return
  fi
  needs "$formula is not installed ($why)"
  step "Installing $formula ($why)"
  brew install "$formula"
  eval "$probe" >/dev/null 2>&1 \
    || die "installed $formula but $probe still fails -- check 'brew doctor'."
  ok "$formula"
}

ensure_brew_pkg "oven-sh/bun/bun" "command -v bun" "runs the sidecar"
ensure_brew_pkg "python@3.12" "brew --prefix python@3.12" "runs local Whisper"

# ffmpeg is a genuine runtime dependency, not a build-time one: mlx_whisper's
# transcribe() shells out to it to decode audio. The sidecar appends the
# standard Homebrew locations to PATH before spawning the Whisper process
# (see sidecar/src/asr/whisperClient.ts) precisely because a GUI-launched app
# inherits a minimal PATH that would not otherwise find it.
if [ "$skip_whisper" = "0" ]; then
  ensure_brew_pkg "ffmpeg" "command -v ffmpeg" "local Whisper decodes audio with it"

  ffmpeg_path=$(command -v ffmpeg)
  case "$ffmpeg_path" in
    /opt/homebrew/bin/*|/opt/homebrew/sbin/*|/usr/local/bin/*) ;;
    *)
      warn "ffmpeg resolved to $ffmpeg_path, which is outside the three
      directories the sidecar adds to PATH for GUI launches (/opt/homebrew/bin,
      /opt/homebrew/sbin, /usr/local/bin). Local transcription may fail when the
      app is launched from Finder. See sidecar/src/asr/whisperClient.ts."
      ;;
  esac
fi

# --- 3. Sidecar dependencies --------------------------------------------

step "Sidecar dependencies (bun)"

if [ -d "$project_dir/sidecar/node_modules" ] && [ "$check_only" = "1" ]; then
  ok "sidecar/node_modules present"
else
  needs "sidecar dependencies not installed"
  (cd "$project_dir/sidecar" && bun install)
  ok "sidecar dependencies"
fi

# --- 4. Local Whisper environment ---------------------------------------
#
# The venv is deliberately built here, on this machine, rather than shipped:
# a Python venv hardcodes absolute paths to the interpreter that created it,
# so one built elsewhere would not run here.

venv_dir="$project_dir/sidecar/whisper-env"

if [ "$skip_whisper" = "1" ]; then
  step "Skipping local Whisper setup (--skip-whisper)"
  skip "configure a remote transcription provider in the app's setup wizard"
else
  step "Setting up local Whisper (MLX-Whisper)"

  # Resolve Homebrew's python@3.12 explicitly. A bare `python3` is the classic
  # failure here: on many Macs it resolves to Xcode's bundled interpreter or to
  # the system Python 3.9, and this stack's floor is 3.12 (scipy requires
  # >=3.12; mlx, numba and llvmlite require >=3.10).
  brew_python_prefix=$(brew --prefix python@3.12 2>/dev/null || true)
  python_bin=""
  for candidate in "$brew_python_prefix/bin/python3.12" "/opt/homebrew/bin/python3.12"; do
    if [ -x "$candidate" ]; then
      python_bin=$candidate
      break
    fi
  done
  [ -n "$python_bin" ] && ok "interpreter $python_bin" \
    || die "could not find Homebrew's python3.12 even though 'brew --prefix
  python@3.12' succeeded. Try 'brew reinstall python@3.12'. Do NOT fall back to
  a bare 'python3' -- the system interpreter is too old for this stack."

  if [ -x "$venv_dir/bin/python3" ]; then
    ok "venv exists at sidecar/whisper-env"
  else
    needs "local Whisper venv missing"
    step "Creating venv (this downloads ~500 MB of packages, give it a few minutes)"
    "$python_bin" -m venv --copies "$venv_dir"
    ok "venv created"
  fi

  # Verify by importing, not by checking that a directory exists -- a venv can
  # be present but unusable (interrupted install, interpreter upgraded out from
  # under it), and that failure is far harder to diagnose once it is wrapped
  # inside the packaged app.
  if "$venv_dir/bin/python3" -c "import mlx_whisper" >/dev/null 2>&1; then
    ok "mlx-whisper imports cleanly"
  else
    needs "mlx-whisper is not installed or not importable"
    step "Installing mlx-whisper into the venv"
    "$venv_dir/bin/pip" install --upgrade pip >/dev/null
    "$venv_dir/bin/pip" install mlx-whisper
    "$venv_dir/bin/python3" -c "import mlx_whisper" >/dev/null 2>&1 || die \
      "mlx-whisper still fails to import after installing. The venv is likely
  broken; remove it and re-run this script:
      rm -rf sidecar/whisper-env && ./scripts/setup.sh"
    ok "mlx-whisper installed"
  fi
fi

# --- 5. Build the app ----------------------------------------------------

app_dir="$project_dir/dist/OpenType.app"

if [ "$check_only" = "1" ]; then
  step "Checking build output"
  if [ -d "$app_dir" ]; then ok "dist/OpenType.app present"; else warn "dist/OpenType.app not built yet"; fi
  print -P "\n%F{green}Check complete.%f"
  exit 0
fi

if [ "$no_build" = "1" ]; then
  step "Skipping app build (--no-build)"
  print -P "\n%F{green}Dependencies ready.%f Build later with: ./scripts/build-app.sh"
  exit 0
fi

step "Building OpenType.app (first build resolves SwiftPM packages -- needs network)"
"$project_dir/scripts/build-app.sh"

[ -d "$app_dir" ] || die "build-app.sh finished but $app_dir does not exist."

# --- 6. What to do next --------------------------------------------------

cat <<EOF

$(print -P "%F{green}Setup complete.%f")  Built: dist/OpenType.app

Next steps:

  1. Install it:   cp -R dist/OpenType.app /Applications/
     (Running it from /Applications keeps macOS permissions stable.)

  2. Launch it:    open /Applications/OpenType.app

  3. Grant permissions when macOS asks -- both are required:
       - Microphone      (to record your voice)
       - Accessibility   (to insert text into the app you're typing in)
     If you miss the prompts: System Settings -> Privacy & Security.
     Accessibility in particular must be enabled by hand there.

  4. Finish setup in the app's first-run wizard: choose local or remote
     speech-to-text, then add an LLM API key if you want Ask/Agent modes.
     Plain dictation works without any API key.

  Note: the first transcription downloads the Whisper model (~460 MB) and
  takes a while. That is a one-time cost, not a hang.

EOF
