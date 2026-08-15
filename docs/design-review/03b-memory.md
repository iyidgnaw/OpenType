# 03B · 记忆 — pixel review

Source of truth: `design_handoff_opentype_redesign_v1/OpenType 重设计（单文件·离线）.html`,
section **3B**, read as literal CSS (the same markup appears verbatim in
`OpenType 重设计.dc.html:491–566`). Prose in that folder's `README.md` §4 rounds
some numbers; where the two disagree, the CSS wins.

Implementation: `Sources/OpenType/MemoryViews.swift`.
Tokens: `Sources/OpenType/DesignTokens.swift` (`DS.*`). This page still does not
edit that file, but it no longer has to work around it: the literal steps 03B
needs were added to the scale in the same batch, so every row below names the
member it uses rather than recording a gap.

Status key: ✅ matches · 🔧 fixed by this review · ⚠️ deviates, reason given.

**Second pass — 稿子优先.** The first pass mapped the mockup's literal values
onto the closed DS scale: 11.5px → 12, 10.5px → 11, a 7pt and a 5pt radius → 6,
five `rgba(0,0,0,α)` steps → one border token, and the whole `rgba(28,28,30,α)`
grey band → SwiftUI's hierarchical styles (`.secondary` ≈ α .50, `.tertiary`
≈ α .26 on macOS light). The owner has since ruled **无条件还原设计稿**: the
mockup's literal CSS wins, unconditionally. Every one of those collapses is
reversed below. The one value still expressed as a semantic is `.primary`,
because the handoff's own colour table names `.primary` for 文字 主 rather than
rounding a value into it.

---

## Page shell

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Page | background | `#F5F5F3` | `DS.Colour.canvas` = `rgb(.961,.961,.953)` = `#F5F5F3` | ✅ |
| Page | appearance | light only (literal colours) | app pinned light in `OpenTypeApp`; `DS.Colour.card` is literal white | ✅ |
| Header strip | height | `52px` | `DS.Size.headerHeight` = 52 via `ColumnHeader` | ✅ |
| Header strip | padding | `0 24px` | `ColumnHeader` → `DS.Space.pageWide` = 24 (narrow: `pageNarrow` = 14) | ✅ |
| Header strip | vertical align | `align-items: center` | `HStack` default `.center` | ✅ |
| Header strip | gap | `14px` | `ColumnHeader` uses `HStack(spacing: 8)` | ⚠️ **Out of scope** — `SidebarShell.swift:335`. The same `14px` header gap is drawn in 03A and 06A, so this is one cross-screen fix, not a memory-page one. See *Out-of-scope*. |
| Content area | padding | `0 24px 24px` | was `DS.Space.content` (16) | 🔧 → `DS.Space.pageWide` (24) wide / `pageNarrow` (14) narrow |
| Content area | column gap | `16px` | `DS.Space.content` = 16 | ✅ |
| Left column | flex | `1.15` | `MemoryMetrics.leftColumnShare` = 1.15/2.15 of the width left after the gap | ✅ |
| Right column | flex | `1` | remaining width (`maxWidth: .infinity`) | ✅ |
| Left column | inner gap | `8px` (label → card) | `DS.Space.label` = 8 | ✅ |
| Right column | inner gap | `16px` (关于你 → 整理记录) | `DS.Space.group` = 16 | ✅ |
| Content area | overflow | `hidden` | two independent `ScrollView`s, one per column | ⚠️ Deliberate: the mockup is a fixed 640pt frame with 6 terms and 3 runs; a real 34-term dictionary must not push 整理记录 off a page whose right half is three rows long. Clipping alone would make rows unreachable. |
| Narrow layout | page padding | `24 → 14` (README §2) | `DS.Space.pageNarrow` below `MemoryMetrics.twoColumnMinimum` (640) | ✅ |
| Narrow layout | column stacking | not drawn for 03B | single scroller, `DS.Space.group` between the three groups | ⚠️ Not specified by 03B; follows README §2's narrow rule. |

