# 01 · 会话 — pixel audit

Design source: `design_handoff_opentype_redesign_v1/OpenType 重设计（单文件·离线）.html`,
sections **01 · 主屏「会话」· 宽布局 1120×720** and **02 · 窄布局 460×720** (2A 会话列表, 2B 线程).
Values below are read from the literal inline CSS in that file, not from the README's prose
(the README rounds — e.g. it says the composer glyphs are 15pt where the markup says `font-size:16px`).

Implementation: `Sources/OpenType/SessionsViews.swift` (in scope),
`Sources/OpenType/SidebarShell.swift` + `Sources/OpenType/Views.swift` +
`Sources/OpenType/AssistantMarkdownView.swift` (out of scope — audited, changes reported to the lead).

Status key:

| | meaning |
|---|---|
| ✅ | already matched the design |
| 🔧 | did not match; fixed in this pass |
| ⚠ | deliberate deviation, reason given in the row |
| ⛔ | cannot be fixed from `SessionsViews.swift` — needs a change elsewhere (listed in §12) |

Counts: **208 properties checked — 150 already matched, 15 fixed here, 12 documented deviations,
31 blocked outside this file** (of which 8 are the narrow layout being correctly implemented but
never switched on, §12.1).

The app is pinned to the light appearance (`OpenTypeApp`), so every design colour below is a
literal target, not an adaptive one. Where a row says `.secondary` / `.tertiary` matches an
`rgba(28,28,30,.5)`-ish value, that is the README's own sanctioned mapping
(文字 次 → `.secondary`, 文字 三级 → `.tertiary`); SwiftUI's hierarchical styles land within a few
percent of the design alphas and are not individually re-listed as deviations.

---

## 1 · Window shell and the three columns

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Window | canvas background | `#F5F5F3` | `DS.Colour.canvas` = `rgb(0.961,0.961,0.953)` = `#F5F5F3` | ✅ |
| Window | wide reference size | 1120×720 | `idealWidth 1120 / idealHeight 720` (`Views.swift`) | ✅ |
| Window | narrow reference size | 460×720 | `DS.Size.windowMinWidth` = 460 | ✅ |
| Layout | breakpoint | 窄 ≤ 560 / 宽 ≥ 900, README recommends `< 720pt` → narrow | `DS.Size.narrowBreakpoint` = 720 | ✅ |
| Sidebar | width | 212 | `DS.Size.sidebar` = 212 | ✅ |
| Sidebar | right border | 0.75pt `rgba(0,0,0,.09)` | `DS.Colour.hairline` (0.06) in `SidebarShell` | ⛔ (§12.2) |
| List column | width | 334 | `DS.Size.list` = 334 | ✅ |
| List column | background | `#F5F5F3` | `DS.Colour.canvas` | ✅ |
| List column | right border | 0.75pt `rgba(0,0,0,.07)` | `DS.Colour.hairline` (0.06) in `SidebarShell` | ⛔ (§12.2) |
| Thread column | width | `flex:1; min-width:0` | `.frame(maxWidth: .infinity)` | ✅ |
| Thread column | background | `#fff` | `DS.Colour.card` = `Color.white` | ✅ |
| All columns | header strip height | 52 | `DS.Size.headerHeight` = 52 | ✅ |

---

