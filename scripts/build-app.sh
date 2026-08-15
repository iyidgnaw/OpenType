#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"

# Argument parsing. --bundle-env is an explicit opt-in to fold the developer's
# local sidecar/.env.local (which holds real secrets like DEEPSEEK_API_KEY)
# into the built .app. It is OFF by default so a routine build never leaks
# credentials into a distributable bundle. Unknown args are left untouched for
# any future handling; notarization is still driven by the OPENTYPE_NOTARIZE
# env var, not a flag.
bundle_env=0
for arg in "$@"; do
  case "$arg" in
    --bundle-env) bundle_env=1 ;;
  esac
done

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
cp "$project_dir/Resources/AppIcon.icns" "$resources_dir/AppIcon.icns"
rm -rf "$resources_dir/Sounds"
ditto "$project_dir/Resources/Sounds" "$resources_dir/Sounds"
rm -rf "$resources_dir/en.lproj"
ditto \
  "$project_dir/Resources/Localization/en.lproj" \
  "$resources_dir/en.lproj"
# §F: CFBundleDevelopmentRegion is `en`, but zh-Hans has to ship too — this is
# what lets a Chinese-system user see 「OpenType 需要使用麦克风…」 in the
# microphone/speech-recognition/AppleEvents system dialogs instead of the
# English base copy in Info.plist (InfoPlist.strings localisation, not the
# interface language switch, which those dialogs are out of SwiftUI's reach
# to affect).
rm -rf "$resources_dir/zh-Hans.lproj"
ditto \
  "$project_dir/Resources/Localization/zh-Hans.lproj" \
  "$resources_dir/zh-Hans.lproj"
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

# A `bun build --compile` binary doesn't carry the source tree's
# sidecar/.env.local with it, and doesn't know to look for one at an
# arbitrary launch-time cwd. Bundle it (if present) as sidecar.env next to
# the binary; SidecarClient.swift reads this file and injects its values
# into the child process's environment before launching the bundled binary.
# This file is local-only (sidecar/.env.local is gitignored) - it never
# touches source control, only this local build output.
#
# SECURITY: bundling is gated behind an explicit --bundle-env opt-in. By
# default we skip it, so a routine build never bakes the developer's real
# DEEPSEEK_API_KEY (or any other secret in .env.local) into a distributable
# .app. Only pass --bundle-env for a private, non-distributed local build.
if [ "$bundle_env" = "1" ]; then
  if [ -f "$project_dir/sidecar/.env.local" ]; then
    echo "warning: --bundle-env set -- bundling sidecar/.env.local (contains secrets like DEEPSEEK_API_KEY) into the .app. DO NOT distribute this build." >&2
    cp "$project_dir/sidecar/.env.local" "$resources_dir/sidecar.env"
  else
    echo "note: --bundle-env set but sidecar/.env.local not found -- nothing to bundle." >&2
  fi
else
  echo "note: skipping sidecar/.env.local bundling (default). Pass --bundle-env to include it in a private local build." >&2
fi

# Files received through WeChat can leave a quarantine attribute on the
# workspace. A locally rebuilt app must not inherit that download quarantine,
# otherwise Finder may refuse to launch an otherwise valid ad-hoc build.
xattr -dr com.apple.quarantine "$app_dir" 2>/dev/null || true