## Header

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| 「记忆」 | font-size | `20px` | `DS.Text.title()` = 20 | ✅ |
| 「记忆」 | font-weight | `700` | `.bold` | ✅ |
| 「记忆」 | letter-spacing | `-.02em` = −0.4pt | `DS.Tracking.title` = −0.4 | ✅ |
| 「记忆」 | colour | inherited (`#1C1C1E`) | default `.primary` | ✅ |
| Status line | font | `11px ui-monospace` | `DS.Text.mono()` = 11pt monospaced | ✅ |
| Status line | colour | `rgba(28,28,30,.4)` | was `.tertiary` (≈ .26) | 🔧 → `DS.Colour.ink(0.4)` |
| Status line | width | `flex: 1` | `.frame(maxWidth: .infinity, alignment: .leading)` | ✅ |
| Status line | text | `本机 SQLite · 上次整理 8月13日 21:04` | `本机 SQLite · 上次整理 <Mdjmm>`; falls back to `尚未整理`, and shows the consolidate result while one is running/finished | ✅ (extra states not drawn by the mockup) |
| Status line | truncation | not specified | `lineLimit(1)`, `.middle` | ✅ |
| 立即整理 | height | `26px` | `MemoryMetrics.headerControlHeight` = 26 | ✅ |
| 立即整理 | padding | `0 11px` | `.padding(.horizontal, 11)` | ✅ |
| 立即整理 | radius | `7px` | was `DS.Radius.control` = 6 | 🔧 → `DS.Radius.iconButton` = 7 |
| 立即整理 | background | `#fff` | `DS.Colour.card` | ✅ |
| 立即整理 | border | `.75px rgba(0,0,0,.09)` | was `DS.Colour.border` (α .07) | 🔧 → `DS.Colour.controlBorder` = `rgba(0,0,0,.09)`, 0.75pt |
| 立即整理 | shadow | `0 1px 1.5px rgba(0,0,0,.05)` | `DS.Shadow.control` = α .05, radius 0.75, y 1 (CSS blur 1.5 ≙ radius .75) | ✅ |
| 立即整理 | font-size | `12px` | `DS.Text.caption()` = 12 | ✅ |
| 立即整理 | font-weight / colour | `400` / inherited | `.regular` / `.primary` | ✅ |
| 立即整理 | busy state | not drawn | `ProgressView` (small) replaces the label, button disabled | ✅ (addition) |
| Error banner | — | not drawn | `memoryEditError` renders an `exclamationmark.triangle` label in `DS.Colour.warningText` above the columns | ⚠️ Addition: the sidecar's memory writes can fail and the mockup has no failure state. |

## 实体词典 — label row

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Label row | padding | `0 4px` | `MemoryMetrics.labelInset` = 4 | ✅ |
| Label row | gap | `8px` | `DS.Space.label` = 8 | ✅ |
| Label row | align | `center` | `HStack` default | ✅ |
| 「实体词典 · 34」 | font-size | `11px` | `DS.Text.groupLabel()` = 11 | ✅ |
| 「实体词典 · 34」 | font-weight | `600` | `.semibold` | ✅ |
| 「实体词典 · 34」 | letter-spacing | `.05em` = 0.55pt | `DS.Tracking.groupLabel` = 0.55 | ✅ |
| 「实体词典 · 34」 | colour | `rgba(28,28,30,.42)` | was `.tertiary` (≈ .26) | 🔧 → `DS.Colour.ink(0.42)`, applied in `MemorySectionLabel` so 关于你 and 整理记录 move with it |
| 「实体词典 · 34」 | count | `· 34` = `memoryTerms.count` | `MemorySectionLabel(count:)` | ✅ |
| 「实体词典 · 34」 | width | `flex: 1` | `Spacer(minLength: 0)` after it | ✅ |
| 「添加词条」 | font-size | `11.5px` | was `DS.Text.caption()` = 12 | 🔧 → `DS.Text.size(11.5)` = 11.5 |
| 「添加词条」 | font-weight | `500` | `.medium` | ✅ |
| 「添加词条」 | colour | `#0D73FA` | `DS.Colour.accent` = `AppAccent.primary` = `rgb(.05,.45,.98)` = `#0D73FA` | ✅ |
| 「添加词条」 | behaviour | not drawn | popover with the shared add/edit form | ✅ (addition) |

