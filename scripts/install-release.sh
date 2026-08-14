#!/bin/zsh
#
# OpenType installer.
#
#   curl -fsSL https://opentype-site.vercel.app/install | zsh
#
# Options (through a pipe, pass them after `zsh -s --`):
#   --dest DIR        install into DIR instead of /Applications
#   --skip-whisper    no local speech recognition; configure a remote service in the app
#
# It fetches the latest release itself, so there is nothing to download by hand.
# Safe to re-run: an existing working speech environment is kept rather than
# rebuilt.
#
# zsh rather than sh: this uses zsh parameter expansion and prompt escapes, and
# zsh is macOS's default shell, so it is present on every Mac that can run
# OpenType.
#
# Everything below lives inside main(), called on the last line. A pipe feeds
# the shell as bytes arrive, so a connection that drops halfway would otherwise
# leave it executing whatever fragment turned up -- possibly a half-written
# destructive command. With the body in a function, a truncated download
# defines main and never calls it.

set -euo pipefail

REPO="iyidgnaw/OpenType"
API_LATEST="https://api.github.com/repos/$REPO/releases/latest"
TOTAL_STEPS=6

# --- output ---------------------------------------------------------------
#
# One voice for the whole run: a numbered step header, indented detail beneath
# it. The user should always be able to tell what is happening and how much is
# left, especially during the two multi-minute waits.

step_no=0

rule()    { print -P "  %F{8}────────────────────────────────────────────%f"; }
title()   { print -P "\n  %F{cyan}%BOpenType installer%b%f"; rule; }
step()    { step_no=$((step_no + 1))
            print -P "\n  %F{cyan}[$step_no/$TOTAL_STEPS]%f %B$1%b" }
detail()  { print -P "        %F{8}$1%f" }
ok()      { print -P "        %F{green}✓%f $1" }
warn()    { print -P "        %F{yellow}!%f $1" >&2 }
die()     { print -P "\n  %F{red}✗ $1%f\n" >&2; exit 1 }

# Renders 137 -> "2m 17s", 45 -> "45s". Uses $SECONDS, a zsh builtin, so the
# script needs no date command.
elapsed() {
  local s=$1
  (( s < 60 )) && { print -r -- "${s}s"; return }
  print -r -- "$((s / 60))m $((s % 60))s"
}

# Downloads $1 to $2, drawing a progress bar aligned with everything else.
# curl's own --progress-bar writes carriage-returns at column zero and opens
# with a burst of connection noise, which reads as something having gone wrong
# in the middle of an otherwise orderly run. Polling the partial file's size
# keeps the output in one voice, and still degrades gracefully into a byte
# counter when the server declines to send a Content-Length.
download() {
  local url=$1 out=$2 total="" pid now pct filled bar
  total=$(curl -fsIL --max-time 30 "$url" 2>/dev/null \
    | awk 'tolower($1) == "content-length:" { print $2 }' | tr -d '\r' | tail -1)

  # Redrawing in place only makes sense on a terminal. Piped into a file or a
  # CI log, carriage returns just pile up as noise, so say it once instead.
  if [[ ! -t 1 ]]; then
    detail "downloading…"
    curl -fsSL --max-time 900 -o "$out" "$url"
    return
  fi

  curl -fsSL --max-time 900 -o "$out" "$url" &
  pid=$!

  while kill -0 $pid 2>/dev/null; do
    now=0
    [[ -f $out ]] && now=$(stat -f%z "$out" 2>/dev/null || print 0)
    if [[ -n $total ]] && (( total > 0 )); then
      pct=$(( now * 100 / total ))
      (( pct > 100 )) && pct=100
      filled=$(( pct * 28 / 100 ))
      bar=""
      (( filled > 0 )) && bar=$(printf '%.0s━' {1..$filled})
      printf '\r        %-28s %3d%%' "$bar" "$pct"
    else
      printf '\r        %s' "$(( now / 1048576 )) MB"
    fi
    sleep 0.2
  done

  # Clear the meter so the ✓ line lands on a clean row.
  printf '\r%-50s\r' ""
  wait $pid
}

