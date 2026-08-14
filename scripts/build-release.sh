#!/bin/zsh
#
# Builds the distributable release archive that users download instead of
# cloning this repo.
#
# What ends up in the archive: the built OpenType.app, an install.sh that
# finishes setup on the user's machine, and a short INSTALL.md.
#
# What deliberately does NOT end up in it: the local Whisper Python
# environment. A venv records absolute paths to the interpreter that created
# it -- `whisper-env/bin/python3` links against this build machine's
# /opt/homebrew/Cellar/python@3.12/<exact version>/... and the venv carries no
# standard library of its own -- so a venv built here cannot run anywhere else.
# Shipping it would produce an app whose local speech recognition is dead on
# arrival on every machine but this one. install.sh rebuilds it locally instead,
# which is also why the archive is ~74 MB rather than ~1.2 GB.
#
# Usage:
#   ./scripts/build-release.sh            # -> dist/OpenType-<version>-macos-arm64.zip
#
set -euo pipefail

script_path=${0:A}
project_dir=${script_path:h:h}
cd "$project_dir"

REPO_SLUG="iyidgnaw/OpenType"
INSTALL_URL="https://opentype-site.vercel.app/install"
AGENT_URL="https://opentype-site.vercel.app/agent"

step() { print -P "%F{cyan}==>%f $1"; }
ok()   { print -P "  %F{green}ok%f  $1"; }
die()  { print -P "%F{red}error:%f $1" >&2; exit 1; }

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$project_dir/Resources/Info.plist" 2>/dev/null) \
  || die "could not read CFBundleShortVersionString from Resources/Info.plist"

app_dir="$project_dir/dist/OpenType.app"
staging="$project_dir/dist/release/OpenType-$version"
archive="$project_dir/dist/OpenType-$version-macos-arm64.zip"

step "Building OpenType.app $version"
"$project_dir/scripts/build-app.sh"
[ -d "$app_dir" ] || die "build-app.sh did not produce $app_dir"

# Removing files from a signed bundle breaks its code signature seal, so the
# strip and the re-sign are one indivisible step. The designated requirement
# matches build-app.sh's so macOS keeps binding TCC (microphone / accessibility)
# permissions to a stable identity across reinstalls.
step "Stripping the non-portable Whisper venv and re-signing"
rm -rf "$app_dir/Contents/Resources/whisper-env"
codesign --force --sign - \
  --requirements '=designated => identifier "ai.rain.opentype"' \
  "$app_dir"
codesign --verify --strict "$app_dir" || die "re-signed bundle fails verification"
ok "signature valid"

# The archive carries the app and a note, not the installer: install.sh always
# fetches the current release itself, so a copy shipped inside one particular
# release would be a stale copy of a script whose whole job is to go get the
# newest thing.
step "Staging the archive contents"
rm -rf "$project_dir/dist/release"
mkdir -p "$staging"
ditto "$app_dir" "$staging/OpenType.app"

cat > "$staging/INSTALL.md" <<EOF
# OpenType $version — install

Requires an Apple Silicon Mac running macOS 13 or newer.

**Do not install by dragging OpenType.app into /Applications.** On its own it
cannot transcribe anything: speech recognition needs a Python environment that
has to be built on this Mac, because a prebuilt one hardcodes absolute paths to
the machine that created it and will not run anywhere else.

Open Terminal and run:

    curl -fsSL $INSTALL_URL | zsh

That fetches the current release, installs it into /Applications, installs the
dependencies (Homebrew's python@3.12 and ffmpeg), builds the speech
environment, and signs the result. It asks where speech recognition should
run — press Return for the on-device default. It is safe to re-run.

Prefer to have a coding agent do it, permissions and in-app setup included?
Give Claude Code / Codex / Cursor this:

    Please fetch the instructions at $AGENT_URL
    and follow them to install OpenType on this Mac for me.

Afterwards you grant two macOS permissions (microphone and accessibility) and
finish a short in-app wizard. Plain dictation needs no API key; the Ask and
Agent modes need an LLM provider key you supply there.

Homepage and source: https://github.com/$REPO_SLUG
EOF

step "Packing"
rm -f "$archive"
# ditto -c -k is the macOS-native zip: it preserves symlinks, resource forks
# and the code signature's extended attributes, which /usr/bin/zip does not.
ditto -c -k --keepParent "$staging" "$archive"

size=$(du -h "$archive" | cut -f1)
ok "$archive ($size)"

cat <<EOF

Release built. To publish it:

  gh release create v$version "$archive" \\
    --title "OpenType $version" --notes-file <(...)

Reminder: this archive is ad-hoc signed, not notarized. macOS will warn on
first launch unless the user removes the quarantine attribute — install.sh
does that for them.
EOF