## 2 · Sidebar, 212pt (`SidebarShell.swift` — out of scope, audited)

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Rail | background | `#EAEAE7` | `DS.Colour.sidebar` = `rgb(0.918,0.918,0.906)` = `#EAEAE7` | ✅ |
| Traffic-light strip | height | 52 | `Color.clear.frame(height: 52)` | ✅ |
| Brand row | padding | `2px 12px 14px` | `.padding(.vertical, 2)`, `.horizontal 12`, `.bottom 14` | ✅ |
| Brand row | gap | 9 | `HStack(spacing: 8)` | ⛔ (§12.2) |
| Brand mark | size / radius | 24×24, r7 | 24×24, r7 | ✅ |
| Brand mark | gradient | `135deg #0D73FA → #5751FA` | `.topLeading→.bottomTrailing`, accent → `DS.Colour.agent` `#4B45E8` | ⛔ (§12.2) — `#5751FA` has no token |
| Brand glyph | name / size / colour | `graphic_eq`→`waveform`, 14px, white | `waveform`, 14pt `.medium`, white | ✅ |
| Brand label | size / weight | 13 / 600 | `DS.Text.body(.semibold)` | ✅ |
| Nav list | padding / item gap | `0 10`, gap 2 | `.horizontal 10`, `VStack(spacing: 2)` | ✅ |
| Nav item | height / radius / padding / gap | 30, r6, `0 9`, gap 9 | 30, `DS.Radius.control` 6, 9, 9 | ✅ |
| Nav item | icon / label size | 16 / 13 | 16 / 13 | ✅ |
| Nav item selected | fill / text | `#0D73FA`, white, 500 | accent, white, `.medium` | ✅ |
| Nav item unselected | icon colour | `rgba(28,28,30,.55)` | `.secondary` | ✅ |
| Nav badge | font | 11 mono | `DS.Text.mono()` | ✅ |
| Nav badge selected | colour | `rgba(255,255,255,.7)` | `.white.opacity(0.85)` | ⛔ (§12.2) |
| 记忆 attention dot | size / colour | 5pt `#E8973A` | `DS.Colour.warning` = `#E8973A`, 5pt | ✅ |
| Nav items | membership | four: 会话/听写/记忆/设置 | `AppTab.allCases` | ✅ |
| Mode card | container padding | 12 | `.padding(12)` | ✅ |
| Mode card | radius / border | r10, 0.75 `rgba(0,0,0,.07)` | `DS.Radius.inset` 10, `DS.Colour.border` | ✅ |
| Mode card | shadow | `0 1px 2px rgba(0,0,0,.04)` | none | ⛔ (§12.2) |
| Mode card top row | padding / gap | `9 10 8`, gap 7 | `9/10/8`, gap 8 | ⛔ (§12.2) |
| Mode card top row | icon name / size / colour | `mic` filled→`mic.fill`, 15px, accent | mode symbol, 15pt, accent | ✅ |
| Mode card top row | title size / weight | 12 / 600 | `.system(size: 12, weight: .semibold)` | ✅ |
| Mode card top row | hint font | 10 mono | `DS.Text.mono(10)` | ✅ |
| Mode card top row | disclosure icon | `unfold_more`→`chevron.up.chevron.down`, 14px | 10pt `.semibold` | ⛔ (§12.2) |
| Mode card bottom row | separator / padding | top hairline, `7 10` | `dsHairline(.top)`, 7/10 | ✅ |
| Mode card bottom row | dot size / colour | 5pt `#34A853` | `DS.Colour.ok` = `#34A853`, 5pt | ✅ |
| Mode card bottom row | text font | 10 mono | `DS.Text.mono(10)` | ✅ |

---

## 3 · List column header (`SessionsListColumn.header`)

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Header | height | 52 | `DS.Size.headerHeight` | ✅ |
| Header | horizontal gutter | 16 (both layouts) | was 24 via `ColumnHeader`; now `SessionColumnHeader(leading: 16, trailing: 16)` | 🔧 |
| Header | gap | 10 | `spacing: 10` | ✅ |
| 会话 title | size / weight | 20 / 700 | `DS.Text.title()` = 20 `.bold` | ✅ |
| 会话 title | letter-spacing | `-.02em` = −0.4pt | `DS.Tracking.title` = −0.4 | ✅ |
| 会话 title | flex | `flex:1` | `.frame(maxWidth: .infinity, alignment: .leading)` | ✅ |
| 会话 title | copy | 「会话」 | 「会话」/ "Sessions" | ✅ |
| Search button | size / radius | 26×26, r7 | 26×26, `SessionMetrics.iconButtonRadius` 7 | ✅ |
| Search button | fill / border | `#fff`, 0.75 `rgba(0,0,0,.09)` | `DS.Colour.card`, `DS.Colour.border` (0.07) | ⚠ token — the design tokens table declares 0.07 the single global border value; the mockup's local 0.09 is not a fifth border weight |
| Search button | shadow | `0 1px 1.5px rgba(0,0,0,.05)` | `DS.Shadow.control` = 0.05, r0.75, y1 | ✅ |
| Search icon | name / size / colour | `search`→`magnifyingglass`, 16px, `rgba(28,28,30,.6)` | was 14 `.medium`; now `SessionMetrics.glyph` 16, `.secondary` | 🔧 |
| Add button | size / radius / fill | 26×26, r7, `#0D73FA` | 26×26, 7, accent | ✅ |
| Add button | shadow | `0 1px 2px rgba(13,115,250,.3)` | accent 0.30, r1, y1 | ✅ |
| Add icon | name / size / colour | `add`→`plus`, 16px, `#fff` | was 14 `.medium`; now 16, white | 🔧 |

---

