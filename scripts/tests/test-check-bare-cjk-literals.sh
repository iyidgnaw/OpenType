#!/usr/bin/env bash
#
# Test of check-bare-cjk-literals.sh (§F,
# docs/superpowers/specs/2026-08-15-product-batch-plan.md §F).
#
# "The check must have a test of its own proving it catches a known-bad
# sample — a linter nobody has proven can fail is not a guard." This builds a
# throwaway fixture directory with:
#   - one line that MUST be flagged (a bare `Text("...")` literal — the
#     P0-4-shaped bug §F exists to close),
#   - a handful of lines that MUST NOT be flagged: a correct
#     `OpenTypeL10n.text(...)` call site (single-line and the common
#     multi-line shape), a `Text(verbatim: "OpenType")` with no CJK at all,
#     and a `///` doc comment quoting Chinese UI copy the way this repo's own
#     doc comments constantly do.
# then runs the real check script against that directory and asserts it
# exits 1 with the bad line named, and would exit 0 if the bad line were
# removed (checked by re-running against a second, all-good fixture).
#
# Run:  bash scripts/tests/test-check-bare-cjk-literals.sh
# Exit: 0 = pass, non-zero = fail.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/check-bare-cjk-literals.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ -f "$CHECK_SCRIPT" ] || fail "check-bare-cjk-literals.sh not found at $CHECK_SCRIPT"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --------------------------------------------------------------------------
# Fixture 1: one known-bad line among several known-good ones.
# --------------------------------------------------------------------------
bad_dir="$work/bad"
mkdir -p "$bad_dir"
cat > "$bad_dir/Sample.swift" <<'SWIFT'
import SwiftUI

/// A doc comment is allowed to quote Chinese UI copy like 「还没有输入历史」 —
/// this line must never be flagged.
struct Sample: View {
    var body: some View {
        VStack {
            // A bare comment quoting 中文 must never be flagged either.
            Text(OpenTypeL10n.text("正确的写法", english: "The correct way"))
            Text(
                OpenTypeL10n.text(
                    "多行也正确",
                    english: "Multi-line is correct too"
                )
            )
            Text(verbatim: "Tab")
            Text("还没有输入历史")
        }
    }
}
SWIFT

bad_output="$("$CHECK_SCRIPT" "$bad_dir" 2>&1)"
bad_exit=$?

[ "$bad_exit" -ne 0 ] || fail "expected a non-zero exit against the known-bad fixture, got 0. Output:\n$bad_output"

case "$bad_output" in
  *"Sample.swift"*"还没有输入历史"*) pass "known-bad line was flagged" ;;
  *) fail "the known-bad line was not named in the output:\n$bad_output" ;;
esac

# Exactly one violation — if the correct call sites, the verbatim label, or
# either comment were also flagged, this would be >1.
violation_lines="$(printf '%s\n' "$bad_output" | grep -c "Sample.swift:")"
[ "$violation_lines" -eq 1 ] || fail "expected exactly 1 flagged line, got $violation_lines. Output:\n$bad_output"
pass "exactly one line was flagged (the correct call sites, verbatim label, and comments were not false positives)"

# --------------------------------------------------------------------------
# Fixture 2: the same file with the bad line removed must pass clean.
# --------------------------------------------------------------------------
good_dir="$work/good"
mkdir -p "$good_dir"
grep -v '还没有输入历史' "$bad_dir/Sample.swift" > "$good_dir/Sample.swift"

good_output="$("$CHECK_SCRIPT" "$good_dir" 2>&1)"
good_exit=$?

[ "$good_exit" -eq 0 ] || fail "expected a zero exit against the known-good fixture, got $good_exit. Output:\n$good_output"
pass "known-good fixture passed clean"

# --------------------------------------------------------------------------
# Sanity: the real Sources/OpenType tree (as of this pipeline stage) passes
# clean too, so this test doubles as the audit's actual result for §F.
# --------------------------------------------------------------------------
repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
real_output="$("$CHECK_SCRIPT" "$repo_root/Sources/OpenType" 2>&1)"
real_exit=$?
[ "$real_exit" -eq 0 ] || fail "the real Sources/OpenType tree has unresolved bare CJK literals:\n$real_output"
pass "the real Sources/OpenType tree passes clean"

echo "ALL PASS"
