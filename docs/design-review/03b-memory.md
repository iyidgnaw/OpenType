# 03B · 记忆 — pixel review

Source of truth: `design_handoff_opentype_redesign_v1/OpenType 重设计（单文件·离线）.html`,
section **3B**, read as literal CSS (the same markup appears verbatim in
`OpenType 重设计.dc.html:491–566`). Prose in that folder's `README.md` §4 rounds
some numbers; where the two disagree, the CSS wins.

Implementation: `Sources/OpenType/MemoryViews.swift`.
Tokens: `Sources/OpenType/DesignTokens.swift` (`DS.*`), which this review is not
allowed to change — every value the token scale lacks is recorded as a **gap**
below rather than hardcoded into the view.

Status key: ✅ matches · 🔧 fixed by this review · ⚠️ deviates, reason given.

The design's text greys are stated as `rgba(28,28,30,α)`. SwiftUI's hierarchical
foreground styles are the DS-sanctioned way to express them and resolve on macOS
light to roughly `.primary` α .85, `.secondary` α .50, `.tertiary` α .26,
`.quaternary` α .10. Those are the only levels available; see **Gap 1**.

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
| Status line | colour | `rgba(28,28,30,.4)` | `.tertiary` (≈ .26) | ⚠️ **Gap 1** |
| Status line | width | `flex: 1` | `.frame(maxWidth: .infinity, alignment: .leading)` | ✅ |
| Status line | text | `本机 SQLite · 上次整理 8月13日 21:04` | `本机 SQLite · 上次整理 <Mdjmm>`; falls back to `尚未整理`, and shows the consolidate result while one is running/finished | ✅ (extra states not drawn by the mockup) |
| Status line | truncation | not specified | `lineLimit(1)`, `.middle` | ✅ |
| 立即整理 | height | `26px` | `MemoryMetrics.headerControlHeight` = 26 | ✅ |
| 立即整理 | padding | `0 11px` | `.padding(.horizontal, 11)` | ✅ |
| 立即整理 | radius | `7px` | `DS.Radius.control` = 6 | ⚠️ **Gap 2** |
| 立即整理 | background | `#fff` | `DS.Colour.card` | ✅ |
| 立即整理 | border | `.75px rgba(0,0,0,.09)` | `DS.Colour.border` = `.primary.opacity(.07)`, 0.75pt | ⚠️ **Gap 3** (width ✅, α .07 vs .09) |
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
| 「实体词典 · 34」 | colour | `rgba(28,28,30,.42)` | `.tertiary` (≈ .26), which is the pairing `DS.Text.groupLabel()`'s own doc comment prescribes | ⚠️ **Gap 1** |
| 「实体词典 · 34」 | count | `· 34` = `memoryTerms.count` | `MemorySectionLabel(count:)` | ✅ |
| 「实体词典 · 34」 | width | `flex: 1` | `Spacer(minLength: 0)` after it | ✅ |
| 「添加词条」 | font-size | `11.5px` | `DS.Text.caption()` = 12 | ⚠️ **Gap 4** |
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
| Aliases | colour | `rgba(28,28,30,.42)` | `.tertiary` (≈ .26) | ⚠️ **Gap 1** |
| Aliases | overflow | `ellipsis` / `nowrap` | `lineLimit(1)`, `.truncationMode(.tail)` | ✅ |
| Aliases | separator | ` · ` | `joined(separator: " · ")`; `无别名` when empty | ✅ (empty case not drawn) |
| Confidence column | width | `44px` | `MemoryMetrics.confidenceColumn` = 44 | ✅ |
| Confidence column | gap / align | `4px` / `flex-end` | `VStack(alignment: .trailing, spacing: 4)` | ✅ |
| Confidence value | font | `10.5px ui-monospace` | was `DS.Text.mono()` (11) | 🔧 → `DS.Text.mono(MemoryMetrics.confidenceType)` = 10.5 mono |
| Confidence value | colour | `rgba(28,28,30,.4)` | `.tertiary` (≈ .26) | ⚠️ **Gap 1** |
| Confidence value | format | `92%` (integer) | `String(format: "%.0f%%")` | ✅ |
| Confidence bar | width × height | `40 × 2` | `MemoryMetrics.barWidth`/`barHeight` = 40 / 2 | ✅ |
| Confidence bar | radius | `99px` (pill) | `Capsule()` | ✅ |
| Confidence bar | track colour | `rgba(0,0,0,.08)` | `DS.Colour.border` (α .07) | ⚠️ **Gap 3** |
| Confidence bar | fill colour | `rgba(28,28,30,.32)` | `.tertiary` (≈ .26) | ⚠️ **Gap 1** |
| Confidence bar | fill width | `{{ t.bar }}` = the percentage | `barWidth × min(max(value,0),1)` | ✅ |
| Confidence bar | accessibility | — | `.accessibilityHidden(true)` (the percentage above it already says it) | ✅ |
| Origin column | width | `52px` | `MemoryMetrics.originColumn` = 52 | ✅ |
| Origin column | justify | `flex-end` | `.frame(width: 52, alignment: .trailing)` | ✅ |
| Origin badge | font-size | `10.5px` | `DS.Text.groupLabel()` = 11 | ⚠️ **Gap 4** |
| Origin badge | font-weight | `600` | `.semibold` | ✅ |
| Origin badge | letter-spacing | none | no `.tracking` applied | ✅ |
| Origin badge | padding | `2px 6px` | `.padding(.vertical, 2)` / `.padding(.horizontal, 6)` | ✅ |
| Origin badge | radius | `5px` | `DS.Radius.control` = 6 | ⚠️ **Gap 2** |
| Origin badge | neutral background | `rgba(0,0,0,.05)` | `DS.Colour.inset` = `.primary.opacity(.035)` | ⚠️ **Gap 3** |
| Origin badge | neutral text | `rgba(28,28,30,.5)` | `.secondary` (≈ .50) | ✅ |
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
| 「关于你 · 5」 | colour | `rgba(28,28,30,.42)` | `.tertiary` (≈ .26) | ⚠️ **Gap 1** |
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
| Badge | font-size / weight | `10.5px` / `600` | `DS.Text.groupLabel()` = 11 / `.semibold` | ⚠️ **Gap 4** |
| Badge | padding / radius | `2px 6px` / `5px` | 2 / 6 ✅; `DS.Radius.control` = 6 | ⚠️ **Gap 2** (radius only) |
| Badge | neutral bg / fg | `rgba(0,0,0,.05)` / `rgba(28,28,30,.5)` | `DS.Colour.inset` (α .035) / `.secondary` | ⚠️ **Gap 3** (bg only) |
| Badge | untrusted bg / fg | `rgba(232,151,58,.14)` / `#B26A16` | `DS.Colour.warningFill` / `DS.Colour.warningText` | ✅ |
| Badge | alignment (no actions) | `align-self: flex-start` | `HStack` + trailing `Spacer(minLength: 0)` — same left-flush result | ✅ |
| Untrusted row | background | `rgba(232,151,58,.05)` | `DS.Colour.warning.opacity(MemoryMetrics.reviewTint = .05)`, applied outside the padding so it fills the row | ✅ |
| Untrusted row | tint vs. hairline | hairline draws over the tint | tint inside `MemoryRowSeparator`, so the hairline sits on top | ✅ |
| Action row | layout / gap | flex, `align-items: center`, `8px` | `HStack(spacing: DS.Space.label = 8)` | ✅ |
| 「确认」 | font-size | `11.5px` | `DS.Text.caption()` = 12 | ⚠️ **Gap 4** |
| 「确认」 | font-weight | `500` | `.medium` | ✅ |
| 「确认」 | colour | `#0D73FA` | `DS.Colour.accent` | ✅ |
| 「确认」 | prominence | plain text button beside the badge, no dialog | plain text button beside the badge, no dialog, with a `.help` tooltip | ✅ — the affordance is at least as findable as the mockup's |
| 「删除」 | font-size / weight | `11.5px` / `500` | 12 / `.medium` | ⚠️ **Gap 4** |
| 「删除」 | colour | `rgba(28,28,30,.45)` | `.secondary` (≈ .50) | ✅ |
| 「删除」 | safety | not drawn | `confirmationDialog` (destroys content, unlike 确认) | ✅ (addition) |
| Actions | which rows show them | only the `未经确认` row is drawn with them | every non-`owner` origin (`untrusted`, `agent`, `system`) | ⚠️ Deliberate: the sidebar's unconfirmed dot counts *every* non-owner origin, so an `agent`/`system`-only user would otherwise carry a dot with no way to clear it — the exact "flag you learn to ignore" 确认 exists to prevent. Only `untrusted` takes the amber tint, so the drawn row still looks exactly as designed. |
| Empty state | — | not drawn | explanatory card row | ⚠️ Addition. |