## 4 · Filter chips (`SessionFilterChip`)

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Chip row | padding | `0 16 10` | `.horizontal 16`, `.bottom 10` | ✅ |
| Chip row | gap | 5 | `HStack(spacing: 5)` | ✅ |
| Chip | height | 22 | `.frame(height: 22)` | ✅ |
| Chip | horizontal padding | 10 | `.padding(.horizontal, 10)` | ✅ |
| Chip | radius | 6 | `DS.Radius.control` = 6 | ✅ |
| Chip | font size | 11.5 | `DS.Text.caption()` = 12 | ⚠ scale — 11.5 is not one of the six steps; 12 is the nearest, and the whole point of the closed scale is that it does not gain a 6.5th value per screen |
| Chip selected | fill | `#1C1C1E` | `Color(nsColor: .labelColor)` | ✅ — the README maps 文字主 `#1C1C1E` → `.primary`; `.labelColor` is that colour |
| Chip selected | text / weight | `#fff` / 500 | `DS.Colour.card` white / `.medium` | ✅ |
| Chip unselected | fill | `rgba(0,0,0,.055)` | `DS.Colour.hairline` = 0.06 | ✅ |
| Chip unselected | text | `rgba(28,28,30,.6)` | `.secondary` | ✅ |
| Chip dot | size / gap | 5pt, gap 5 | `DS.Size.statusDot` 5, spacing 5 | ✅ |
| Chip dot | Agent colour | `#4B45E8` | `DS.Colour.agent` | ✅ |
| Chip dot | 问答 colour | `#0D73FA` | `DS.Colour.accent` | ✅ |
| Chip dot | 全部 has none | — | `filter.kind == nil` | ✅ |
| Chip | copy | 全部 / Agent / 问答 | `SessionFilter.title` | ✅ |

---

## 5 · List content area

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Content | padding wide | `0 12 12` | `.horizontal 12`, `.bottom 12` | ✅ |
| Content | padding narrow | `0 14 14` | `DS.Space.pageNarrow` 14 — correct but unreachable | ⛔ (§12.1) |
| Content | gap between groups | 14 | `LazyVStack(spacing: 14)` | ✅ |
| Content | scrolls | `flex:1; overflow:hidden` | `ScrollView`, indicators hidden | ✅ |

### 5.1 · 进行中 group

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Group | gap | 7 | `VStack(spacing: 7)` | ✅ |
| Label row | padding / gap | `0 4`, gap 6 | `.horizontal 4`, spacing 6 | ✅ |
| Pulse dot | size / colour | 5pt `#0D73FA` | 5pt accent | ✅ |
| Pulse dot | animation | `otPulse 1.4s ease-in-out infinite`, opacity 1→.35, scale 1→.82 | `.easeInOut(1.4).repeatForever(autoreverses:)`, 1→0.35, 1→0.82 | ✅ |
| Label | size / weight | 11 / 600 | `DS.Text.groupLabel()` | ✅ |
| Label | letter-spacing | `.05em` = 0.55pt | `DS.Tracking.groupLabel` = 0.55 | ✅ |
| Label | colour | `rgba(28,28,30,.42)` | `.tertiary` | ✅ |
| Label | copy | 「进行中」 | 「进行中」/ "In progress" | ✅ |

### 5.2 · 进行中 card (`SessionRunningCard`)

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Card | fill | `#fff` | `DS.Colour.card` | ✅ |
| Card | border | 0.75 `rgba(13,115,250,.28)` | `DS.Colour.accent.opacity(0.28)`, 0.75 | ✅ |
| Card | radius | 14 | `DS.Radius.card` | ✅ |
| Card | shadow | `0 2px 8px rgba(13,115,250,.10)` | `DS.Shadow.running` = accent 0.10, r4, y2 | ✅ |
| Card | padding | `13 14` | `.vertical 13`, `.horizontal 14` | ✅ |
| Card | gap | 10 | `VStack(spacing: 10)` | ✅ |
| Task text | size / weight | 13 / 500 | `DS.Text.body(.medium)` | ✅ |
| Task text | line height | 1.5 | `.lineSpacing(4)` | ✅ |
| Inner block | fill | `#F5F5F3` | `DS.Colour.canvas` | ✅ |
| Inner block | radius | 8 | `DS.Radius.inset` = 10 | ⚠ scale — 8 is not one of the four radii; the README's own table puts 卡内嵌套块 at 9–10 |
| Inner block | padding / gap | `8 10`, gap 5 | 8/10, spacing 5 | ✅ |
| Tool row | gap | 7 | `HStack(spacing: 7)` | ✅ |
| Tool icon | name / size / colour | `build`→`wrench.and.screwdriver`, 13px, `#4B45E8` | same, 13pt, `DS.Colour.agent` | ✅ |
| Tool text | font | 11 mono | `DS.Text.mono()` | ✅ |
| Tool text | colour | `rgba(28,28,30,.7)` | `.primary` (≈0.85) | ⚠ no 0.7 token; `.primary` is the nearer of the two available steps (`.secondary` ≈ 0.5) |
| Tool text | truncation | single line, ellipsis | `.lineLimit(1)`, `.truncationMode(.tail)` | ✅ |
| Progress bar | height / radius | 2, r99 | `.frame(height: 2)`, `Capsule()` | ✅ |
| Progress bar | track / fill | `rgba(0,0,0,.07)` / accent | `DS.Colour.border` / accent | ✅ |
| Progress bar | determinacy | 58% fill | indeterminate sweep | ⚠ `/agent/run` never reports a step total, so any percentage would be invented; the sweep says "still going", which is all that is known |
| Bottom row | left text font | 10 mono | `DS.Text.mono(10)` | ✅ |
| Bottom row | left text colour | `rgba(28,28,30,.42)` | `.tertiary` | ✅ |
| Bottom row | copy | 「第 6 步 · 已用 42s」 | 「第 N 步 · 已用 …」, live `TimelineView` | ✅ |
| 停止 | size / weight | 11 / 500 | `DS.Text.groupLabel()` = 11 / 600 | ⚠ token gap (§11.1) — no 11/medium step exists |
| 停止 | colour | `#0D73FA` | accent | ✅ |
| 停止 | copy | 「停止」 | 「停止」/ "Stop" | ✅ |