## 实体词典 — card and rows

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Card | background | `#fff` | `dsCard()` → `DS.Colour.card` | ✅ |
| Card | border | `.75px rgba(0,0,0,.07)` | `DS.Colour.border` = `.primary.opacity(.07)`, 0.75pt | ✅ |
| Card | radius | `14px` | `DS.Radius.card` = 14 | ✅ |
| Card | shadow | `0 1px 2px rgba(0,0,0,.04)` | `DS.Shadow.card` = α .04, radius 1, y 1 | ✅ |
| Card | overflow | `hidden` | `.clipShape(RoundedRectangle(14, .continuous))` | ✅ |
| Row | padding | `11px 14px` | `DS.Space.rowV` = 11 / `MemoryMetrics.rowH` = 14 | ✅ |
| Row | gap | `12px` | `HStack(spacing: 12)` | ✅ |
| Row | align | `center` | `HStack` default | ✅ |
| Row separator | rule | `.75px rgba(0,0,0,.06)`, rows 2+ only | `dsHairline(.top)` = `DS.Colour.hairline` (α .06) at 0.75pt, suppressed on the first row | ✅ |
| Term | font-size / weight | `13px` / `500` | `DS.Text.body(.medium)` | ✅ |
| Term | colour | inherited | `.primary` | ✅ |
| Term | truncation | (col has `min-width: 0`) | `lineLimit(1)` | ✅ |
| Term/alias stack | gap | `3px` | `VStack(spacing: 3)` | ✅ |
| Term/alias stack | width | `flex: 1; min-width: 0` | `.frame(maxWidth: .infinity, alignment: .leading)` | ✅ |
| Aliases | font | `11px ui-monospace` | `DS.Text.mono()` = 11 mono | ✅ |
| Aliases | colour | `rgba(28,28,30,.42)` | was `.tertiary` (≈ .26) | 🔧 → `DS.Colour.ink(0.42)` |
| Aliases | overflow | `ellipsis` / `nowrap` | `lineLimit(1)`, `.truncationMode(.tail)` | ✅ |
| Aliases | separator | ` · ` | `joined(separator: " · ")`; `无别名` when empty | ✅ (empty case not drawn) |
| Confidence column | width | `44px` | `MemoryMetrics.confidenceColumn` = 44 | ✅ |
| Confidence column | gap / align | `4px` / `flex-end` | `VStack(alignment: .trailing, spacing: 4)` | ✅ |
| Confidence value | font | `10.5px ui-monospace` | was `DS.Text.mono()` (11) | 🔧 → `DS.Text.mono(MemoryMetrics.confidenceType)` = 10.5 mono |
| Confidence value | colour | `rgba(28,28,30,.4)` | was `.tertiary` (≈ .26) | 🔧 → `DS.Colour.ink(0.4)` |
| Confidence value | format | `92%` (integer) | `String(format: "%.0f%%")` | ✅ |
| Confidence bar | width × height | `40 × 2` | `MemoryMetrics.barWidth`/`barHeight` = 40 / 2 | ✅ |
| Confidence bar | radius | `99px` (pill) | `Capsule()` | ✅ |
| Confidence bar | track colour | `rgba(0,0,0,.08)` | was `DS.Colour.border` (α .07) | 🔧 → `DS.Colour.borderStrong` |
| Confidence bar | fill colour | `rgba(28,28,30,.32)` | was `.tertiary` (≈ .26) | 🔧 → `DS.Colour.ink(0.32)` |
| Confidence bar | fill width | `{{ t.bar }}` = the percentage | `barWidth × min(max(value,0),1)` | ✅ |
| Confidence bar | accessibility | — | `.accessibilityHidden(true)` (the percentage above it already says it) | ✅ |
| Origin column | width | `52px` | `MemoryMetrics.originColumn` = 52 | ✅ |
| Origin column | justify | `flex-end` | `.frame(width: 52, alignment: .trailing)` | ✅ |
| Origin badge | font-size | `10.5px` | was `DS.Text.groupLabel()` = 11 | 🔧 → `DS.Text.size(10.5, .semibold)` = 10.5 |
| Origin badge | font-weight | `600` | `.semibold` | ✅ |
| Origin badge | letter-spacing | none | no `.tracking` applied | ✅ |
| Origin badge | padding | `2px 6px` | `.padding(.vertical, 2)` / `.padding(.horizontal, 6)` | ✅ |
| Origin badge | radius | `5px` | was `DS.Radius.control` = 6 | 🔧 → `DS.Radius.tag` = 5 |
| Origin badge | neutral background | `rgba(0,0,0,.05)` | was `DS.Colour.inset` (α .035) | 🔧 → `DS.Colour.control`. This is the one that changed the look: .035 against white is close to no fill at all, which is why neutral badges used to read as bare text. |
| Origin badge | neutral text | `rgba(28,28,30,.5)` | was `.secondary` (≈ .50) | 🔧 → `DS.Colour.ink(0.5)`. The semantic was within a rounding of the literal, but the badge's fill moved to a literal in the row above, and leaving its text on a platform semantic is exactly how the two drift apart again. |
| Origin badge | untrusted background | `rgba(232,151,58,.14)` | `DS.Colour.warningFill` = `rgb(.910,.592,.227)` (`#E8973A`) at α .14 | ✅ |
| Origin badge | untrusted text | `#B26A16` | `DS.Colour.warningText` = `rgb(.698,.416,.086)` = `#B26A16` | ✅ |
| Origin badge | labels | `确认` / `自动` / `未确认` | `确认` (owner) · `自动` (system) · `助理` (agent) · `未确认` (untrusted) · `未知` | ✅ (agent/unknown not drawn) |
| Edit / delete | presence | hover-revealed, not persistent (README §4) | hover-revealed | ✅ |
| Edit / delete | layout cost | 03B's row has three columns and no fourth slot | was a permanently reserved 46pt column, pushing every badge 58pt left of the design | 🔧 → trailing `.overlay` over the badge; row at rest is now pixel-exact and hovering still causes no reflow |
| Edit / delete | icon | not drawn; README's symbol table maps 删除项 → `xmark` | `pencil` / `trash`, 11pt, `.secondary`, in 22pt hit targets | ⚠️ 03B draws no icons here. `xmark` in that table is for dismissing an inline chip; a row delete that opens a confirm dialog is the standard `trash` affordance, and `pencil` has no table entry at all. |
| Edit / delete | dismissal safety | — | `allowsHitTesting(false)` while hidden; delete opens a `confirmationDialog` | ✅ (addition) |
| Empty state | — | not drawn | one card-shaped row explaining the emptiness, `padding 12 14` | ⚠️ Addition: the mockup always has 34 terms. |

