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

step "Staging the archive contents"
rm -rf "$project_dir/dist/release"
mkdir -p "$staging"
ditto "$app_dir" "$staging/OpenType.app"
cp "$project_dir/scripts/install-release.sh" "$staging/install.sh"
chmod +x "$staging/install.sh"

cat > "$staging/INSTALL.md" <<EOF
# OpenType $version — install

Requires an Apple Silicon Mac running macOS 13 or newer.

Open Terminal, \`cd\` into this folder, and run:

    ./install.sh

That installs the app into /Applications, installs its two dependencies
(Homebrew's python@3.12 and ffmpeg), and builds the local speech-recognition
environment. It is safe to re-run.

You did not actually need to download this archive by hand — the same script,
run straight from the network, fetches the latest release itself:

    curl -fsSL https://raw.githubusercontent.com/$REPO_SLUG/main/scripts/install-release.sh | zsh

Prefer to have a coding agent do it? Give Claude Code / Codex / Cursor this:

    Please install OpenType on this Mac. In this folder there's an
    OpenType.app and an install.sh — read install.sh, run it, and then walk
    me through granting the microphone and accessibility permissions and
    finishing the app's first-run setup wizard.

After installing you'll need to grant two macOS permissions (microphone and
accessibility) and finish a short in-app setup wizard. Plain dictation needs no
API key; the Ask and Agent modes need an LLM provider key you supply there.

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