### 5.3 · Date group and rows (`SessionDay`, `SessionRow`)

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Group | gap | 7 | `VStack(spacing: 7)` | ✅ |
| Group label | padding | `0 4` | `.horizontal 4` | ✅ |
| Group label | size / weight / tracking / colour | 11 / 600 / `.05em` / `rgba(28,28,30,.42)` | `DS.Text.groupLabel()`, 0.55, `.tertiary` | ✅ |
| Group label | copy | 「今天」「昨天」 | 今天 / 昨天 / dated, locale-aware | ✅ |
| Card | one card holds N rows | not one card per row | `VStack(spacing: 0)` of rows, clipped, `.dsCard()` | ✅ |
| Card | fill / border / radius | `#fff`, 0.75 `rgba(0,0,0,.07)`, 14 | `dsCard()` | ✅ |
| Card | shadow | `0 1px 2px rgba(0,0,0,.04)` | `DS.Shadow.card` = 0.04, r1, y1 | ✅ |
| Card | clip | `overflow:hidden` | `.clipShape(RoundedRectangle(14))` | ✅ |
| Row | padding | `11 13` | `DS.Space.rowV` 11 / `DS.Space.rowH` 13 | ✅ |
| Row | separator | top 0.75 `rgba(0,0,0,.06)` | `DS.Colour.hairline`, 0.75 | ✅ |
| Row | separator on first row | present (template applies it to every row) | suppressed on the first row | ⚠ the card already draws a border there; keeping it would double the line at the card's top edge |
| Row | inner gap | 4 | `VStack(spacing: 4)` | ✅ |
| Row line 1 | gap | 7 | `HStack(spacing: 7)` | ✅ |
| Row line 1 | type dot | 5pt, Agent `#4B45E8` / 问答 `#0D73FA` | `DS.Size.statusDot`, `SessionKindStyle.dot` | ✅ |
| Row line 1 | title size / weight | 13 / 500 | `DS.Text.body(.medium)` | ✅ |
| Row line 1 | title truncation | single line, ellipsis | `.lineLimit(1)`, `.tail` | ✅ |
| Row line 1 | time font / colour | 11 mono, `rgba(28,28,30,.35)` | `DS.Text.mono()`, `.tertiary` | ✅ |
| Row line 1 | time format | `14:32` | `HH:mm` | ✅ |
| Row line 2 | preview text | 12, `rgba(28,28,30,.5)`, lh 1.45, `padding-left:12`, ellipsis | not rendered | ⛔ (§12.3) — `GET /conversations` returns id/kind/title/createdAt/updatedAt only; there is no truthful preview to draw |

---

## 6 · Thread header (`SessionThreadColumn.header`)

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Header | height | 52 | `DS.Size.headerHeight` | ✅ |
| Header | gutter wide | `0 20` | was 24 via `ColumnHeader`; now 20/20 | 🔧 |
| Header | gutter narrow | `0 14 0 10` | was 14/14; now leading 10 / trailing 14 | 🔧 |
| Header | gap | 10 wide / 8 narrow | was 10 both; now `narrow ? 8 : 10` | 🔧 |
| Header | bottom border | 0.75 `rgba(0,0,0,.07)` | was `dsHairline` (0.06); now `SessionEdgeBorder` = `DS.Colour.border` | 🔧 |
| Kind tag | padding | `2 7` | `.vertical 2`, `.horizontal 7` | ✅ |
| Kind tag | radius | 5 | `DS.Radius.control` = 6 | ⚠ scale — the README's radius table puts 标签 at 6 |
| Kind tag | size / weight | 11 / 600 | `DS.Text.groupLabel()` | ✅ |
| Kind tag | Agent fill / text | `rgba(75,69,232,.11)` / `#4B45E8` | `agent.opacity(0.12)` / `agent` | ✅ (README specifies .12) |
| Kind tag | 问答 fill / text | `rgba(13,115,250,.11)` / `#0A5CC8` | `accent.opacity(0.11)` / `rgb(0.039,0.361,0.784)` = `#0A5CC8` | ✅ |
| Kind tag | copy | 「Agent」「问答」 | `SessionKind.title` | ✅ |
| Title | size / weight | 14 / 600 | `DS.Text.section()` = 15 / 600 | ⚠ scale — there is no 14 step; 15/semibold is the nearest, and per-screen exceptions are how the previous twelve-size UI happened |
| Title | flex / truncation | `flex:1`, single line, ellipsis | `.frame(maxWidth: .infinity)`, `.lineLimit(1)` | ✅ |
| Copy button | icon / size / colour | `content_copy`→`doc.on.doc`, 17px, `rgba(28,28,30,.45)` | `doc.on.doc`, 17, `.secondary` | ✅ |
| Copy button | present in narrow | absent in 2B | was always shown; now `if !narrow` | 🔧 |
| More button | icon / size / colour | `more_horiz`→`ellipsis`, 17px | `ellipsis`, 17, `.secondary` | ✅ |
| Back chevron (narrow) | icon / size / colour | `chevron_left`→`chevron.left`, 20px, `#0D73FA` | `chevron.left`, 20, accent — correct but unreachable | ⛔ (§12.1) |