## 关于你

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Label | padding | `0 4px` | `MemoryMetrics.labelInset` = 4 | ✅ |
| 「关于你 · 5」 | font-size / weight / tracking | `11px` / `600` / `.05em` | `DS.Text.groupLabel()` + `DS.Tracking.groupLabel` | ✅ |
| 「关于你 · 5」 | colour | `rgba(28,28,30,.42)` | was `.tertiary` (≈ .26) | 🔧 → `DS.Colour.ink(0.42)` (shared `MemorySectionLabel`) |
| 「关于你 · 5」 | count | `· 5` | `memoryOwnerFacts.count` | ✅ |
| Card | background / border / radius / shadow / overflow | `#fff` · `.75px rgba(0,0,0,.07)` · `14px` · `0 1px 2px rgba(0,0,0,.04)` · hidden | `dsCard()` + `clipShape(14)` | ✅ |
| Row | padding | `12px 14px` | `MemoryMetrics.factRowV` = 12 / `MemoryMetrics.rowH` = 14 | ✅ |
| Row | direction / gap | column / `6px` | `VStack(alignment: .leading, spacing: 6)` | ✅ |
| Row separator | rule | `.75px rgba(0,0,0,.06)`, rows 2+ | `dsHairline(.top)`, first row suppressed | ✅ |
| Fact body | font-size | `13px` | `DS.Text.body()` = 13 | ✅ |
| Fact body | line-height | `1.6` | `lineSpacing(13 × 0.6)` = 7.8 | ✅ |
| Fact body | colour | inherited | `.primary` | ✅ |
| Fact body | wrapping | multi-line | `fixedSize(horizontal: false, vertical: true)` | ✅ |
| Badge (owner) | text | `你确认过` | `你确认过` | ✅ |
| Badge (system) | text | `自动整理` | `自动整理` | ✅ |
| Badge (untrusted) | text | `未经确认` | `未经确认` | ✅ |
| Badge | font-size / weight | `10.5px` / `600` | was `DS.Text.groupLabel()` = 11 | 🔧 → `DS.Text.size(10.5, .semibold)` = 10.5. One `MemoryOriginTag` serves both cards, so this and the dictionary badge move together. |
| Badge | padding / radius | `2px 6px` / `5px` | 2 / 6 ✅; radius was `DS.Radius.control` = 6 | 🔧 → `DS.Radius.tag` = 5 |
| Badge | neutral bg / fg | `rgba(0,0,0,.05)` / `rgba(28,28,30,.5)` | was `DS.Colour.inset` (α .035) / `.secondary` | 🔧 → `DS.Colour.control` / `DS.Colour.ink(0.5)` |
| Badge | untrusted bg / fg | `rgba(232,151,58,.14)` / `#B26A16` | `DS.Colour.warningFill` / `DS.Colour.warningText` | ✅ |
| Badge | alignment (no actions) | `align-self: flex-start` | `HStack` + trailing `Spacer(minLength: 0)` — same left-flush result | ✅ |
| Untrusted row | background | `rgba(232,151,58,.05)` | `DS.Colour.warning.opacity(MemoryMetrics.reviewTint = .05)`, applied outside the padding so it fills the row | ✅ |
| Untrusted row | tint vs. hairline | hairline draws over the tint | tint inside `MemoryRowSeparator`, so the hairline sits on top | ✅ |
| Action row | layout / gap | flex, `align-items: center`, `8px` | `HStack(spacing: DS.Space.label = 8)` | ✅ |
| 「确认」 | font-size | `11.5px` | was `DS.Text.caption()` = 12 | 🔧 → `DS.Text.size(11.5)` = 11.5 |
| 「确认」 | font-weight | `500` | `.medium` | ✅ |
| 「确认」 | colour | `#0D73FA` | `DS.Colour.accent` | ✅ |
| 「确认」 | prominence | plain text button beside the badge, no dialog | plain text button beside the badge, no dialog, with a `.help` tooltip | ✅ — the affordance is at least as findable as the mockup's |
| 「删除」 | font-size / weight | `11.5px` / `500` | was 12 / `.medium` | 🔧 → `DS.Text.size(11.5, .medium)` = 11.5 |
| 「删除」 | colour | `rgba(28,28,30,.45)` | was `.secondary` (≈ .50) | 🔧 → `DS.Colour.ink(0.45)` |
| 「删除」 | safety | not drawn | `confirmationDialog` (destroys content, unlike 确认) | ✅ (addition) |
| Actions | which rows show them | only the `未经确认` row is drawn with them | every non-`owner` origin (`untrusted`, `agent`, `system`) | ⚠️ Deliberate: the sidebar's unconfirmed dot counts *every* non-owner origin, so an `agent`/`system`-only user would otherwise carry a dot with no way to clear it — the exact "flag you learn to ignore" 确认 exists to prevent. Only `untrusted` takes the amber tint, so the drawn row still looks exactly as designed. |
| Empty state | — | not drawn | explanatory card row | ⚠️ Addition. |