## 整理记录

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Label | padding | `0 4px` | `MemoryMetrics.labelInset` = 4 | ✅ |
| 「整理记录」 | font-size / weight / tracking | `11px` / `600` / `.05em` | `DS.Text.groupLabel()` + `DS.Tracking.groupLabel` | ✅ |
| 「整理记录」 | colour | `rgba(28,28,30,.42)` | `.tertiary` (≈ .26) | ⚠️ **Gap 1** |
| 「整理记录」 | count | none | `count: nil` | ✅ |
| Card | background / border / radius / shadow / overflow | as above | `dsCard()` + `clipShape(14)` | ✅ |
| Row | padding | `11px 14px` | `DS.Space.rowV` = 11 / `MemoryMetrics.rowH` = 14 | ✅ |
| Row | align / gap | `baseline` / `12px` | `HStack(alignment: .firstTextBaseline, spacing: 12)` | ✅ |
| Row separator | rule | `.75px rgba(0,0,0,.06)`, rows 2+ | `dsHairline(.top)`, first row suppressed | ✅ |
| Time column | font | `11px ui-monospace` | `DS.Text.mono()` = 11 mono | ✅ |
| Time column | colour | `rgba(28,28,30,.42)` | `.tertiary` (≈ .26) | ⚠️ **Gap 1** |
| Time column | width | `76px`, `flex: none` | `MemoryMetrics.logTimeColumn` = 76, leading-aligned | ✅ |
| Time column | format | `08-13 21:04` | `MM-dd HH:mm`, `en_US_POSIX` (identical in every interface language) | ✅ |
| Summary | font-size | `12.5px` | `DS.Text.caption()` = 12 | ⚠️ **Gap 4** |
| Summary | line-height | `1.5` | `lineSpacing(12 × 0.5)` = 6 | ✅ |
| Summary | width | `flex: 1` | `.frame(maxWidth: .infinity, alignment: .leading)` | ✅ |
| Summary | colour (normal) | inherited | `.primary` | ✅ |
| Summary | colour (rolled back) | `rgba(28,28,30,.45)` | `.tertiary` (≈ .26); README §4 says "已回滚的行摘要用 `.tertiary`" | ⚠️ **Gap 1** — the two sources disagree here; the CSS asks for ≈`.secondary`, the README names `.tertiary`. Left as `.tertiary` so it does not diverge from Gap 1's single global fix. |
| Rolled-back row | text | `已回滚` alone | `已回滚 · <summary>` | ⚠️ The mockup's third row has no summary text to show; keeping the summary preserves *what* was rolled back, which is the only reason the row is still on screen. |
| Empty state | — | not drawn | explanatory card row | ⚠️ Addition. |

