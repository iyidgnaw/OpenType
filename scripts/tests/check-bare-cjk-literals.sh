#!/usr/bin/env bash
#
# §F audit guard (docs/superpowers/specs/2026-08-15-product-batch-plan.md §F,
# docs/reviews/2026-08-15-product-review.md §10).
#
# THE PROBLEM THIS CATCHES: `OpenTypeL10n.text(_:english:)` is what makes a
# string follow the interface-language setting. A Chinese literal handed
# straight to a screen-rendering API instead — `Text("还没有输入历史")` rather
# than `Text(OpenTypeL10n.text("还没有输入历史", english: "..."))` — shows
# Chinese under an English interface regardless of what the user picked,
# which is exactly the bug §F exists to close. 670 call sites already do this
# correctly; this is the mechanical check that stops the 671st from sneaking
# past review, since nobody is going to re-read all 670 by hand every time.
#
# WHAT IT MATCHES: a bare `"...CJK..."` string literal immediately (only
# whitespace in between) after the opening paren/`=` of one of these sinks —
# Text(...), Text(verbatim: ...), Button(...), Label(...), .help(...),
# .accessibilityLabel/.accessibilityHint/.accessibilityValue(...),
# .navigationTitle(...), and the notification/alert assignment shape
# (.title/.body/.subtitle/.messageText/.informativeText = "..."), which is
# what `content.title = OpenTypeL10n.text(...)` in AppModel.swift and
# NSAlert's messageText/informativeText actually look like in this codebase.
#
# WHAT IT DELIBERATELY DOES NOT COVER — say this whenever this script's
# result is reported, so a clean run is never read as "there is no bypass
# left anywhere":
#   - Any sink not in the list above. A custom row/label type that takes a
#     raw `String` parameter (`SettingsRow(title: someString)`, say) is
#     supposed to receive an already-`OpenTypeL10n.text`-wrapped `String`,
#     but nothing here can tell a wrapped one from a bare one at that call
#     site without an actual type checker — that would need a real Swift
#     tool, not a grep rule.
#   - A CJK literal built with `+`, `String(format:)`, or string
#     interpolation around a sink call, or assigned to a `let`/`var` first
#     and passed to the sink by name one line later.
#   - Non-Swift surfaces entirely: the sidecar (TypeScript), docs, shell
#     scripts, Info.plist (that one has its own mechanism — InfoPlist.strings
#     localisation, not OpenTypeL10n, since it renders before any SwiftUI
#     environment exists at all).
#   - A bare literal on a code line that also carries a trailing `//`
#     comment — only a line whose *trimmed content starts with* `//` is
#     skipped (see FALSE-POSITIVE NOTE). No sink pattern above has ever
#     legitimately appeared after a trailing comment marker in this repo, so
#     this has not been a gap in practice, but it is not specially handled.
#
# FALSE-POSITIVE NOTE: comments and doc comments in this codebase quote
# Chinese UI copy constantly (design handoffs, review excerpts, 「」-quoted
# product terms). A line whose trimmed content starts with `//` is never
# scanned. `OpenTypeL10n.text("...", english: "...")` call sites are never
# flagged either way: the patterns only match a literal appearing
# *immediately* after a sink's opening paren, and `Text(OpenTypeL10n.text(`
# has `OpenTypeL10n.text(` in that position, not a quote.
#
# Run:  bash scripts/tests/check-bare-cjk-literals.sh [directory]
#       (directory defaults to Sources/OpenType under this repo; the
#       companion test in test-check-bare-cjk-literals.sh points it at a
#       throwaway fixture with one known-bad and one known-good line.)
# Exit: 0 = no violations. 1 = at least one violation, listed on stdout.

set -u

target_dir="${1:-}"
if [ -z "$target_dir" ]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "$script_dir/../.." && pwd)"
  target_dir="$repo_root/Sources/OpenType"
fi

if [ ! -d "$target_dir" ]; then
  echo "check-bare-cjk-literals: no such directory: $target_dir" >&2
  exit 1
fi

# One CJK code point anywhere inside the literal is enough to flag it — a
# mixed Chinese/English/number string ("今天 · 42 字") is still Chinese copy
# that has to go through OpenTypeL10n.text like anything else.
cjk='一-鿿'
sink="[[:space:]]*(verbatim:[[:space:]]*)?\"[^\"]*[$cjk][^\"]*\""
pattern="Text\($sink"
pattern="$pattern|Button\([[:space:]]*\"[^\"]*[$cjk][^\"]*\""
pattern="$pattern|Label\([[:space:]]*\"[^\"]*[$cjk][^\"]*\""
pattern="$pattern|\\.help\([[:space:]]*\"[^\"]*[$cjk][^\"]*\""
pattern="$pattern|\\.accessibilityLabel\([[:space:]]*\"[^\"]*[$cjk][^\"]*\""
pattern="$pattern|\\.accessibilityHint\([[:space:]]*\"[^\"]*[$cjk][^\"]*\""
pattern="$pattern|\\.accessibilityValue\([[:space:]]*\"[^\"]*[$cjk][^\"]*\""
pattern="$pattern|\\.navigationTitle\([[:space:]]*\"[^\"]*[$cjk][^\"]*\""
pattern="$pattern|\\.title[[:space:]]*=[[:space:]]*\"[^\"]*[$cjk][^\"]*\""
pattern="$pattern|\\.body[[:space:]]*=[[:space:]]*\"[^\"]*[$cjk][^\"]*\""
pattern="$pattern|\\.subtitle[[:space:]]*=[[:space:]]*\"[^\"]*[$cjk][^\"]*\""
pattern="$pattern|\\.messageText[[:space:]]*=[[:space:]]*\"[^\"]*[$cjk][^\"]*\""
pattern="$pattern|\\.informativeText[[:space:]]*=[[:space:]]*\"[^\"]*[$cjk][^\"]*\""

violations=0

while IFS= read -r -d '' file; do
  while IFS=: read -r lineno content; do
    trimmed="$(printf '%s' "$content" | sed -e 's/^[[:space:]]*//')"
    case "$trimmed" in
      //*) continue ;;
    esac
    echo "$file:$lineno: $content"
    violations=$((violations + 1))
  done < <(grep -nE "$pattern" "$file")
done < <(find "$target_dir" -name '*.swift' -print0 | sort -z)

if [ "$violations" -gt 0 ]; then
  echo >&2
  echo "check-bare-cjk-literals: $violations bare CJK literal(s) bypass OpenTypeL10n.text. See this script's own header for exactly what it does and does not cover." >&2
  exit 1
fi

exit 0