---

## 7 · Thread content

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Content | padding wide | `24 28` | `.vertical 24` (`DS.Space.pageWide`), `.horizontal 28` | ✅ |
| Content | padding narrow | `20 18` | `.vertical 20`, `.horizontal 18` | ✅ |
| Content | message gap | 20 wide / 18 narrow | `LazyVStack(spacing: narrow ? 18 : 20)` | ✅ |

### 7.1 · User bubble (`SessionTurn`)

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Bubble | alignment | right | `HStack { Spacer(); … }` | ✅ |
| Bubble | max width | 78% wide / 80% narrow | was 0.78 both; now `narrow ? 0.80 : 0.78` | 🔧 |
| Bubble | padding | `10 14` | `.vertical 10`, `.horizontal 14` | ✅ |
| Bubble | radius | `14 14 4 14` | `SessionBubbleShape` (14/14/4/14) | ✅ |
| Bubble | fill / text | `#0D73FA` / `#fff` | accent / white | ✅ |
| Bubble | size / line height | 13 / 1.6 | `DS.Text.body()`, `.lineSpacing(5)` | ✅ |

### 7.2 · Assistant body

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Body | no bubble, full width | — | `AssistantMarkdownView`, `maxWidth: .infinity` | ✅ |
| Body | size / line height | 13.5 / 1.75 | `fontSize: 13.5`, `.lineSpacing(7)` on the wrapper | ⛔ (§12.4) — MarkdownUI renders its own text runs; the wrapper's `lineSpacing` does not reach them |
| Body | heading | 15 / 600, 9pt below | MarkdownUI `Theme.gitHub` relative heading scale (`1.25em`+ of 13.5) | ⛔ (§12.4) |
| Body | paragraph spacing | 10pt below | `Theme.gitHub` default | ⛔ (§12.4) |
| Inline code | font / fill / padding / radius | 12.5 mono, `rgba(0,0,0,.045)`, `1.5 5`, r4 | `Theme.gitHub` code style (GitHub grey) | ⛔ (§12.4) |
| Trailing note | colour | `rgba(28,28,30,.55)` | body colour | ⛔ (§12.4) |
| Structured table (01, 文件表) | border / radius | 0.75 `rgba(0,0,0,.07)`, r10 | `Theme.gitHub` table style | ⛔ (§12.4) |
| Structured table | row padding / separator / gap | `8 12`, 0.75 `rgba(0,0,0,.06)`, gap 10 | `Theme.gitHub` | ⛔ (§12.4) |
| Structured table | icon / value / count | `folder` 15px `rgba(.4)`, 12 mono, 11.5 mono `rgba(.45)` | `Theme.gitHub` | ⛔ (§12.4) |
| Comparison table (2B) | header row fill | `#FAFAF8` + bottom hairline | `Theme.gitHub` | ⛔ (§12.4) |
| Comparison table (2B) | header / cell font | 11 mono `rgba(.45)` / 12.5 | `Theme.gitHub` | ⛔ (§12.4) |