## 整理记录

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Label | padding | `0 4px` | `MemoryMetrics.labelInset` = 4 | ✅ |
| 「整理记录」 | font-size / weight / tracking | `11px` / `600` / `.05em` | `DS.Text.groupLabel()` + `DS.Tracking.groupLabel` | ✅ |
| 「整理记录」 | colour | `rgba(28,28,30,.42)` | was `.tertiary` (≈ .26) | 🔧 → `DS.Colour.ink(0.42)` (shared `MemorySectionLabel`) |
| 「整理记录」 | count | none | `count: nil` | ✅ |
| Card | background / border / radius / shadow / overflow | as above | `dsCard()` + `clipShape(14)` | ✅ |
| Row | padding | `11px 14px` | `DS.Space.rowV` = 11 / `MemoryMetrics.rowH` = 14 | ✅ |
| Row | align / gap | `baseline` / `12px` | `HStack(alignment: .firstTextBaseline, spacing: 12)` | ✅ |
| Row separator | rule | `.75px rgba(0,0,0,.06)`, rows 2+ | `dsHairline(.top)`, first row suppressed | ✅ |
| Time column | font | `11px ui-monospace` | `DS.Text.mono()` = 11 mono | ✅ |
| Time column | colour | `rgba(28,28,30,.42)` | was `.tertiary` (≈ .26) | 🔧 → `DS.Colour.ink(0.42)` |
| Time column | width | `76px`, `flex: none` | `MemoryMetrics.logTimeColumn` = 76, leading-aligned | ✅ |
| Time column | format | `08-13 21:04` | `MM-dd HH:mm`, `en_US_POSIX` (identical in every interface language) | ✅ |
| Summary | font-size | `12.5px` | was `DS.Text.caption()` = 12 | 🔧 → `DS.Text.size(12.5)` = 12.5 |
| Summary | line-height | `1.5` | was `lineSpacing(12 × 0.5)` = 6 | 🔧 → `lineSpacing(12.5 × 0.5)` = 6.25, following the corrected size above |
| Summary | width | `flex: 1` | `.frame(maxWidth: .infinity, alignment: .leading)` | ✅ |
| Summary | colour (normal) | inherited | `.primary` | ✅ |
| Summary | colour (rolled back) | `rgba(28,28,30,.45)` | was `.tertiary` (≈ .26) | 🔧 → `DS.Colour.ink(0.45)`. README §4 names `.tertiary` for this row and the CSS says `.45`; 稿子优先 settles it in the CSS's favour. |
| Rolled-back row | text | `已回滚` alone | `已回滚 · <summary>` | ⚠️ The mockup's third row has no summary text to show; keeping the summary preserves *what* was rolled back, which is the only reason the row is still on screen. |
| Empty state | — | not drawn | explanatory card row | ⚠️ Addition. |