# --- Signing -----------------------------------------------------------
#
# Two paths:
#
# 1. Default (OPENTYPE_NOTARIZE unset): fast ad-hoc signing for local
#    iteration, unchanged from before. `bun build --compile` binaries have a
#    non-standard Mach-O shape (an appended module-graph trailer) that a
#    `codesign --deep` pass on the outer app corrupts -- spctl then reports
#    "invalid signature (code or signature have been modified)" and macOS
#    silently kills the process the instant the running app tries to spawn
#    it, even though the app itself launches fine. Sign the sidecar binary
#    standalone first, then the outer app WITHOUT --deep, to avoid that.
#
# 2. OPENTYPE_NOTARIZE=1: a real Developer ID Application identity, signing
#    every nested Mach-O individually (notarization -- unlike ad-hoc/local
#    Gatekeeper checks -- rejects the whole submission if any nested
#    executable/dylib lacks a valid signature+hardened-runtime+timestamp),
#    then submits to Apple's notary service and staples the ticket so the
#    app opens with no Gatekeeper warning even offline. Needs a Developer ID
#    Application certificate in the login Keychain and notarytool credentials
#    stored under OPENTYPE_NOTARY_PROFILE (default: OpenTypeNotary) -- see
#    docs/onboarding/coding-agent-setup-prompt.md's release-build note, or
#    just `xcrun notarytool store-credentials`.
if [ "${OPENTYPE_NOTARIZE:-}" = "1" ]; then
  # Two auth methods for notarytool: App Store Connect API key
  # (OPENTYPE_NOTARY_KEY_PATH/_ID/_ISSUER_ID -- preferred, and the only one
  # that worked around a "Team is not yet configured for notarization"
  # (statusCode 7000) rejection seen with Apple-ID+app-specific-password
  # auth during this app's own first notarization attempt) or the
  # keychain-profile method (OPENTYPE_NOTARY_PROFILE, default OpenTypeNotary)
  # set up via `xcrun notarytool store-credentials`.
  notary_auth_args=()
  if [ -n "${OPENTYPE_NOTARY_KEY_PATH:-}" ]; then
    : ${OPENTYPE_NOTARY_KEY_ID:?OPENTYPE_NOTARY_KEY_PATH is set but OPENTYPE_NOTARY_KEY_ID is not}
    : ${OPENTYPE_NOTARY_ISSUER_ID:?OPENTYPE_NOTARY_KEY_PATH is set but OPENTYPE_NOTARY_ISSUER_ID is not}
    notary_auth_args=(--key "$OPENTYPE_NOTARY_KEY_PATH" --key-id "$OPENTYPE_NOTARY_KEY_ID" --issuer "$OPENTYPE_NOTARY_ISSUER_ID")
  else
    notary_profile="${OPENTYPE_NOTARY_PROFILE:-OpenTypeNotary}"
    notary_auth_args=(--keychain-profile "$notary_profile")
  fi
  identity=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
  if [ -z "$identity" ]; then
    echo "error: OPENTYPE_NOTARIZE=1 but no 'Developer ID Application' certificate found in the login Keychain." >&2
    exit 1
  fi
  echo "notarized release build: signing with identity: $identity"

  # Sign every nested Mach-O in the bundled Whisper venv first (bottom-up).
  # `file` per-entry is slow across a venv this size but correctness here
  # matters more than build speed for a release build, and only runs when
  # explicitly opted into.
  if [ -d "$resources_dir/whisper-env" ]; then
    find "$resources_dir/whisper-env" -type f -print0 | while IFS= read -r -d '' f; do
      if file "$f" 2>/dev/null | grep -q "Mach-O"; then
        entitlements_arg=()
        case "$f" in
          "$resources_dir/whisper-env/bin/"*)
            entitlements_arg=(--entitlements "$project_dir/Resources/PythonRuntime.entitlements")
            ;;
        esac
        codesign --force --sign "$identity" --options runtime --timestamp "${entitlements_arg[@]}" "$f"
      fi
    done
  fi

  codesign --force --sign "$identity" --options runtime --timestamp "$resources_dir/opentype-sidecar"

  codesign \
    --force \
    --sign "$identity" \
    --options runtime \
    --timestamp \
    --entitlements "$project_dir/Resources/OpenType.entitlements" \
    --requirements '=designated => identifier "ai.rain.opentype"' \
    "$app_dir"

  echo "submitting to Apple notary service..."
  notarize_zip="$project_dir/dist/OpenType-notarize.zip"
  rm -f "$notarize_zip"
  ditto -c -k --keepParent "$app_dir" "$notarize_zip"
  if [ "${OPENTYPE_NOTARIZE_NO_WAIT:-}" = "1" ]; then
    # Submit and return immediately with a submission ID, instead of
    # blocking here on notarytool's own --wait polling loop -- Apple's
    # server-side processing can run long enough to exceed a single
    # command's execution window, so the caller is expected to poll
    # `xcrun notarytool wait <id> ...` externally and then re-run this
    # script's stapling step itself (see the two-phase note in
    # docs/onboarding/coding-agent-setup-prompt.md's release-build section,
    # or just re-invoke with OPENTYPE_STAPLE_ONLY=1).
    xcrun notarytool submit "$notarize_zip" "${notary_auth_args[@]}"
    rm -f "$notarize_zip"
    exit 0
  fi
  xcrun notarytool submit "$notarize_zip" "${notary_auth_args[@]}" --wait
  rm -f "$notarize_zip"

  echo "stapling notarization ticket..."
  xcrun stapler staple "$app_dir"

  echo "verifying..."
  spctl --assess --type execute -vv "$app_dir"
  codesign --verify --deep --strict --verbose=2 "$app_dir"
else
  # Sign the sidecar binary on its own -- see the note above on why --deep
  # on the outer app corrupts a `bun build --compile` binary's signature.
  codesign --force --sign - "$resources_dir/opentype-sidecar"

  # Keep a stable designated requirement across local ad-hoc builds. Without
  # an explicit requirement, macOS may bind TCC permissions to a changing
  # code hash and ask for Microphone / Accessibility access again after
  # every rebuild.
  codesign \
    --force \
    --sign - \
    --requirements '=designated => identifier "ai.rain.opentype"' \
    "$app_dir"
fi

echo "$app_dir"