# Asks where speech recognition should run, and sets skip_whisper.
#
# Reading from /dev/tty rather than stdin is the whole trick: piped from curl,
# stdin *is* the script, so a plain `read` would swallow the rest of this file.
# Where there is no terminal at all -- CI, or output redirected -- there is
# nobody to ask, so the default stands.
choose_speech_mode() {
  (( skip_whisper )) && return   # already answered on the command line

  if [[ ! -r /dev/tty ]]; then
    detail "no terminal to ask on — using on-device recognition (the default)"
    return
  fi

  print -P "\n  %BWhere should speech recognition run?%b\n"
  print -P "    %F{green}1%f  On this Mac %F{8}(default)%f"
  print -P "       %F{8}Free, private, works offline. Adds a few minutes to this install%f"
  print -P "       %F{8}and about 1.1 GB of disk.%f\n"
  print -P "    %F{green}2%f  On a remote service"
  print -P "       %F{8}Nothing extra to install now, but afterwards you must paste a%f"
  print -P "       %F{8}transcription API URL and key into the app, and every recording%f"
  print -P "       %F{8}makes a network round trip, so it is noticeably slower.%f\n"
  print -P "  %F{8}Not sure what this means? Press Return and take the default.%f"

  local reply=""
  printf '\n  Choice [1]: '
  read -r reply < /dev/tty || reply=""

  case "${reply:l}" in
    2|remote|r)
      skip_whisper=1
      print -P "\n        %F{yellow}!%f Remote it is. Remember: you'll need a transcription"
      print -P "          API URL and key, and it will be slower than on-device."
      ;;
    *)
      print -P "\n        %F{green}✓%f On this Mac"
      ;;
  esac
}

usage() {
  cat <<'USAGE'
OpenType installer.

  curl -fsSL https://opentype-site.vercel.app/install | zsh

Options (through a pipe, pass them after `zsh -s --`):
  --dest DIR        install into DIR instead of /Applications
  --skip-whisper    skip local speech recognition (use a remote service instead)
  -h, --help        show this
USAGE
}