---

## Token steps this page uses

The four gaps the first pass recorded are closed. They were closed in
`DesignTokens.swift` (owned by another agent this batch), not worked around
here, so 03B still contains no naked literal for any of them.

**1 — text greys.** The design's band is `rgba(28,28,30, .32 / .40 / .42 / .45
/ .5)`, and the hierarchical styles only offer ≈ .85 / .50 / .26 / .10. Nine
rows on this page depended on it, and every one rendered `.tertiary` was roughly
0.16 alpha lighter than drawn — by far the largest visual difference the first
pass left. They now go through `DS.Colour.ink(_:)`, the scale's alpha axis, at
the alpha the markup states.

**2 — a 5pt radius, and a 7pt one.** `DS.Radius.tag` = 5 for the provenance
badges (README §7 specifies the same 5pt for type tags), `DS.Radius.iconButton`
= 7 for 立即整理 (README §5's `6–7pt` small controls). `DS.Radius.control` stays
6 for everything the mockup actually draws at 6.

**3 — hairline/fill alphas.** `DS.Colour.control` (`rgba(0,0,0,.05)`, the
neutral badge fill), `DS.Colour.borderStrong` (`.08`, the confidence-bar track)
and `DS.Colour.controlBorder` (`.09`, 立即整理's border), against the single
`DS.Colour.border` all three used to share. These are literal black; the ink
steps above are literal `#1C1C1E`. The handoff uses both bases and they are not
interchangeable, which is why they are two axes in `DS.Colour` rather than one.

**4 — half-point type steps.** `DS.Text.size(10.5, .semibold)` (badges),
`DS.Text.size(11.5)` / `size(11.5, .medium)` (添加词条 / 确认 / 删除) and
`DS.Text.size(12.5)` (整理记录 summary). The confidence percentage was already
correct via `DS.Text.mono(10.5)`, the one step that always took a size argument.
`MemoryMetrics.confidenceType` (10.5) stays as the page's own name for that mono
size, since `DS.Text.mono` is parameterised rather than stepped.

