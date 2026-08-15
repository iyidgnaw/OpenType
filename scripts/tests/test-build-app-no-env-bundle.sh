#!/usr/bin/env bash
#
# Stage-1 TDD test for bug P0-4 (verified true).
#
# BUG: scripts/build-app.sh (~lines 68-70) unconditionally does
#         cp sidecar/.env.local  Contents/Resources/sidecar.env
#      whenever sidecar/.env.local exists. That bundles the developer's real
#      DEEPSEEK_API_KEY (and any other secret in .env.local) into every
#      distributed OpenType.app.
#
# INTENDED FIX (a later pipeline stage): do NOT bundle .env.local by default.
#      Only bundle it when the build is explicitly opted in via a flag,
#      "--bundle-env" (ideally with a warning printed).
#
# WHAT THIS TEST ASSERTS:
#   1. A DEFAULT build (no flags) must NOT produce
#      Contents/Resources/sidecar.env.                <-- fails against current code (red)
#   2. A build passed "--bundle-env" MUST still produce it (opt-in preserved).
#
# STRATEGY (fast, hermetic, no real build):
#   Run the REAL scripts/build-app.sh, but against a throwaway fake project
#   layout and with swift/bun/codesign/xattr stubbed out on PATH, so no actual
#   Swift/TypeScript compilation or code-signing happens. project_dir inside
#   build-app.sh is derived from the script's own location
#   (project_dir=${0:A:h:h}), so copying build-app.sh into $tmp/scripts/ makes
#   it target our fake $tmp project instead of the real repo. We then inspect
#   the produced bundle for sidecar.env.
#
# Run:  bash scripts/tests/test-build-app-no-env-bundle.sh
# Exit: 0 = pass, non-zero = fail.

set -u

REPO_ROOT="/Users/diywang/hackathon/OpenType"
REAL_SCRIPT="$REPO_ROOT/scripts/build-app.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ -f "$REAL_SCRIPT" ] || fail "build-app.sh not found at $REAL_SCRIPT"
command -v zsh >/dev/null 2>&1 || fail "zsh not on PATH (build-app.sh has a #!/bin/zsh shebang and uses zsh-only \${0:A:h:h})"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --------------------------------------------------------------------------
# Fake project layout under $work/proj. project_dir = ${0:A:h:h} of the copied
# script, i.e. $work/proj. Populate the minimum the script copies/dittos from.
# --------------------------------------------------------------------------
proj="$work/proj"
mkdir -p "$proj/scripts"
cp "$REAL_SCRIPT" "$proj/scripts/build-app.sh"

mkdir -p "$proj/.build/release"
printf 'fake-binary' > "$proj/.build/release/OpenType"

mkdir -p "$proj/Resources/Sounds" "$proj/Resources/Localization/en.lproj" "$proj/Resources/Localization/zh-Hans.lproj"
printf 'plist'  > "$proj/Resources/Info.plist"
printf 'icns'   > "$proj/Resources/AppIcon.icns"
printf 'sound'  > "$proj/Resources/Sounds/blip.wav"
printf 'strings'> "$proj/Resources/Localization/en.lproj/Localizable.strings"
printf 'strings'> "$proj/Resources/Localization/en.lproj/InfoPlist.strings"
printf 'strings'> "$proj/Resources/Localization/zh-Hans.lproj/InfoPlist.strings"

mkdir -p "$proj/sidecar/src" "$proj/sidecar/whisper"
printf 'server' > "$proj/sidecar/src/server.ts"
printf 'py'     > "$proj/sidecar/whisper/run.py"

# The secret the bug leaks. Its presence in the produced bundle is the failure.
printf 'DEEPSEEK_API_KEY=SECRET_SHOULD_NOT_LEAK\n' > "$proj/sidecar/.env.local"

# --------------------------------------------------------------------------
# Stubs: shadow the real build tools so nothing heavy runs.
#   swift    -> no-op (release binary is pre-created above)
#   bun      -> satisfies `command -v bun` AND emulates `--compile --outfile X`
#   codesign -> no-op
#   xattr    -> no-op
# --------------------------------------------------------------------------
stub="$work/bin"
mkdir -p "$stub"

cat > "$stub/swift" <<'STUB'
#!/bin/sh
exit 0
STUB

cat > "$stub/bun" <<'STUB'
#!/bin/sh
# Emulate: bun build <entry> --compile --outfile <path>
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --outfile) shift; out="$1" ;;
  esac
  [ "$#" -gt 0 ] && shift
done
if [ -n "$out" ]; then
  mkdir -p "$(dirname "$out")"
  printf 'fake-sidecar-binary' > "$out"
fi
exit 0
STUB

cat > "$stub/codesign" <<'STUB'
#!/bin/sh
exit 0
STUB

cat > "$stub/xattr" <<'STUB'
#!/bin/sh
exit 0
STUB

chmod +x "$stub/swift" "$stub/bun" "$stub/codesign" "$stub/xattr"

bundled_env="$proj/dist/OpenType.app/Contents/Resources/sidecar.env"

run_build() {
  # Run the copied script with stubs winning on PATH; keep the notarize path
  # off. Output captured to $work/out.log.
  env -u OPENTYPE_NOTARIZE PATH="$stub:$PATH" \
    zsh "$proj/scripts/build-app.sh" "$@" >"$work/out.log" 2>&1
}

dump_log() { echo "---- build-app.sh output ----" >&2; cat "$work/out.log" >&2; echo "-----------------------------" >&2; }

# --------------------------------------------------------------------------
# Assertion 1 (the red one): default build must NOT bundle sidecar.env.
# --------------------------------------------------------------------------
rm -rf "$proj/dist"
if ! run_build; then
  dump_log
  fail "default build-app.sh run exited non-zero -- test harness problem, not the security assertion"
fi
if [ -f "$bundled_env" ]; then
  fail "DEFAULT build bundled sidecar/.env.local as $bundled_env -- this leaks DEEPSEEK_API_KEY into the distributed .app. Bundling must be gated behind an explicit --bundle-env opt-in."
fi
pass "default build did not bundle sidecar.env"

# --------------------------------------------------------------------------
# Assertion 2 (guards the fix): --bundle-env must still bundle sidecar.env.
# --------------------------------------------------------------------------
rm -rf "$proj/dist"
if ! run_build --bundle-env; then
  dump_log
  fail "--bundle-env build-app.sh run exited non-zero -- test harness problem"
fi
if [ ! -f "$bundled_env" ]; then
  fail "--bundle-env build did NOT bundle sidecar.env -- the explicit opt-in flag must still allow bundling"
fi
pass "--bundle-env build bundled sidecar.env"

echo "ALL PASS"