---

## Token gaps

Four, none of which can be closed inside `MemoryViews.swift`. Each needs a
`DesignTokens.swift` change, which is out of this review's scope.

**Gap 1 — text greys.** `DS.Colour` has no text tones; the DS delegates them to
SwiftUI's hierarchical styles, whose only levels are ≈ .85 / .50 / .26 / .10.
03B asks for `.40`, `.42`, `.45`, `.5` and `.32` — a band that falls between
`.secondary` and `.tertiary`, closer to `.secondary`. Eight rows above depend on
this. It is by far the largest remaining visual difference on the page: every
grey rendered `.tertiary` is roughly 0.16 alpha lighter than drawn.

I did not switch them to `.secondary` locally, for two reasons. `DS.Text
.groupLabel()`'s own doc comment prescribes `.tertiary`, so changing it here
would contradict the token file while five sibling screens are being audited in
parallel against the same instruction — the result would be one page's greys
disagreeing with the other five. And `.secondary` is not right either (.50 vs
.42). The fix is a token:

```swift
// DS.Colour
static let textSecondary = Color.primary.opacity(0.42)  // rgba(28,28,30,.42)
static let textTertiary  = Color.primary.opacity(0.35)  // rgba(28,28,30,.35)
static let textMuted     = Color.primary.opacity(0.50)  // badge text, 「删除」≈.45
```