### 7.3 · Step log (`StepLog`)

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Block | gap to the answer below it | 12 | was 20 (both were LazyVStack children); now wrapped in `VStack(spacing: 12)` | 🔧 |
| Block | border / radius | 0.75 `rgba(0,0,0,.07)`, r10 | `DS.Colour.border`, `DS.Radius.inset` 10 | ✅ |
| Block | fill | `#FAFAF8` | `DS.Colour.inset` = `primary.opacity(0.035)` | ✅ (README sanctions either) |
| Block | clip | `overflow:hidden` | rounded background + stroke | ✅ |
| Header | padding / gap | `8 12`, gap 8 | `.horizontal 12`, `.vertical 8`, spacing 8 | ✅ |
| Header | bottom separator | 0.75 `rgba(0,0,0,.06)` | `DS.Colour.hairline`, only while expanded | ⚠ a collapsed block has nothing under the line to separate it from |
| Header | chevron | `expand_more`→`chevron.down`, 14px, `rgba(28,28,30,.45)` | `chevron.down` / `chevron.right`, 14, `.tertiary` | ✅ |
| Header | label size / weight / colour | 12 / 600 / `rgba(28,28,30,.6)` | `DS.Text.caption()` + `.semibold`, `.secondary` | ✅ |
| Header | label copy | 「执行了 7 步」 | 「执行了 N 步」 | ✅ |
| Header | elapsed font / colour | 11 mono, `rgba(28,28,30,.4)` | `DS.Text.mono()`, `.tertiary` | ✅ |
| Body | padding / row gap | `9 12`, gap 6 | `.horizontal 12`, `.vertical 9`, spacing 6 | ✅ |
| Row | baseline alignment / gap | `align-items:baseline`, gap 9 | `.firstTextBaseline`, spacing 9 | ✅ |
| Row col 1 | font / width / colour | 10.5 mono, 16pt, `rgba(28,28,30,.3)` | `DS.Text.mono(10.5)`, `width: 16`, `.tertiary` | ✅ |
| Row col 2 | font / width / tint | 10.5 mono, 64pt, `#4B45E8` (read-only tools `rgba(28,28,30,.45)`) | `DS.Text.mono(10.5)`, `width: 64`, `DS.Colour.agent` for side-effecting, `.secondary` otherwise | ✅ |
| Row col 3 | font / colour / truncation | 11 mono, `rgba(28,28,30,.6)`, ellipsis | `DS.Text.mono()`, `.secondary`, `.lineLimit(1)` `.tail` | ✅ |

### 7.4 · Working row (2B 正在检索)

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Row | gap | 7 | `HStack(spacing: 7)` | ✅ |
| Dot | size / colour | 5pt accent | `SessionPulseDot` | ✅ |
| Dot | animation period | 1.2s | was 1.4s (shared with 进行中); now `SessionPulseDot(period: 1.2)` | 🔧 |
| Text | font / colour | 11 mono, `rgba(28,28,30,.4)` | `DS.Text.mono()`, `.tertiary` | ✅ |
| Text | copy | 「正在检索…」 | 「正在检索…」 | ✅ |

---

## 8 · Composer

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Composer | padding wide | `14 20 18` | top 14, horizontal 20, bottom 18 | ✅ |
| Composer | padding narrow | `12 16 16` | top 12, horizontal 16, bottom 16 | ✅ |
| Composer | top border | 0.75 `rgba(0,0,0,.07)` | was `dsHairline` (0.06); now `SessionEdgeBorder` = `DS.Colour.border` | 🔧 |
| Container | fill | `#F5F5F3` | `DS.Colour.canvas` | ✅ |
| Container | border | 0.75 `rgba(0,0,0,.08)` | `DS.Colour.border` (0.07) | ⚠ token — 0.07 is the declared single border value |
| Container | radius | 14 | `DS.Radius.card` | ✅ |
| Container | padding | `10 10 10 14` | leading 14, trailing 10, vertical 10 | ✅ |
| Container | alignment / gap | `flex-end`, gap 10 | `HStack(alignment: .bottom, spacing: 10)` | ✅ |
| Placeholder | size / colour | 13, `rgba(28,28,30,.35)` | `DS.Text.body()`, `.tertiary` | ✅ |
| Placeholder | bottom padding | 6 | `.padding(.bottom, 6)` | ✅ |
| Placeholder | copy | 「接着说,或按住 ⌥ 口述…」 | 「接着说，或按住 ⌥ 口述…」 | ⚠ fullwidth comma — the mockup uses ASCII `,` in every Chinese string in the file, which is an authoring artifact, not a typographic instruction |
| Mic button | size / radius | 30×30, r9 | 30×30, `SessionMetrics.composerButtonRadius` 9 | ✅ |
| Mic button | fill / border / shadow | `#fff`, 0.75 `rgba(0,0,0,.09)`, `0 1px 1.5px rgba(0,0,0,.05)` | `DS.Colour.card`, `DS.Colour.border`, `DS.Shadow.control` | ✅ |
| Mic icon | name / size / colour | `mic` filled → `mic.fill`, 16px, accent | was 15 `.medium`; now `SessionMetrics.glyph` 16 | 🔧 |
| Send button | size / radius / fill | 30×30, r9, `#0D73FA` | 30×30, 9, accent | ✅ |
| Send button | shadow | `0 1px 2px rgba(13,115,250,.3)` | accent 0.30, r1, y1 | ✅ |
| Send icon | name / size / colour | `arrow_upward`→`arrow.up`, 16px, `#fff` | was 15 `.medium`; now 16, white | 🔧 |

