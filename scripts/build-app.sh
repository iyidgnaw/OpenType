#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"

if ! command -v bun >/dev/null 2>&1; then
  echo "error: bun not found on PATH. Install bun (https://bun.sh) to compile the sidecar binary." >&2
  exit 1
fi

mkdir -p \
  "$project_dir/.build/clang-module-cache" \
  "$project_dir/.build/swiftpm-module-cache"

CLANG_MODULE_CACHE_PATH="$project_dir/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.build/swiftpm-module-cache" \
swift build -c release --disable-sandbox

(
  cd "$project_dir/sidecar"
  bun build ./src/server.ts --compile --outfile "$project_dir/sidecar/dist/opentype-sidecar"
)

app_dir="$project_dir/dist/OpenType.app"
contents_dir="$app_dir/Contents"
binary_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"

mkdir -p "$binary_dir" "$resources_dir"
cp "$project_dir/.build/release/OpenType" "$binary_dir/OpenType"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
rm -rf "$resources_dir/Sounds"
ditto "$project_dir/Resources/Sounds" "$resources_dir/Sounds"
rm -rf "$resources_dir/en.lproj"
ditto \
  "$project_dir/Resources/Localization/en.lproj" \
  "$resources_dir/en.lproj"
chmod +x "$binary_dir/OpenType"

cp "$project_dir/sidecar/dist/opentype-sidecar" "$resources_dir/opentype-sidecar"
chmod +x "$resources_dir/opentype-sidecar"

# Local MLX-Whisper ASR: bundle the python venv + server script so the
# packaged sidecar binary can spawn it without depending on the source
# checkout (SidecarClient.swift points OPENTYPE_WHISPER_PYTHON_BIN /
# OPENTYPE_WHISPER_SCRIPT_PATH at these bundled, absolute copies -- see its
# `bundledIsExecutable` branch). This makes the .app noticeably larger (the
# venv includes mlx/torch/numpy and is several hundred MB) but keeps ASR
# fully local with no separate install step.
if [ -d "$project_dir/sidecar/whisper-env" ]; then
  rm -rf "$resources_dir/whisper-env"
  ditto "$project_dir/sidecar/whisper-env" "$resources_dir/whisper-env"
else
  echo "warning: sidecar/whisper-env/ not found -- packaged app's local ASR will not work. Run the Part 1 setup (python3 -m venv sidecar/whisper-env && sidecar/whisper-env/bin/pip install mlx-whisper) first." >&2
fi
rm -rf "$resources_dir/whisper"
ditto "$project_dir/sidecar/whisper" "$resources_dir/whisper"

# Sign the sidecar binary on its own, before it becomes part of the app
# bundle's seal below. `bun build --compile` binaries have a non-standard
# Mach-O shape (an appended module-graph trailer) that a later
# `codesign --deep` pass on the outer app corrupts -- spctl then reports
# "invalid signature (code or signature have been modified)" and macOS
# silently kills the process the instant the running app tries to spawn
# it, even though the app itself launches fine. Signing it here, then
# signing the outer app WITHOUT --deep (this bundle has no other nested
# executables that need it), leaves both signatures valid.
codesign --force --sign - "$resources_dir/opentype-sidecar"

# A `bun build --compile` binary doesn't carry the source tree's
# sidecar/.env.local with it, and doesn't know to look for one at an
# arbitrary launch-time cwd. Bundle it (if present) as sidecar.env next to
# the binary; SidecarClient.swift reads this file and injects its values
# into the child process's environment before launching the bundled binary.
# This file is local-only (sidecar/.env.local is gitignored) - it never
# touches source control, only this local build output.
if [ -f "$project_dir/sidecar/.env.local" ]; then
  cp "$project_dir/sidecar/.env.local" "$resources_dir/sidecar.env"
fi

# Files received through WeChat can leave a quarantine attribute on the
# workspace. A locally rebuilt app must not inherit that download quarantine,
# otherwise Finder may refuse to launch an otherwise valid ad-hoc build.
xattr -dr com.apple.quarantine "$app_dir" 2>/dev/null || true

# Keep a stable designated requirement across local ad-hoc builds. Without an
# explicit requirement, macOS may bind TCC permissions to a changing code hash
# and ask for Microphone / Accessibility access again after every rebuild.
codesign \
  --force \
  --sign - \
  --requirements '=designated => identifier "ai.rain.opentype"' \
  "$app_dir"
echo "$app_dir"