with `DS.Text.groupLabel()`'s doc comment repointed at `textSecondary`. That is
one edit that fixes all six screens at once.

**Gap 2 — a 5pt radius, and a 7pt one.** `DS.Radius` has 6 / 10 / 14 / 18. 03B's
provenance badges are `5px` and 立即整理 is `7px`; README §7 also specifies `5pt`
type tags and §5 specifies `6–7pt` small controls. Both currently render at
`DS.Radius.control` (6), so the badge is 1pt too round and the button 1pt too
square. Either add a `tag: CGFloat = 5` step and widen `control` to 7, or accept
6 as the closed value for both — but that is a scale decision, not a per-screen
one.

**Gap 3 — hairline/fill alphas.** Three literals sit between existing tokens:
the button border `rgba(0,0,0,.09)` (token: .07), the confidence-bar track
`rgba(0,0,0,.08)` (token: .07), and the neutral badge fill `rgba(0,0,0,.05)`
(`DS.Colour.inset` = .035). The badge fill is the visible one — .035 against
white is very close to no fill at all, which is why neutral badges currently
read as bare text. Suggest `DS.Colour.inset` → `.05` and a `DS.Colour.borderStrong`
= `.09` for lifted controls.

**Gap 4 — half-point type steps.** `DS.Text` is a closed six-step scale and says
so ("Anything outside them is a bug in the caller"). 03B uses `10.5` (badges),
`11.5` (添加词条 / 确认 / 删除) and `12.5` (整理记录 summary). Only the mono
step takes a size argument, which is why the confidence percentage could be
fixed (`DS.Text.mono(10.5)`) and the SF-set ones could not — those five render
at the nearest step (11 or 12), 0.5pt off. `Views.swift` (the legacy screen the
DS was created to replace) is full of `.system(size: 10.5/11.5/12.5)` literals,
so reintroducing them here would undo exactly what the scale closed. Decide once,
at the token level: either add `micro()` = 10.5 / `caption(small:)` = 11.5, or
ratify 11/12 as the rounded values and treat the handoff's halves as advisory.

## Out-of-scope changes needed

1. **`SidebarShell.swift:335` — `ColumnHeader` spacing.** `HStack(spacing: 8)`;
   03B, 03A and 06A all draw a `14px` header gap (03C has a single child, and
   07A's `10px` is a different header — it leads with a `chevron.left` and is
   padded `0 24 0 16`). Affects every page's header, so it belongs to whoever
   owns the shell — change 8 → 14, or make it a parameter if 07A needs its own.
   This is the only structural miss left on 03B.
2. **`DesignTokens.swift`** — Gaps 1–4 above.

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
beside the badge, their accent/secondary colours, their absence of a
confirmation step on 确认, and the amber row tint that disappears when the flag
clears.

**Verification.** `swift build` clean and `swift test` 524 XCTest + 13
swift-testing green, run in an isolated worktree containing this change alone
(the shared tree had unrelated in-flight edits from the parallel screen audits).