---

## 9 · Narrow layout (section 02)

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Icon rail | width | 52 | `DS.Size.iconRail` = 52 | ✅ |
| Icon rail | background / right border | `#EAEAE7`, 0.75 `rgba(0,0,0,.09)` | `DS.Colour.sidebar`, hairline 0.06 | ⛔ (§12.2) |
| Icon rail | top padding / item gap | 14 / 4 | 52pt clear strip, `VStack(spacing: 2)` | ⛔ (§12.2) |
| Icon rail | brand size / radius / bottom margin | 24×24, r7, 10 | 24×24, r7, `.padding(.bottom, 14)` | ⛔ (§12.2) |
| Icon rail | nav item size / radius | 34×30, r7 | 34×30, r7 | ✅ |
| Icon rail | nav icon size | 17 | 17 | ✅ |
| Icon rail | selected fill | accent | accent | ✅ |
| Icon rail | 记忆 dot position | absolute `top:4 right:5`, 5pt `#E8973A` | `.offset(x: -5, y: 4)` from `.topTrailing`, `DS.Colour.warning` | ✅ |
| Icon rail | mic button size / radius | 34×34, r9 | 34×34, r9 | ✅ |
| Icon rail | mic button fill / border / shadow | `#fff`, 0.75 `rgba(0,0,0,.08)`, `0 1px 2px rgba(0,0,0,.05)` | `DS.Colour.card`, `DS.Colour.border`, no shadow | ⛔ (§12.2) |
| Icon rail | mic glyph size | 17 | 15 | ⛔ (§12.2) |
| Icon rail | mic bottom margin | 14 | 12 | ⛔ (§12.2) |
| List (2A) | header gutter | 16 (same as wide) | 16 | 🔧 (same fix as §3) |
| List (2A) | content gutter | 14 | `DS.Space.pageNarrow` — correct but unreachable | ⛔ (§12.1) |
| List (2A) | chips / cards / rows | identical to wide | identical code path | ✅ |
| Thread (2B) | presentation | push over the list, not side by side | `SidebarShell` ZStack + `.move(edge: .trailing)` | ✅ |
| Thread (2B) | back affordance | `chevron.left` in the header | `if narrow` branch | ⛔ (§12.1) — `narrow` is never `true`, so in a <720pt window there is currently **no way back to the list** |
| Thread (2B) | header gutter / gap | `0 14 0 10`, gap 8 | implemented | ⛔ (§12.1) |
| Thread (2B) | content padding / message gap | `20 18` / 18 | implemented | ⛔ (§12.1) |
| Thread (2B) | bubble max width | 80% | implemented | ⛔ (§12.1) |
| Thread (2B) | composer padding | `12 16 16` | implemented | ⛔ (§12.1) |

---

## 10 · Present in the implementation, not drawn in the design

Not deviations — the mockup draws one state of a screen that has more than one. Listed so the
next reviewer does not have to work out whether they were invented by accident.

| Element | What it is | Metrics used |
|---|---|---|
| Search field | The design draws the 搜索 button but no results screen. It filters what is already rendered, exactly like the chips. | 26pt tall, r7, white + `DS.Colour.border`, 16pt gutter, `DS.Text.caption()` |
| Empty list | A blank column reads as broken. | `DS.Text.caption()`, `.secondary`, centred |
| Thread placeholder | The wide layout with nothing selected. | `bubble.left.and.bubble.right.fill` 22pt `.quaternary` + caption |
| Loading thread | Between opening a row and the fetch returning. | small `ProgressView` + caption |
| Selected-row tint | The wide layout shows list and thread together; without it the list cannot say which row you are reading. | `accent.opacity(0.08)` |
| Step numbering | The design shows `{{ st.n }}` placeholders. | zero-padded `%02d`, 10.5 mono |

---

## 11 · Token gaps

Values the design asks for that `DesignTokens.swift` has no step for. Reported rather than
hardcoded — a one-off literal is exactly what the closed scale exists to prevent.

1. **11pt / medium text.** The 停止 action (§5.2) is 11/500 in the design. The scale's only 11pt
   step is `groupLabel` (11/600, meant for 今天 / 进行中). A small-action step —
   `DS.Text.action()` = 11 `.medium` — would cover this and probably the equivalents on other
   screens.
2. **A 0.7-alpha foreground.** The running card's tool line (§5.2) is `rgba(28,28,30,.7)`, between
   `.primary` (≈0.85) and `.secondary` (≈0.5). Only worth adding if other screens hit it too.
3. **`#5751FA`, the brand gradient's end stop.** `DS.Colour.agent` is `#4B45E8` and is documented
   as "type tags and tool names, nothing else", so the brand mark is currently borrowing it.
   (Sidebar, out of scope — noted here because the token is what is missing.)