Nothing on 03B is still blocked on a token.

## Out-of-scope changes needed

1. **`SidebarShell.swift:335` — `ColumnHeader` spacing.** `HStack(spacing: 8)`;
   03B, 03A and 06A all draw a `14px` header gap (03C has a single child, and
   07A's `10px` is a different header — it leads with a `chevron.left` and is
   padded `0 24 0 16`). Affects every page's header, so it belongs to whoever
   owns the shell — change 8 → 14, or make it a parameter if 07A needs its own.
   This is the only structural miss left on 03B, and this pass was scoped out of
   that file too, so it is still open.
2. **`.primary` for 文字 主.** Every main-text row on this page still resolves
   through `.primary` = `labelColor` = black at 85% ≈ `#262626`, where the
   design says `#1C1C1E`. It is left alone deliberately: the handoff's own
   colour table names `.primary` for that role rather than giving a value to
   round, so it is not one of the collapses being reversed. If the owner wants
   it literal too, it is one more `DS.Colour` member and a `.foregroundStyle`
   sweep across all six screens, not a 03B change.

## Changes made

`Sources/OpenType/MemoryViews.swift` only:

1. **Content padding 16 → 24.** `pagePadding` used `DS.Space.content`; 03B's
   content area is `padding: 0 24 24` and `ColumnHeader` had already been
   corrected to `pageWide`, so every card on the page sat 8pt left of the title
   above it. This was the one alignment bug on the screen.
2. **Confidence percentage 11pt → 10.5pt mono**, via `DS.Text.mono(10.5)`.
3. **Dictionary row actions moved out of the layout.** They occupied a
   permanently reserved 46pt column, so the confidence and provenance columns sat
   58pt left of the design on every row, hovered or not. They are now a trailing
   `.overlay` on a card-coloured ground: at rest the row is exactly 03B's three
   columns, and revealing them still causes no reflow. The trade is that hovering
   covers the provenance badge — the one thing on the row you are not reaching
   for when you reach for edit or delete.
4. **Named the repeated literals** — `MemoryMetrics.rowH` (14), `factRowV` (12),
   `confidenceType` (10.5) — so the page's four cards cannot drift apart. Removed
   the now-unused `actionColumn`.

`MemoryOwnerFactRowView` was not restyled: 确认 and 删除 keep their position
beside the badge, their accent colours, their absence of a confirmation step on
确认, and the amber row tint that disappears when the flag clears.

## Changes made — second pass (稿子优先)

`Sources/OpenType/MemoryViews.swift` only. Nineteen rows across the page, all of
them a value the first pass rounded to the nearest scale step and none of them a
structural change:

1. **Nine greys off the hierarchical styles** and onto the literal
   `rgba(28,28,30,α)` steps — the status line and confidence percentage (.40),
   the three group labels, the aliases and the run-log timestamp (.42), the
   confidence-bar fill (.32), the badge text and 「删除」 (.50 / .45), and the
   rolled-back summary (.45). This is the change you can see from across the
   room: everything set `.tertiary` was ~0.16 alpha too light.
2. **Six type sizes back to their half-points** — the two provenance badges to
   10.5, 添加词条 / 确认 / 删除 to 11.5, the run-log summary to 12.5 (and its
   `lineSpacing` from 6 to 6.25 to keep the drawn 1.5 line-height).
3. **Two radii** — 立即整理 6 → 7, both provenance badges 6 → 5.
4. **Three fills and borders** — 立即整理's border .07 → .09, the confidence-bar
   track .07 → .08, and the neutral badge fill .035 → .05, the last of which is
   what makes a neutral badge read as a badge rather than as bare text.

Nothing was removed to match the mockup. The additions the first pass recorded —
the error banner, the busy state on 立即整理, the empty-state rows, the
hover-revealed edit/delete, 确认 on every non-owner origin, the `已回滚 ·` prefix
that keeps the summary — are all still there and still marked ⚠️ above with
their reasons unchanged.

**Verification.** `swift build` clean, `swift test` 524 tests / 0 failures.
