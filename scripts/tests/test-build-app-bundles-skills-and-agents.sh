#!/usr/bin/env bash
#
# Stage-1 TDD test for the packaging half of the skills/agents bug (batch
# 8abd25f added sidecar/skills/ and sidecar/agents/; the built-in skill/agent
# system cannot work in the packaged .app for two compounding reasons — this
# test covers the first one).
#
# BUG: scripts/build-app.sh copies the compiled sidecar binary, whisper-env/,
#      whisper/, and (optionally) sidecar.env into Contents/Resources/ — but
#      it never copies sidecar/skills/ or sidecar/agents/. So even a correctly
#      wired SidecarClient (the Swift-side half of this fix, see
#      Tests/OpenTypeTests/BundledSkillsAndAgentsEnvironmentTests.swift) would
#      point OPENTYPE_SKILLS_DIR / OPENTYPE_AGENTS_DIR at directories that
#      simply don't exist in the shipped bundle.
#
# INTENDED FIX (a later pipeline stage): build-app.sh must ditto
#      sidecar/skills/ -> Contents/Resources/skills and
#      sidecar/agents/ -> Contents/Resources/agents, the same way it already
#      does for sidecar/whisper/.
#
# WHAT THIS TEST ASSERTS:
#   1. A build run against a fake project whose sidecar/skills/ and
#      sidecar/agents/ each contain a marker file must produce that same
#      marker file at Contents/Resources/skills/... and
#      Contents/Resources/agents/... in the built bundle.
#   2. The copy is a real recursive copy, not just an empty directory: nested
#      subdirectories/files travel with it (mirroring how a real skill/agent
#      is a directory of files, e.g. sidecar/skills/*/SKILL.md).
#
# STRATEGY (fast, hermetic, no real build) — mirrors
# test-build-app-no-env-bundle.sh's harness exactly: run the REAL
# scripts/build-app.sh, but against a throwaway fake project layout and with
# swift/bun/codesign/xattr stubbed out on PATH, so no actual Swift/TypeScript
# compilation or code-signing happens. project_dir inside build-app.sh is
# derived from the script's own location (project_dir=${0:A:h:h}), so copying
# build-app.sh into $tmp/scripts/ makes it target our fake $tmp project
# instead of the real repo. We then inspect the produced bundle.
#
# Run:  bash scripts/tests/test-build-app-bundles-skills-and-agents.sh
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
# Fake project layout under $work/proj — the same minimum
# test-build-app-no-env-bundle.sh populates, plus sidecar/skills/ and
# sidecar/agents/ with marker content (including a nested subdirectory, since
# a real skill/agent is itself a directory of files).
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

# The bundled skill/agent content this fix must make it into the .app.
# Skills are directory-plus-marker (<name>/SKILL.md); agent definitions are
# FLAT files directly under the root (<name>.md, resourceStore.ts's "file"
# layout) -- these are deliberately different shapes, so the fixtures below
# must not be.
mkdir -p "$proj/sidecar/skills/example-skill"
printf 'marker: skill\n' > "$proj/sidecar/skills/example-skill/SKILL.md"
mkdir -p "$proj/sidecar/agents"
printf 'marker: agent\n' > "$proj/sidecar/agents/example-agent.md"

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

resources_dir="$proj/dist/OpenType.app/Contents/Resources"

run_build() {
  env -u OPENTYPE_NOTARIZE PATH="$stub:$PATH" \
    zsh "$proj/scripts/build-app.sh" "$@" >"$work/out.log" 2>&1
}

dump_log() { echo "---- build-app.sh output ----" >&2; cat "$work/out.log" >&2; echo "-----------------------------" >&2; }

rm -rf "$proj/dist"
if ! run_build; then
  dump_log
  fail "build-app.sh run exited non-zero -- test harness problem, not the packaging assertion"
fi

# --------------------------------------------------------------------------
# Assertion 1 (the red one): sidecar/skills/ must be bundled.
# --------------------------------------------------------------------------
if [ ! -f "$resources_dir/skills/example-skill/SKILL.md" ]; then
  dump_log
  fail "sidecar/skills/ was not copied into Contents/Resources/skills -- the packaged app's OPENTYPE_SKILLS_DIR would point at nothing"
fi
pass "sidecar/skills/ was bundled into Contents/Resources/skills"

# --------------------------------------------------------------------------
# Assertion 2 (the red one): sidecar/agents/ must be bundled.
# --------------------------------------------------------------------------
if [ ! -f "$resources_dir/agents/example-agent.md" ]; then
  dump_log
  fail "sidecar/agents/ was not copied into Contents/Resources/agents -- the packaged app's OPENTYPE_AGENTS_DIR would point at nothing"
fi
pass "sidecar/agents/ was bundled into Contents/Resources/agents"

# --------------------------------------------------------------------------
# Assertion 3: copied content actually matches (a real, not empty, copy).
# --------------------------------------------------------------------------
skill_content="$(cat "$resources_dir/skills/example-skill/SKILL.md" 2>/dev/null || true)"
if [ "$skill_content" != "marker: skill" ]; then
  fail "bundled skills/example-skill/SKILL.md content did not match source (got: '$skill_content')"
fi
agent_content="$(cat "$resources_dir/agents/example-agent.md" 2>/dev/null || true)"
if [ "$agent_content" != "marker: agent" ]; then
  fail "bundled agents/example-agent.md content did not match source (got: '$agent_content')"
fi
pass "bundled skills/agents content matches source verbatim"

echo "ALL PASS"