main() {
  local dest_dir="/Applications"
  local skip_whisper=0
  local started=$SECONDS

  while [ $# -gt 0 ]; do
    case "$1" in
      --dest) shift; [ $# -gt 0 ] || die "--dest needs a directory"; dest_dir=$1 ;;
      --skip-whisper) skip_whisper=1 ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown argument '$1' (try --help)" ;;
    esac
    shift
  done

  title

  # --- 1. Can this Mac run it? -------------------------------------------

  step "Checking this Mac"

  [ "$(uname -s)" = "Darwin" ] || die "OpenType is macOS-only."

  [ "$(uname -m)" = "arm64" ] || die "OpenType needs an Apple Silicon Mac.
     Its speech recognition is built on Apple's MLX framework, which has no
     Intel build, so there is no workaround on this machine."

  local macos_version macos_major
  macos_version=$(sw_vers -productVersion)
  macos_major=${macos_version%%.*}
  [ "$macos_major" -ge 13 ] || die "macOS 13 (Ventura) or newer required, found $macos_version."
  ok "Apple Silicon · macOS $macos_version"

  # Ask before anything is downloaded or installed, so the answer can still
  # change what happens -- and check Homebrew only once we know it is needed.
  choose_speech_mode

  if [ "$skip_whisper" = "0" ] && ! command -v brew >/dev/null 2>&1; then
    die "Homebrew not found, and it is how this installer gets Python and ffmpeg
     for on-device recognition. Install it from https://brew.sh and run this
     again, or run this again and choose option 2 to use a remote service."
  fi

  # --- 2. Fetch the release ----------------------------------------------

  step "Fetching the latest release"

  local workdir
  workdir=$(mktemp -d "${TMPDIR:-/tmp}/opentype-install.XXXXXX")
  # Holds a ~23 MB download; clear it however this exits.
  trap "rm -rf '$workdir'" EXIT INT TERM

  local url
  url=$(curl -fsSL --max-time 60 "$API_LATEST" \
    | awk -F'"' '/browser_download_url/ && /macos-arm64\.zip/ { print $4; exit }') \
    || die "could not reach GitHub to look up the latest release.
     Check your network and try again."
  [[ -n $url ]] || die "the latest release has no macOS archive attached.
     Please report this at https://github.com/$REPO/issues"

  detail "${url:t}"
  download "$url" "$workdir/OpenType.zip" \
    || die "the download failed. Run this again to retry."

  ditto -x -k "$workdir/OpenType.zip" "$workdir/unpacked" \
    || die "the download could not be expanded -- it may be incomplete.
     Run this again to fetch it fresh."

  local app_src
  app_src=$(find "$workdir/unpacked" -maxdepth 2 -name "OpenType.app" -print -quit)
  [[ -n $app_src ]] || die "no OpenType.app inside the downloaded archive."
  ok "downloaded ($(du -h "$workdir/OpenType.zip" | cut -f1 | tr -d ' '))"

  # --- 3. Dependencies ---------------------------------------------------

  step "Installing dependencies"

  if [ "$skip_whisper" = "1" ]; then
    detail "skipped — you chose remote speech recognition"
  else
    if brew --prefix python@3.12 >/dev/null 2>&1; then
      ok "python@3.12 already installed"
    else
      detail "installing python@3.12 via Homebrew…"
      brew install python@3.12 >/dev/null 2>&1 || brew install python@3.12
      ok "python@3.12"
    fi

    # mlx_whisper shells out to ffmpeg to decode audio. The app adds the standard
    # Homebrew locations to PATH when it launches the speech process, because an
    # app started from Finder inherits a minimal PATH without them.
    if command -v ffmpeg >/dev/null 2>&1; then
      ok "ffmpeg already installed"
    else
      detail "installing ffmpeg via Homebrew… (this one can take a few minutes)"
      brew install ffmpeg >/dev/null 2>&1 || brew install ffmpeg
      ok "ffmpeg"
    fi
  fi

  # --- 4. Install the app ------------------------------------------------

  step "Installing OpenType.app"

  local app_dest="$dest_dir/OpenType.app"
  mkdir -p "$dest_dir"

  # Reinstalling replaces the whole bundle, which would throw away a working
  # speech environment inside it. Set it aside and put it back, so an upgrade
  # doesn't reinstall over a gigabyte of Python packages.
  local stash=""
  if [ -x "$app_dest/Contents/Resources/whisper-env/bin/python3" ] \
     && "$app_dest/Contents/Resources/whisper-env/bin/python3" -c "import mlx_whisper" >/dev/null 2>&1; then
    stash=$(mktemp -d "${TMPDIR:-/tmp}/opentype-venv.XXXXXX")
    mv "$app_dest/Contents/Resources/whisper-env" "$stash/whisper-env"
    detail "keeping the speech environment already installed here"
  fi

  [ -d "$app_dest" ] && rm -rf "$app_dest"
  ditto "$app_src" "$app_dest"

  # A downloaded archive carries a quarantine flag that makes macOS refuse to
  # open an app that isn't notarized. This build is ad-hoc signed, so clear it.
  xattr -dr com.apple.quarantine "$app_dest" 2>/dev/null || true

  if [ -n "$stash" ] && [ -d "$stash/whisper-env" ]; then
    mv "$stash/whisper-env" "$app_dest/Contents/Resources/whisper-env"
    rmdir "$stash" 2>/dev/null || true
  fi
  ok "$app_dest"

  # --- 5. Local speech recognition ---------------------------------------

  step "Setting up speech recognition"

  local venv_dir="$app_dest/Contents/Resources/whisper-env"

  if [ "$skip_whisper" = "1" ]; then
    detail "skipped — configure a remote service in the app's setup wizard"
  elif "$venv_dir/bin/python3" -c "import mlx_whisper" >/dev/null 2>&1; then
    ok "reused the environment already installed here"
  else
    detail "Installing about 1.1 GB of Python packages."
    detail "This is the slow part — a few minutes is normal. Progress below:"
    print ""

    # Resolve Homebrew's python3.12 explicitly. A bare `python3` is the classic
    # mistake here: it resolves to the system Python 3.9, or to Xcode's bundled
    # one, and this stack needs 3.12 or newer.
    local brew_prefix python_bin="" candidate
    brew_prefix=$(brew --prefix python@3.12 2>/dev/null || true)
    for candidate in "$brew_prefix/bin/python3.12" "/opt/homebrew/bin/python3.12"; do
      [ -x "$candidate" ] && { python_bin=$candidate; break }
    done
    [ -n "$python_bin" ] || die "Homebrew's python3.12 is missing even after installing it.
     Try 'brew reinstall python@3.12' and run this again. Do not substitute a
     bare 'python3' -- the system interpreter is too old for this software."

    local venv_started=$SECONDS
    rm -rf "$venv_dir"
    "$python_bin" -m venv --copies "$venv_dir"
    "$venv_dir/bin/pip" install --upgrade pip >/dev/null 2>&1 || true
    "$venv_dir/bin/pip" install --progress-bar on mlx-whisper 2>&1 \
      | sed -u 's/^/        /' \
      || die "installing mlx-whisper failed. Check the output above, then run this again."

    print ""
    "$venv_dir/bin/python3" -c "import mlx_whisper" >/dev/null 2>&1 \
      || die "the speech environment was built but does not work.
     Run this again; if it fails the same way, please report it at
     https://github.com/$REPO/issues"
    ok "ready ($(elapsed $((SECONDS - venv_started))))"
  fi

  # --- 6. Re-sign --------------------------------------------------------
  #
  # Adding the speech environment changed the bundle's contents, which
  # invalidates its code signature. An app with a broken signature can be
  # refused at launch, and macOS binds microphone / accessibility permissions
  # to the signature, so this has to match what the build used: the same stable
  # designated requirement, and the inner sidecar binary signed on its own
  # (signing it via --deep on the outer app corrupts it).

  step "Signing"

  codesign --force --sign - "$app_dest/Contents/Resources/opentype-sidecar" 2>/dev/null
  codesign --force --sign - \
    --requirements '=designated => identifier "ai.rain.opentype"' \
    "$app_dest" 2>/dev/null
  codesign --verify --strict "$app_dest" 2>/dev/null \
    || die "the installed app fails signature verification, and macOS will
     probably refuse to open it. Run this installer again."
  ok "signature valid"

  # --- Done --------------------------------------------------------------

  print -P "\n  %F{green}%BInstalled in $(elapsed $((SECONDS - started))).%b%f"
  rule
  cat <<EOF

  Three things left, and only you can do them:

    1  Open it
       open "$app_dest"

    2  Grant two permissions when macOS asks — both are required
       · Microphone      to hear you
       · Accessibility   to type the result into whatever app you're using
       Missed the prompts? System Settings → Privacy & Security.
       Accessibility almost always has to be switched on by hand there.
EOF

  if (( skip_whisper )); then
    cat <<EOF

    3  Set up transcription in the app — it will not work until you do
       You chose a remote service, so nothing on this Mac can transcribe
       yet. In the app's setup wizard, under 语音识别, choose the remote
       option and paste your transcription API URL and key, then use Test
       Connection to confirm it works. Expect it to be slower than
       on-device recognition, since every recording is uploaded first.

       Changed your mind? Run this installer again and pick option 1.
EOF
  else
    cat <<EOF

    3  Finish the setup wizard in the app
       Speech recognition is already set up and runs on this Mac. Add an
       LLM API key only if you want the Ask and Agent modes — plain
       dictation needs neither a key nor a network connection.

  The first thing you transcribe downloads a ~460 MB speech model. That
  happens once, and a long pause there is not a crash.
EOF
  fi
  print ""
}

main "$@"