4. **A gutter-parameterised `ColumnHeader`.** Not a token, but the same shape of problem:
   `ColumnHeader` hardcodes 24/14, and the handoff gives different columns different gutters
   (list 16/16, thread 20/20 and 10/14, and 听写/记忆/设置 have their own). This screen now uses a
   private `SessionColumnHeader`; if the other screens hit the same wall, `ColumnHeader` should
   take `leading`/`trailing` instead and the private copy should be deleted.

---

## 12 · Changes needed outside `SessionsViews.swift`

### 12.1 · `narrow` is never passed — the narrow layout does not currently run (highest priority)

`Views.swift:93` calls `SessionsListColumn(model: model)` and `Views.swift:110` calls
`SessionThreadColumn(model:onSubmit:)`, both leaving `narrow` at its `false` default.
`SidebarShell` computes `narrow` inside its own `GeometryReader` and does not expose it, so
nothing downstream can see it. Consequences in a window under 720pt:

- the thread has **no back button**, so the pushed thread cannot be dismissed;
- gutters, message gap and bubble width stay at the wide values in a 408pt column.

It cannot be fixed from inside this file: the list column could infer narrowness from its own
width (334 exactly when wide), but the thread column's width ranges overlap between the two
layouts, so there is no honest signal to read.

Fix: `SidebarShell` should pass its computed `narrow` into the `list`/`detail` builders
(`@ViewBuilder var list: (Bool) -> List`), or publish it through an `EnvironmentKey`, and
`Views.swift` should forward it to both columns. All the narrow-path code in `SessionsViews.swift`
is in place and correct the moment it is wired.

### 12.2 · `SidebarShell.swift` (sidebar + icon rail)

| # | What | Design | Current |
|---|---|---|---|
| a | rail right border | 0.75 `rgba(0,0,0,.09)` | `DS.Colour.hairline` (0.06) |
| b | list-column right border | 0.75 `rgba(0,0,0,.07)` | `DS.Colour.hairline` (0.06) — should be `DS.Colour.border` |
| c | brand row gap | 9 | 8 |
| d | brand gradient end stop | `#5751FA` | `DS.Colour.agent` `#4B45E8` (needs the token in §11.3) |
| e | selected nav badge | `rgba(255,255,255,.7)` | `.white.opacity(0.85)` |
| f | mode card shadow | `0 1px 2px rgba(0,0,0,.04)` | none (`DS.Shadow.card` exists) |
| g | mode card top-row gap | 7 | 8 |
| h | `chevron.up.chevron.down` | 14px | 10pt `.semibold` |
| i | rail mic glyph | 17 | 15 |
| j | rail mic shadow | `0 1px 2px rgba(0,0,0,.05)` | none |
| k | rail mic bottom margin | 14 | 12 |
| l | rail top block | `padding-top:14`, brand `margin-bottom:10`, nav gap 4 | 52pt clear strip, brand `.bottom 14`, nav gap 2 |

(c/e/g/h are shared with whichever agent is auditing the sidebar itself — these are reported, not
claimed.)

### 12.3 · Conversation preview line (sidecar + `Models.swift`)

The design's list row is two lines; the second is a message preview. `GET /conversations`
(`sidecar/src/memory/conversations.ts:99` — `SELECT id, kind, title, createdAt, updatedAt`) does
not return one, and `ConversationSummary` (`Models.swift:1525`) has no field for it. To land the
row as drawn:

1. `listConversations` selects the latest message's content, truncated, as `preview`;
2. `ConversationSummary` gains `let preview: String?`;
3. `SessionRow` renders it at 12pt `.secondary`, `lineSpacing` for 1.45, `padding-leading: 12`,
   single line with tail truncation.

Step 3 is a five-line change in this file and is ready to make as soon as 1–2 exist.

### 12.4 · `AssistantMarkdownView.swift` (assistant body typography)

The assistant turn is styled by MarkdownUI's `Theme.gitHub` with only the body colour, background
and size overridden, so everything structural is still GitHub's web styling rather than the
handoff's. The design asks for:

- body 13.5 / line-height 1.75 (the `.lineSpacing(7)` this file applies to the wrapper does not
  reach MarkdownUI's own text runs);
- headings inside an answer at 15 / 600 with 9pt below (GitHub's theme uses a relative scale, so
  they currently come out at 16.9pt+);
- paragraphs 10pt apart;
- inline code 12.5 mono on `rgba(0,0,0,.045)`, padding `1.5 5`, radius 4;
- tables: 0.75 `rgba(0,0,0,.07)` border, radius 10, rows separated by 0.75 `rgba(0,0,0,.06)`, row
  padding `8 12`, `#FAFAF8` header row, values in mono;
- a trailing note paragraph at `rgba(28,28,30,.55)`.

This affects every surface that renders assistant text (the voice surface's result card as well as
this thread), so it wants to be one change in `AssistantMarkdownView`, not a per-screen override.
