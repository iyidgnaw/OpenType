# 07 · Agent 工具与 MCP 服务器 — pixel review

Source of truth: `design_handoff_opentype_redesign_v1/OpenType 重设计.dc.html`, lines
1064–1338 (§07 markup, the readable twin of the 4.4MB offline bundle — same
markup, assets not inlined), plus that folder's `README.md` §7, 「MCP 的关键行为」
and the SF-Symbols table.

Implementation: `Sources/OpenType/McpServerViews.swift`.
Tokens: `Sources/OpenType/DesignTokens.swift` (not modified — this review is
scoped to the one view file).

Status key — ✅ matches · ⚠️ deviates on purpose, reason given · ❌ blocked on a
change outside this file.

**Standing token collapses — all three reversed (2026-08-15).** This review
originally collapsed three whole classes of §07's literal CSS onto the README's
closed scale, and argued per class why the token should win. The product owner
has ruled the other way: **稿子优先 — 无条件还原设计稿**. The mockup's literal
values win unconditionally, and `DesignTokens.swift` carries the extra steps
this needs, so no row below is a naked literal.

| Was collapsed | §07 markup | Now |
|---|---|---|
| Type steps | `12.5` / `11.5` / `10.5` px | restored as literal steps; mono sizes go through `DS.Text.mono(_ size:)`, which already took a size |
| Radii | `4` / `5` / `7` / `8` px | `5` / `7` / `8` restored (the `4` is the code chip's, still unexpressible — see below) |
| Borders | `.045` / `.06` / `.09` / `.1` / `.12` / `.14` black | each α restored at the element that draws it |

The three "why the token wins" arguments are recorded in git history rather than
re-stated here — the decision they lost is not a close call to re-litigate.

Two things below are still ⚠️ and are **not** collapses, so they stay: the
`4px`-radius inline code chip (a `Text` run has no box model — a SwiftUI limit,
not a missing token), and 重启服务并连接's `0 11px` padding (`McpButton` is one
control shared with the two sheet footers, which the handoff itself draws at
`0 12px`).

---

## 7A · 主页面 (908×700)

### Frame and header

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Page frame | background | `#F5F5F3` | `DS.Colour.canvas` = `rgb(245,245,243)` | ✅ |
| Page frame | size / radius / shadow | `908×700`, radius `11`, `0 20px 60px rgba(0,0,0,.22)` | n/a — the mockup's window chrome, not a view | ✅ n/a |
| Header bar | height | `52px` | `DS.Size.headerHeight` = 52 | ✅ |
| Header bar | padding | `0 24px 0 16px` | `.leading DS.Space.content` (16) / `.trailing DS.Space.pageWide` (24) | ✅ |
| Header bar | gap | `10px` | `HStack(spacing: 10)` | ✅ |
| Back chevron | icon | `chevron_left` → `chevron.left` | `chevron.left` | ✅ |
| Back chevron | size | `20px` | `McpIcon.back` = 20 | ✅ |
| Back chevron | colour | `#0D73FA` | `DS.Colour.accent` | ✅ |
| Title 「Agent 工具」 | font | `20px / 700` | `DS.Text.title()` = 20 bold | ✅ |
| Title | tracking | `-.02em` (= −0.4pt at 20) | `DS.Tracking.title` = −0.4 | ✅ |
| Title | fill | `flex: 1` | `Spacer()` after it | ✅ |
| 重启服务并连接 | height | `26px` | `.frame(height: 26)` in `McpButton` | ✅ |
| 重启服务并连接 | padding-h | `11px` | `11` — `McpButton(paddingH:)`, defaulted to the 12 the sheet and 7D footers draw | 🔧 was 12 for all three; the shared control names the odd one out, same as `border` below |
| 重启服务并连接 | radius | `7px` | `DS.Radius.smallControl` = 7 | 🔧 was `control` = 6 |
| 重启服务并连接 | background | `#fff` | `DS.Colour.card` | ✅ |
| 重启服务并连接 | border | `.75px rgba(0,0,0,.09)` | `DS.Colour.controlBorder` (.09), `0.75` | 🔧 was `border` = .07 |
| 重启服务并连接 | shadow | `0 1px 1.5px rgba(0,0,0,.05)` | `DS.Shadow.control` | ✅ CSS blur maps to a SwiftUI radius at half its value (`DS.Shadow`'s own note), so 1.5px *is* `radius: 0.75` |
| 重启服务并连接 | gap | `6px` | `HStack(spacing: 6)` | ✅ |
| 重启服务并连接 | icon | `restart_alt` → `arrow.clockwise`, `15px`, `rgba(28,28,30,.5)` | `arrow.clockwise`, `McpIcon.inlineGlyph` = 15, `.secondary` | ✅ |
| 重启服务并连接 | label | `12px` | `DS.Text.caption()` = 12, `.regular` | ✅ |

### Body layout

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Content area | padding | `0 24px 24px` | `.horizontal DS.Space.pageWide` (24), `.bottom` 24 | ✅ |
| Content area | column gap | `16px` | `HStack(spacing: DS.Space.group)` = 16 | ✅ |
| Content area | columns | two, each `flex: 1; min-width: 0` | `.frame(maxWidth: .infinity)` on both | ✅ |
| Content area | narrow fallback | — (mockup is fixed 908) | stacks vertically below `DS.Size.narrowBreakpoint` (720) | ⚠️ addition; the settings detail column is resizable, the mockup frame is not |
| Right column | row gap | `16px` | `VStack(spacing: DS.Space.group)` = 16 | ✅ |
| Left column | label→card gap | `8px` | `DS.Space.label` = 8 | ✅ |

### 内置工具 card

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Group label row | padding | `0 4px` | `.padding(.horizontal, 4)` in `McpGroupHeader` | ✅ |
| Group label row | alignment | `baseline` | `.firstTextBaseline` | ✅ |
| 「内置工具 · 10」 | font | `11px / 600` | `DS.Text.groupLabel()` = 11 semibold | ✅ |
| 「内置工具 · 10」 | tracking | `.05em` (= 0.55pt at 11) | `DS.Tracking.groupLabel` = 0.55 | ✅ |
| 「内置工具 · 10」 | colour | `rgba(28,28,30,.42)` | `.tertiary` | ✅ |
| 「内置工具 · 10」 | count | `10` | `McpBuiltInCatalog.count` = 6 + 4 = 10 | ✅ |
| 「始终可用，不可关闭」 | font / colour | `11px / 400`, `rgba(28,28,30,.4)` | `DS.Text.groupLabel().fontWeight(.regular)`, `.tertiary` | ✅ |
| Card | background | `#fff` | `DS.Colour.card` via `dsCard()` | ✅ |
| Card | border | `.75px rgba(0,0,0,.07)` | `DS.Colour.border`, `0.75` | ✅ |
| Card | radius | `14px` | `DS.Radius.card` = 14 | ✅ |
| Card | shadow | `0 1px 2px rgba(0,0,0,.04)` | `DS.Shadow.card` | ✅ |
| Card | clipping | `overflow: hidden` | `.clipShape(RoundedRectangle(14))` | ✅ |
| 「本机」/「网络与记忆」 strip | padding | `7px 14px` | `.horizontal 14`, `.vertical 7` | ✅ |
| … strip | background | `#FAFAF8` | `DS.Colour.insetSurface` = `#FAFAF8` | 🔧 was `inset` (black @ .035); the README folds the two together, the markup does not |
| … strip | font / tracking / colour | `11px / 600`, `.05em`, `rgba(28,28,30,.42)` | `groupLabel()` + `DS.Tracking.groupLabel` + `.tertiary` | ✅ |
| … strip | separators | 本机: `border-bottom`; 网络与记忆: `border-top` **and** `border-bottom`, each `.75px rgba(0,0,0,.06)` | one `0.75` hairline on top when not first; rows carry the line under it | ⚠️ the markup stacks a strip's `border-bottom` against the next row's `border-top`, painting 1.5px at that seam. One hairline per boundary is the intent; two is an artifact of writing it in CSS. |
| Tool row | padding | `10px 14px` | `.horizontal 14`, `.vertical 10` | ✅ |
| Tool row | separator | `border-top .75px rgba(0,0,0,.06)` | `dsHairline(.top)`, `DS.Colour.hairline` (.06), `0.75` | ✅ |
| Tool row | alignment / gap | `flex-start`, `10px` | `HStack(alignment: .top, spacing: 10)` | ✅ |
| Tool row | inner gap | `3px` | `VStack(spacing: 3)` | ✅ |
| Tool name | font | `12px` mono, weight 400 | `DS.Text.mono(12)` | ✅ |
| Tool name | colour | inherited `#1C1C1E` | `.primary` | ✅ |
| Tool description | font | `11.5px` | `DS.Text.size(11.5)` | 🔧 was `caption()` = 12 |
| Tool description | colour | `rgba(28,28,30,.5)` | `DS.Colour.ink(0.5)` | 🔧 was `.secondary`, which renders ≈ .50 of `labelColor`, not of `#1C1C1E` |
| Tool description | line-height | `1.5` | `.lineSpacing(3)` | 🔧 `.lineSpacing` is additive points rather than a ratio, so the value is `size × ratio − size × 1.24` (SF's own line height) rounded — the same conversion §04 uses |
| 「有副作用」 tag | font | `10.5px / 600` | `DS.Text.size(10.5, .semibold)` | 🔧 was `groupLabel()` = 11 |
| 「有副作用」 tag | padding | `2px 6px` | `.horizontal 6`, `.vertical 2` | ✅ |
| 「有副作用」 tag | radius | `5px` | `DS.Radius.tag` = 5 | 🔧 was `control` = 6 |
| 「有副作用」 tag | background | `rgba(232,151,58,.14)` | `DS.Colour.warningFill` = same | ✅ |
| 「有副作用」 tag | colour | `#B26A16` | `DS.Colour.warningText` = same | ✅ |
| 「有副作用」 tag | which rows | `bash`, `python`, `open_file`, `remember_fact` | same four | ✅ |
| Tool list | 本机 contents | `bash`, `python`, `open_file`, `read_file`, `list_dir`, `grep` (6) | same six, same order, same copy | ✅ |
| Tool list | 网络与记忆 contents | `web_search`, `web_fetch`, `remember_fact`, `consolidate_memory_now` (4) | same four, same order, same copy | ✅ |

### MCP 服务器 list

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Group label row | padding / alignment | `0 4px`, `center` | `0 4px`, `.center` via `McpGroupHeader(alignment:)` | 🔧 was `.firstTextBaseline` for both headers; the handoff draws 内置工具's on the baseline and this one on centres |
| 「MCP 服务器 · 3」 | font / tracking / colour | `11px / 600`, `.05em`, `rgba(28,28,30,.42)` | `groupLabel()` + tracking + `.tertiary` | ✅ |
| 「MCP 服务器 · N」 | count | live | `servers.count` | ✅ |
| 「添加服务器」 | font | `11.5px / 500` | `McpLinkButton` → `DS.Text.size(11.5, .medium)` | 🔧 was `caption()` = 12 |
| 「添加服务器」 | colour | `#0D73FA` | `DS.Colour.accent` | ✅ |
| List card | background / border / radius / shadow | as 内置工具 card | `dsCard()` + `.clipShape(14)` | ✅ |
| Server row | padding | `12px 14px` | `.horizontal 14`, `.vertical 12` | ✅ |
| Server row | separator | `border-top .75px rgba(0,0,0,.06)` (suppressed on row 1 by the card's own edge) | hairline when `!isFirst` | ✅ |
| Server row | alignment / gap | `flex-start`, `11px` | `HStack(alignment: .top, spacing: 11)` | ✅ |
| Server row | inner gap | `5px` | `VStack(spacing: 5)` | ✅ |
| Server row | hit target | whole row (`chevron_right`) | `Button` wrapping the row + `.contentShape(Rectangle())` | ✅ |
| Server name | font | `13px` mono, `600` | `DS.Text.mono(13, weight: .semibold)` | ✅ |
| Name↔tag gap | gap | `8px` | `HStack(spacing: 8)` | ✅ |
| Transport tag | font / padding / radius | `10.5px / 600`, `2px 6px`, `5px` | `DS.Text.size(10.5, .semibold)`, `6/2`, `DS.Radius.tag` = 5 | 🔧 was 11pt / radius 6 |
| Transport tag `stdio` | background / colour | `rgba(0,0,0,.05)` / `rgba(28,28,30,.5)` | `DS.Colour.control` (black @ .05) / `DS.Colour.ink(0.5)` | 🔧 fill was `inset` = .035, text was `.secondary` |
| Transport tag `http` | background | `rgba(13,115,250,.11)` | `DS.Colour.accent.opacity(0.11)` | ✅ |
| Transport tag `http` | colour | `#0A5CC8` | `DS.Colour.askTag` = `#0A5CC8` | 🔧 was `accent`; the handoff darkens text on a tinted blue fill, and §04's Q&A tag needs the same value |
| Command / URL line | font | `11px` mono | `DS.Text.mono()` = 11 | ✅ |
| Command / URL line | colour | `rgba(28,28,30,.45)` | `DS.Colour.ink(0.45)` | 🔧 was `.secondary`; `.45` is one of the dozen steps `ink(_:)` exists for |
| Command / URL line | truncation | `nowrap` + ellipsis | `.lineLimit(1)` | ✅ |
| Status row | gap | `6px` | `HStack(spacing: 6)` | ✅ |
| Status dot | size / shape | `5×5`, `border-radius: 50%` | `Circle()`, `DS.Size.statusDot` = 5 | ✅ |
| Status dot | colour (enabled) | `#34A853` | `DS.Colour.ok` = same | ✅ |
| Status dot | colour (disabled) | `rgba(28,28,30,.25)` | `Color.primary.opacity(0.25)` | ✅ |
| Status text | font / colour | `11px`, `rgba(28,28,30,.45)` | `groupLabel().fontWeight(.regular)`, `DS.Colour.ink(0.45)` | 🔧 colour was `.secondary` |
| Status text | copy (enabled) | 「6 个工具 · 上次启动已连接」 | 「N 个工具 · 测试通过 · 下次启动时连接」 after a passing test, otherwise 「已启用 · 下次启动时连接」 | ❌ **blocked** — `GET /config/mcp` returns stored config only; nothing reports which servers the running sidecar connected to or how many tools each contributed. Claiming 「上次启动已连接」 from config alone would be a guess. See "Out of scope" below. |
| Status text | copy (disabled) | 「已停用 · 不会在下次启动时连接」 | identical | ✅ |
| Row chevron | icon / size / colour | `chevron_right` → `chevron.right`, `16px`, `rgba(28,28,30,.3)` | `chevron.right`, `McpIcon.rowChevron` = 16, `DS.Colour.ink(0.3)` | 🔧 colour was `.tertiary` ≈ .26 |
| Row chevron | offset | `padding-top: 2px` | `.padding(.top, 2)` | ✅ |
| Footnote | padding | `0 4px` | `.padding(.horizontal, 4)` | ✅ |
| Footnote | font / colour / line-height | `11px`, `lh 1.6`, `rgba(28,28,30,.45)` | `groupLabel().fontWeight(.regular)`, `DS.Colour.ink(0.45)`, `.lineSpacing(4)` | 🔧 colour was `.tertiary`, line height was SwiftUI's default |
| Footnote | copy | 「连接在语音服务启动时建立，改动从下次启动生效。」 | identical | ✅ |
| Empty state | — | not drawn | 「还没有 MCP 服务器」 card | ⚠️ addition; zero servers is reachable and an empty white box says nothing |
| Loading state | — | not drawn | 「正在读取…」 card | ⚠️ addition; `mcpConfig` is `nil` until the first fetch returns |

### 风险卡

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Card | background | `#fff` | `DS.Colour.card` | ✅ |
| Card | border | `.75px rgba(232,151,58,.35)` | `DS.Colour.warning.opacity(0.35)`, `0.75` | ✅ |
| Card | radius | `14px` | `DS.Radius.card` | ✅ |
| Card | shadow | `0 1px 2px rgba(0,0,0,.04)` | `DS.Shadow.card` | ✅ **fixed** — was missing |
| Card | padding | `14px 16px` | `.horizontal DS.Space.content` (16), `.vertical 14` | ✅ |
| Card | gap / alignment | `11px`, `flex-start` | `HStack(alignment: .top, spacing: 11)` | ✅ |
| Icon | symbol | `warning` → `exclamationmark.triangle` | `exclamationmark.triangle` | ✅ |
| Icon | size / colour | `17px`, `#B26A16` | `McpIcon.cardGlyph` = 17, `DS.Colour.warningText` | ✅ |
| Text stack | gap | `4px` | `VStack(spacing: 4)` | ✅ |
| Title | font | `12.5px / 600` | `DS.Text.size(12.5, .semibold)` | 🔧 was `body(.semibold)` = 13 |
| Title | copy | 「MCP 工具和内置工具一样，直接执行」 | identical | ✅ |
| Body | font / colour / line-height | `11.5px`, `lh 1.6`, `rgba(28,28,30,.55)` | `DS.Text.size(11.5)`, `DS.Colour.ink(0.55)`, `.lineSpacing(4)` | 🔧 was 12pt `.secondary` with no line height |
| Body | copy | 「不经沙箱、不逐条确认。添加一个服务器等于把它提供的每个工具都交给 Agent。只添加你信任来源的服务器。」 | identical | ✅ |

### 环境变量卡

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Card | background / border / radius / shadow | `#fff`, `.75px rgba(0,0,0,.07)`, `14px`, `0 1px 2px rgba(0,0,0,.04)` | `dsCard()` | ✅ |
| Card | padding / gap | `14px 16px`, `7px` | `16 / 14`, `VStack(spacing: 7)` | ✅ |
| Title 「环境变量」 | font | `12.5px / 600` | `DS.Text.size(12.5, .semibold)` | 🔧 was 13 |
| Body | font / colour / line-height | `11.5px`, `lh 1.6`, `rgba(28,28,30,.55)` | `DS.Text.size(11.5)`, `DS.Colour.ink(0.55)`, `.lineSpacing(4)` | 🔧 was 12pt `.secondary` with no line height |
| `OPENTYPE_MCP_SERVERS` chip | font | `11px` mono | `DS.Text.mono()` on that run | ✅ |
| … chip | background | `rgba(0,0,0,.045)` | `DS.Colour.codeFill` (black @ .045) as an `AttributedString.backgroundColor` run | 🔧 was `inset` = .035 |
| … chip | padding / radius | `1.5px 5px`, `4px` | thin spaces (`U+2009`) inside the tinted run; no radius | ⚠️ a run inside a concatenated `Text` carries colour and font but no box model. Splitting the sentence into views to get a real padded chip would stop it wrapping as prose. |
| Body | copy (saved source) | 「检测到 … 里还有 2 个服务器。你已保存了自己的配置，环境变量整份被忽略，不会合并。」 | 「你已保存了自己的配置，所以 … 被整份忽略，不会合并。删掉最后一个服务器的意思是「没有 MCP 服务器」，不是退回环境变量那一套。」 | ⚠️ the count is unavailable (see next row); the added sentence is 「MCP 的关键行为」 #4, which the mockup carries in 7D only |
| 「查看被忽略的 2 个」 link | presence | `11.5px / 500`, `#0D73FA` | **absent** | ❌ **blocked** — when `source == "saved"` the sidecar does not return the ignored env servers, or a count of them. See "Out of scope". |

---

## 7B · 添加/编辑 · stdio (560pt sheet)

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Sheet | width | `560px` | `sheetWidth` = 560 when `transport == .stdio` | ✅ **fixed** — was a fixed 560 for both transports |
| Sheet | width at open | — | draft seeded in `init` via `McpServerDraft(seededFrom:)`, not in `onAppear` | ✅ **fixed follow-on** — a width that reads `draft.transport` must not be measured before the draft exists, or every http edit opens at 560 and snaps to 460 |
| Sheet | background | `#F7F7F5` | `DS.Colour.recessed` = `#F7F7F5` | 🔧 was `canvas` = `#F5F5F3` |
| Sheet | radius / border / shadow | `14px`, `.75px rgba(0,0,0,.08)`, `0 24px 70px rgba(0,0,0,.28)` | AppKit sheet chrome | ✅ n/a |
| Header | padding | `16px 20px 14px` | `.horizontal 20`, `.top DS.Space.content` (16), `.bottom 14` | ✅ |
| Header | gap | `10px` | `HStack(spacing: 10)` | ✅ |
| Header | separator | `border-bottom .75px rgba(0,0,0,.07)` | `dsHairline(.bottom, color: DS.Colour.border)` (.07) | 🔧 was .06 |
| Header title | font | `15px / 600` | `DS.Text.section()` = 15 semibold | ✅ |
| Header title | copy | 「添加 MCP 服务器」 / 「编辑 linear」 | identical, name interpolated | ✅ |
| Close button | icon / size / colour | `close` → `xmark`, `18px`, `rgba(28,28,30,.4)` | `xmark`, `McpIcon.sheetClose` = 18, `DS.Colour.ink(0.4)` | 🔧 colour was `.secondary` |
| Form | padding | `18px 20px` | `.horizontal 20`, `.vertical 18` | ✅ |
| Form | field gap | `16px` | `VStack(spacing: DS.Space.content)` = 16 | ✅ |
| Field | label→control gap | `6px` | `VStack(spacing: 6)` in `McpField` | ✅ |
| Field label | font | `12px / 500` | `DS.Text.caption()` + `.medium` | ✅ |
| 名称 input | height | `28px` | `.frame(height: 28)` | ✅ |
| 名称 input | radius | `7px` | `DS.Radius.smallControl` = 7 | 🔧 was 6 |
| 名称 input | background | `#fff` | `DS.Colour.card` | ✅ |
| 名称 input | border | `.75px rgba(0,0,0,.14)` | `DS.Colour.fieldBorder` (.14) | 🔧 was `border` = .07, half the drawn weight |
| 名称 input | shadow | `0 1px 1.5px rgba(0,0,0,.04)` | `DS.Shadow.control` | ✅ **fixed** — was missing |
| 名称 input | padding | `0 9px` | `.padding(.horizontal, 9)` | ✅ |
| 名称 input | font | `12.5px` mono | `DS.Text.mono(12.5)` | 🔧 restored; was 12 |
| 名称 helper | font / colour / line-height | `11px`, `lh 1.55`, `rgba(28,28,30,.45)` | `groupLabel().fontWeight(.regular)`, `DS.Colour.ink(0.45)`, `.lineSpacing(3)` | 🔧 colour was `.tertiary`, line height was the default |
| 名称 helper | copy | 「会成为工具名的前缀 —— `github__create_issue`。只能用字母、数字、`_` 和 `-`。」 | same sentence, all three identifiers chipped | 🔧 `_` and `-` were inline; a rule about which literal characters are legal is where the reader most needs the character told apart from the punctuation |
| 名称 helper | violation state | not drawn | swaps to the rule in `DS.Colour.warningText` while the typed name is illegal | ⚠️ addition, required by 「MCP 的关键行为」 #5 ("在输入时就校验") |
| 连接方式 | track height / radius | `28px`, `7px` | 28, `DS.Radius.smallControl` = 7 | 🔧 radius was 6 |
| 连接方式 | track background | `#EDEDEA` | `DS.Colour.segmentTrack` = `#EDEDEA` | 🔧 was `inset` composited over the sheet |
| 连接方式 | padding / gap | `2px` / `2px` | `.padding(2)`, `HStack(spacing: 2)` | ✅ |
| 连接方式 | segment height | `24px` (28 − 2 − 2) | `.frame(height: 24)` | ✅ |
| 连接方式 | selected fill / radius | `#fff`, `5px` | `DS.Colour.card`, `DS.Radius.tag` = 5 | 🔧 radius was 6 |
| 连接方式 | selected shadow | `0 1px 2px rgba(0,0,0,.1)` | `DS.Shadow.lifted` | 🔧 was `control`; §07 lifts the segment harder than a plain small control, so it takes its own step |
| 连接方式 | selected / unselected type | `12px / 500` / `12px / 400 rgba(28,28,30,.55)` | `caption()` + `.medium` / `.regular` + `.secondary` | ✅ |
| 连接方式 | labels | 「本地进程」 / 「远程 HTTP」 | identical | ✅ |
| 命令 input | all | as 名称 input | same `McpTextField` | ✅ (same ⚠️s) |
| 参数 label row | trailing action | 「添加一项」 `11.5px / 500` `#0D73FA` | `McpLinkButton` → `DS.Text.size(11.5, .medium)`, accent | 🔧 was 12pt |
| 参数 list | gap | `5px` | `VStack(spacing: 5)` | ✅ |
| 参数 row | height / radius | `26px`, `6px` | 26, `DS.Radius.control` = 6 | ✅ |
| 参数 row | background / border | `#fff`, `.75px rgba(0,0,0,.12)` | `DS.Colour.card`, `DS.Colour.buttonBorder` (.12) | 🔧 border was .07 |
| 参数 row | padding / gap | `0 8px`, `8px` | `.horizontal 8`, `HStack(spacing: 8)` | ✅ |
| 参数 row | index | `11px` mono, `rgba(28,28,30,.3)` | `DS.Text.mono()`, `DS.Colour.ink(0.3)` | 🔧 colour was `.tertiary` |
| 参数 row | index numbering | 1-based | `index + 1` | ✅ |
| 参数 row | value | `12px` mono, `flex: 1` | `DS.Text.mono(12)`, fills | ✅ |
| 参数 row | delete | `close` → `xmark`, `14px`, `rgba(28,28,30,.3)` | `xmark`, `McpIcon.removeGlyph` = 14, `DS.Colour.ink(0.3)` | 🔧 colour was `.tertiary` |
| 环境变量 label row | trailing action | 「添加一项」 | same | 🔧 as 参数 above |
| 环境变量 container | border / radius | `.75px rgba(0,0,0,.1)`, `8px` | `DS.Colour.blockBorder` (.1), `DS.Radius.block` = 8 | 🔧 was .07 / radius 10 |
| 环境变量 container | background / clipping | `#fff`, `overflow: hidden` | `DS.Colour.card`, rounded background | ✅ |
| 环境变量 row | padding / gap | `8px 10px`, `10px` | `.horizontal 10`, `.vertical 8`, `HStack(spacing: 10)` | ✅ |
| 环境变量 row | key | `12px` mono, `width: 150px`, `flex: none` | `DS.Text.mono(12)`, `.frame(width: secretKeyWidth)` = 150 for stdio | ✅ |
| 环境变量 row | key editability | static text (saved entry) | `Text` when `.saved`, `TextField` only for a newly added row | ✅ — renaming a key orphans its mask |
| 环境变量 row | value | `12px` mono, `rgba(28,28,30,.4)`, masked string | `DS.Text.mono(12)`, `DS.Colour.ink(0.4)`, the sidecar's mask verbatim | 🔧 colour was `.tertiary` |
| 环境变量 row | value editability | mask + 「更改」 link, never a field | `Text(mask)` + `McpLinkButton`; 「更改」 swaps to an **empty** `SecureField` | ✅ |
| 环境变量 row | 「更改」 | `11.5px / 500`, `#0D73FA` | `McpLinkButton` → `DS.Text.size(11.5, .medium)`, accent | 🔧 was 12pt |
| 环境变量 row | delete | `close`, `14px`, `rgba(28,28,30,.3)` | `xmark`, 14, `DS.Colour.ink(0.3)` | 🔧 colour was `.tertiary` |
| 环境变量 row | separators | single row drawn | `0.75` hairline between rows | ✅ |
| 环境变量 hint | font / colour / line-height | `11px`, `lh 1.55`, `rgba(28,28,30,.45)` | `groupLabel().fontWeight(.regular)`, `DS.Colour.ink(0.45)`, `.lineSpacing(3)` | 🔧 colour was `.tertiary`, line height was the default |
| 环境变量 hint | copy | 「保存后只回传遮盖值，原值不会再离开本机。键名可见，值不可见。」 | identical | ✅ |
| 测试结果块 | border / radius | `.75px rgba(0,0,0,.09)`, `10px` | `DS.Colour.controlBorder` (.09), `DS.Radius.inset` = 10 | 🔧 border was .07 |
| 测试结果块 | background / clipping | `#fff`, `overflow: hidden` | `DS.Colour.card` | ✅ |
| 测试结果块 header | padding / gap | `10px 12px`, `8px` | `.horizontal 12`, `.vertical 10`, `HStack(spacing: 8)` | ✅ |
| 测试结果块 header | separator | `border-bottom .75px rgba(0,0,0,.06)` | `dsHairline(.bottom)` | ✅ |
| 测试结果块 header | icon | `check` → `checkmark`, `15px`, `rgba(28,28,30,.55)` | `checkmark`, `McpIcon.inlineGlyph` = 15, `DS.Colour.ink(0.55)` | 🔧 colour was `.secondary` |
| 测试结果块 header | title | `12.5px / 600`, 「连接成功，发现 6 个工具」 | `DS.Text.size(12.5, .semibold)`, same sentence with the live count | 🔧 was 13 |
| 测试结果块 header | elapsed | `11px` mono, `rgba(28,28,30,.4)`, 「1.8s」 | `DS.Text.mono()`, `DS.Colour.ink(0.4)`, `%.1fs` measured around the probe | 🔧 colour was `.tertiary` |
| 测试结果块 body | padding / gap | `10px 12px`, `5px`, wrapping | `12 / 10`, `spacing: 5`, hand-packed rows | ✅ |
| Tool chip | font | `11px` mono | `DS.Text.mono()` | ✅ |
| Tool chip | padding / radius | `3px 7px`, `5px` | `7 / 3`, `DS.Radius.tag` = 5 | 🔧 radius was 6 |
| Tool chip | background | `rgba(0,0,0,.045)` | `DS.Colour.codeFill` (black @ .045) | 🔧 was `inset` = .035 |
| Tool chip | colour | `rgba(28,28,30,.65)` | `DS.Colour.ink(0.65)` | 🔧 was `.secondary` |
| Tool chip | packing width | 560 − 20 − 20 − 12 − 12 = 496 | `resultContentWidth` = `sheetWidth − 64` | ✅ **fixed** — was a hard-coded 496, wrong once the sheet can be 460 |
| Footer | padding / gap | `14px 20px`, `9px` | `.horizontal 20`, `.vertical 14`, `HStack(spacing: 9)` | ✅ |
| Footer | background | `#F1F1EF` | `DS.Colour.footerBar` = `#F1F1EF` | 🔧 was `inset` composited over the sheet |
| Footer | separator | `border-top .75px rgba(0,0,0,.07)` | `dsHairline(.top, color: DS.Colour.border)` (.07) | 🔧 was .06 |
| Footer hint | font / colour | `11.5px`, `rgba(28,28,30,.45)`, `flex: 1` | `DS.Text.size(11.5)`, `DS.Colour.ink(0.45)`, `Spacer()` | 🔧 was 11pt `.tertiary` |
| Footer hint | copy | 「连接在下次启动语音服务时建立」 | identical (create only) | ✅ |
| Footer hint | edit variant | 7C draws an empty `flex: 1` | 「删除」 link in `DS.Colour.error` | ⚠️ addition — deleting a server has no other entry point anywhere in §07 |
| 取消 / 重新测试 | height / padding / radius | `26px`, `0 12px`, `7px` | 26, 12, `DS.Radius.smallControl` = 7 | 🔧 radius was 6 |
| 取消 / 重新测试 | background / border / shadow | `#fff`, `.75px rgba(0,0,0,.12)`, `0 1px 1.5px rgba(0,0,0,.05)` | `DS.Colour.card`, `DS.Colour.buttonBorder` (.12), `DS.Shadow.control` | 🔧 border was .07 |
| 取消 / 重新测试 | font | `12px`, weight 400 | `DS.Text.caption()`, `.regular` | ✅ |
| 重新测试 | label | 「重新测试」 | 「测试连接」 before the first probe, then 「重新测试」 / 「测试中…」 | ⚠️ addition; the mockup only draws the post-probe state |
| 保存 | background / colour | `#0D73FA`, `#fff` | `DS.Colour.accent`, `.white` | ✅ |
| 保存 | shadow | `0 1px 2px rgba(13,115,250,.3)` | `.shadow(accent @ .3, radius 1, y 1)` | ✅ |
| 保存 | border | none | `.clear` | ✅ |
| 保存 | font | `12px / 500` | `caption()` + `.medium` | ✅ |
| 保存 | enablement | 「测试通过才让保存」 | `canSave` = fields valid ∧ passing test for the *current* draft signature ∧ not saving | ✅ |
| Blocker hint | — | not drawn | one line in `warningText` naming why the buttons are off | ⚠️ addition; a grey button with no stated reason is the failure mode this replaces |
| Stale-test notice | — | not drawn | replaces the result block when the draft changed after a probe | ⚠️ addition; a passing result shown beside a configuration it no longer describes would be worse than none |
| Disabled-server notice | — | not drawn | orange block at the top of the form when editing a disabled server | ⚠️ addition; 停用并保存 creates this state, so the way out of it has to be sayable |

---

## 7C · 远程 HTTP · 测试失败 (460pt)

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Sheet | width | `460px` | `sheetWidth` = 460 when `transport == .http` | ✅ **fixed** |
| Sheet | header title | 「编辑 linear」 | 「编辑 \(name)」 | ✅ |
| 连接方式 | selected segment | 远程 HTTP | driven by `draft.transport` | ✅ |
| 地址 input | all | as 名称 input, value `https://mcp.linear.app/sse` | same `McpTextField`, placeholder `https://mcp.example.com/mcp` | ✅ (same ⚠️s) |
| 地址 | label | 「地址」 | 「地址」 | ✅ |
| 请求头 | label / action | 「请求头」 + 「添加一项」 | identical | ✅ |
| 请求头 container | border / radius / background | `.75px rgba(0,0,0,.1)`, `8px`, `#fff` | `DS.Colour.blockBorder` (.1), `DS.Radius.block` = 8, `DS.Colour.card` | 🔧 was .07 / radius 10 |
| 请求头 row | padding / gap | `8px 10px`, `10px` | same | ✅ |
| 请求头 row | key width | `110px` | `secretKeyWidth` = 110 for http | ✅ **fixed** — was 150 in both sheets |
| 请求头 row | key / value fonts | `12px` mono; value `rgba(28,28,30,.4)` | `DS.Text.mono(12)`; `DS.Colour.ink(0.4)` | 🔧 colour was `.tertiary` |
| 请求头 row | 「更改」 | `11.5px / 500`, `#0D73FA` | `McpLinkButton` → `DS.Text.size(11.5, .medium)`, accent | 🔧 was 12pt |
| 请求头 row | delete | **not drawn** | `xmark`, 14, `.tertiary` | ⚠️ deviation — without it a header can be added and never removed; the mockup's single row simply has nothing to delete |
| 失败块 | border | `.75px rgba(217,72,59,.35)` | `DS.Colour.error.opacity(0.35)`, `0.75` | ✅ |
| 失败块 | radius / background | `10px`, `#fff` | `DS.Radius.inset` = 10, `DS.Colour.card` | ✅ |
| 失败块 header | padding / gap / separator | `10px 12px`, `8px`, `border-bottom .75px rgba(0,0,0,.06)` | `12 / 10`, `spacing: 8`, `dsHairline(.bottom)` | ✅ |
| 失败块 header | icon | `error` → `exclamationmark.triangle.fill` | `exclamationmark.triangle.fill` | ✅ **fixed** — was the hollow `warning` glyph |
| 失败块 header | icon size / colour | `15px`, `#D9483B` | `McpIcon.inlineGlyph` = 15, `DS.Colour.error` | ✅ |
| 失败块 header | title | `12.5px / 600`, `#D9483B`, 「连接失败」 | `DS.Text.size(12.5, .semibold)`, `DS.Colour.error` | 🔧 was 13 |
| 失败块 header | elapsed | `11px` mono, `rgba(28,28,30,.4)`, 「60.0s」 | `DS.Text.mono()`, `DS.Colour.ink(0.4)`, `%.1fs` | 🔧 colour was `.tertiary` |
| 失败块 body | padding | `10px 12px` | `12 / 10` | ✅ |
| 失败块 body | font / colour / line-height | `11px` mono, `lh 1.6`, `rgba(28,28,30,.6)` | `DS.Text.mono()`, `DS.Colour.ink(0.6)`, `.lineSpacing(4)` | 🔧 colour was `.secondary`, line height was the default |
| 失败块 body | content | the server's raw error, verbatim | `outcome.message` verbatim, `.textSelection(.enabled)` | ✅ |
| 橙色警示块 | background | `rgba(232,151,58,.08)` | `DS.Colour.warningFill.opacity(0.6)` = warning @ .084 | ✅ |
| 橙色警示块 | border / radius | `.75px rgba(232,151,58,.3)`, `10px` | `DS.Colour.warning.opacity(0.3)`, `DS.Radius.inset` = 10 | ✅ |
| 橙色警示块 | padding / gap / alignment | `11px 13px`, `9px`, `flex-start` | `.horizontal 13`, `.vertical 11`, `HStack(alignment: .top, spacing: 9)` | ✅ |
| 橙色警示块 | icon | `warning` → `exclamationmark.triangle`, `15px`, `#B26A16` | same, 15, `DS.Colour.warningText` | ✅ |
| 橙色警示块 | text | `11.5px`, `lh 1.6`, `rgba(28,28,30,.6)` | `DS.Text.size(11.5)`, `DS.Colour.ink(0.6)`, `.lineSpacing(4)` | 🔧 was 12pt `.secondary` with no line height |
| 橙色警示块 | copy | 「连不上的服务器会拖慢语音服务启动。仍要保存的话，它会以**停用**状态存下，不参与下次连接。」 | same sentence, 停用 semibold | 🔧 was unbolded; it is the word that says what the button under this block does |
| Footer | leading | empty `flex: 1` | 「删除」 link (edit) / hint (create) | ⚠️ see 7B |
| 取消 / 重新测试 | all | as 7B | same `McpButton` | ✅ |
| 停用并保存 | height / padding / radius | `26px`, `0 12px`, `7px` | 26, 12, `DS.Radius.smallControl` = 7 | 🔧 radius was 6 |
| 停用并保存 | background | `#fff` | `DS.Colour.card` | ✅ |
| 停用并保存 | border | `.75px rgba(217,72,59,.4)` | `DS.Colour.error.opacity(0.4)`, `0.75` | ✅ |
| 停用并保存 | shadow | `0 1px 1.5px rgba(0,0,0,.05)` | `DS.Shadow.control` | ✅ |
| 停用并保存 | font / colour | `12px`, weight 400, `#D9483B` | `caption()`, `.regular`, `DS.Colour.error` | ✅ |
| 停用并保存 | when shown | replaces 保存 on a failed test | `showsDisabledSave` = failing test for the current signature | ✅ |
| 停用并保存 | what it sends | 停用 | `save(enabled: false)` → `McpServerRequest.enabled == false` | ✅ |

---

## 7D · 只有环境变量 (460pt)

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Card | width | `460px` | fills the column | ⚠️ the mockup draws 7D standalone; in place it is the server-list card in the right column |
| Card | background / border / radius / shadow / clipping | `#fff`, `.75px rgba(0,0,0,.07)`, `14px`, `0 1px 2px rgba(0,0,0,.04)`, hidden | `dsCard()` + `.clipShape(14)` | ✅ |
| 说明块 | padding | `12px 16px` | `.horizontal DS.Space.content` (16), `.vertical 12` | ✅ |
| 说明块 | background | `#FAFAF8` | `DS.Colour.insetSurface` = `#FAFAF8` | 🔧 was `inset` = black @ .035 |
| 说明块 | separator | `border-bottom .75px rgba(0,0,0,.06)` | `dsHairline(.bottom)` | ✅ |
| 说明块 | gap | `5px` | `VStack(spacing: 5)` | ✅ |
| 说明块 title | font / copy | `12.5px / 600`, 「当前来自环境变量，只读」 | `DS.Text.size(12.5, .semibold)`, identical | 🔧 was 13 |
| 说明块 body | font / colour / line-height | `11.5px`, `lh 1.6`, `rgba(28,28,30,.55)` | `DS.Text.size(11.5)`, `DS.Colour.ink(0.55)`, `.lineSpacing(4)` | 🔧 was 12pt `.secondary` with no line height |
| 说明块 body | code chip | `11px` mono, `rgba(0,0,0,.05)`, `1.5px 5px`, radius `4px` | mono run + `DS.Colour.control` (black @ .05) + thin spaces | 🔧 fill was `inset` = .035 · ⚠️ still no radius/padding — see 7A |
| 说明块 body | copy | 「这 2 个服务器由 `OPENTYPE_MCP_SERVERS` 提供，不能在这里改。一旦你在这里保存第一个服务器，环境变量会被**整份忽略** —— 不是合并。」 | same, count live, 整份忽略 semibold | 🔧 as 7C |
| Server row | padding / gap | `12px 16px`, `11px` | `16 / 12`, `HStack(spacing: 11)` | ✅ |
| Server row | opacity | `.62` | `.opacity(0.62)` | ✅ |
| Server row | separator | `border-top .75px rgba(0,0,0,.06)` from row 2 | hairline when `!isFirst` | ✅ |
| Server row | inner gap | `4px` | `VStack(spacing: 4)` | ✅ |
| Server name | font | `13px` mono, `600` | `DS.Text.mono(13, weight: .semibold)` | ✅ |
| Transport tag | font / padding / radius | `10.5px / 600`, `2px 6px`, `5px` | `DS.Text.size(10.5, .semibold)`, `6 / 2`, `DS.Radius.tag` = 5 | 🔧 was 11pt / radius 6 |
| Transport tag `stdio` | background / colour | `rgba(0,0,0,.05)` / `rgba(28,28,30,.5)` | `DS.Colour.control` / `DS.Colour.ink(0.5)` | 🔧 as 7A |
| Command line | font / colour / truncation | `11px` mono, `rgba(28,28,30,.45)`, ellipsis | `DS.Text.mono()`, `DS.Colour.ink(0.45)`, `.lineLimit(1)` | 🔧 colour was `.secondary` |
| Lock | icon | `lock` → `lock.fill` | `lock.fill` | ✅ |
| Lock | size / colour | `15px`, `rgba(28,28,30,.28)` | `McpIcon.inlineGlyph` = 15, `DS.Colour.ink(0.28)` | 🔧 colour was `.tertiary` |
| Row | interactivity | none (read-only) | no button, no chevron | ✅ |
| Footer | padding / separator / gap | `12px 16px`, `border-top .75px rgba(0,0,0,.06)`, `9px` | `16 / 12`, `dsHairline(.top)`, `HStack(spacing: 9)` | ✅ |
| 复制成我的配置 | style | chrome button, `26px`, `0 12px`, radius `7px`, `.75px rgba(0,0,0,.12)`, `12px` | `McpButton(.chrome)` — radius `smallControl` = 7, border `buttonBorder` = .12 | 🔧 was radius 6 / border .07 |
| 复制成我的配置 | behaviour | 「把 env 里的 servers 逐个 POST 成 saved」 | one `POST /config/mcp` per server; secret **values** deliberately omitted and the user is told which servers need one re-entered | ⚠️ addition — only masks ever reached this Mac, and a mask sent on a *create* has no stored record to resolve against, so it would persist as the literal credential |
| 添加服务器 | style | primary, `#0D73FA`, `#fff`, `12px / 500`, shadow `0 1px 2px rgba(13,115,250,.3)` | `McpButton(.primary)` | ✅ |
| Footer | alignment | left, gap 9 | `HStack` + trailing `Spacer()` | ✅ |
| Group header | 「添加服务器」 link | not drawn in 7D | suppressed while environment-only | ✅ |

---

## Behaviour verified after the restyle

Re-read at the current file state, not assumed:

1. **A saved secret is a mask plus 「更改」, never a field.** `McpSecretRowView`'s
   `.saved` case renders `Text(entry.key)` and `Text(mask)` — both static — beside
   an `McpLinkButton`. 「更改」 sets `.entered("")`, an **empty** `SecureField`,
   never one seeded from the mask. `McpServerSummary` has no `env`/`headers`
   property to decode into, so a real token cannot reach Swift in the first
   place. Unchanged by this review.
2. **Every key is resent, including untouched ones.** `McpServerDraft.request`
   loops `activeSecrets` and writes each `submittedKey`/`submittedValue` into one
   map; a `.saved` entry contributes its mask verbatim, which is how "unchanged"
   is expressed on the wire. Nothing filters by "edited". The write is a replace,
   so a dropped key is a deleted secret. Unchanged.
3. **停用并保存 sends `enabled: false`.** The `.danger` button calls
   `save(enabled: false)` → `draft.request(enabled: false)` →
   `McpServerRequest.enabled == false`. The 保存 path passes `true`; the probe
   passes `nil` so the key is omitted. Unchanged.
4. **名称 is validated against `[A-Za-z0-9_-]+` while typing.** `nameViolation`
   runs the regex on every keystroke; the helper line under the field swaps to
   the rule in `DS.Colour.warningText`, and `fieldBlocker` disables both 测试 and
   保存. Unchanged.

`swift build` clean; `swift test` 524/524.

---

## Token gaps (reported, not hard-coded)

These are values §07 needs that `DesignTokens.swift` has no name for. All were
left at the nearest token rather than written as literals.

| Need | §07 value | Nearest token | Where it shows |
|---|---|---|---|
| Deep accent for a tinted tag's text | `#0A5CC8` | `DS.Colour.accent` `#0D73FA` | the `http` transport tag, 7A + 7D |
| Sheet canvas | `#F7F7F5` | `DS.Colour.canvas` `#F5F5F3` | 7B/7C sheet background |
| Sheet footer bar | `#F1F1EF` | `DS.Colour.inset` ≈ `#EDEDEB` | 7B/7C footer |
| A stronger lift for a selected segment | `0 1px 2px rgba(0,0,0,.1)` | `DS.Shadow.control` `0 1px 0.75 rgba(0,0,0,.05)` | 连接方式 |
| Field-weight border | `rgba(0,0,0,.14)` | `DS.Colour.border` `.07` | every 28pt input |
| Inline code chip | `1.5px 5px` padding, radius `4px` | none — `Text` runs have no box model | `OPENTYPE_MCP_SERVERS`, `github__create_issue` |

The first four are candidates for real tokens if other screens want them; the
fifth is a deliberate README-level decision ("全局唯一边框值") that §07's markup
predates; the sixth is a SwiftUI limit, not a token gap.

## Out of scope — needs a change elsewhere

1. **`AgentToolsPage` has no call site.** `SettingsViews2.swift:536` still
   renders a placeholder for `.agentTools` ("内置工具与 MCP 服务器配置即将在这里").
   The whole of §07 is therefore unreachable in the running app. Wiring it needs
   a decision that page cannot make for itself: `SettingsDetailColumn` already
   draws a `ColumnHeader` with a back chevron and the route title, so either
   `AgentToolsPage` replaces the column body outright (its own 52pt header is
   the 7A one, including 重启服务并连接) or its header is dropped and the restart
   button moves into the shared `ColumnHeader`. Note also that
   `SettingsDetailColumn` paints `DS.Colour.card`, while 7A is a canvas page of
   white cards — `AgentToolsPage` sets `DS.Colour.canvas` itself and would
   override it.
2. **「6 个工具 · 上次启动已连接」 and 「查看被忽略的 2 个」 need sidecar data that
   does not exist.** `GET /config/mcp` (`sidecar/src/agent/mcpConfigRoutes.ts`)
   returns `{configured, source, servers}` — stored configuration only. Nothing
   reports which servers the running sidecar actually connected to, how many
   tools each contributed, or — when `source == "saved"` — what the ignored
   `OPENTYPE_MCP_SERVERS` entry contains. Both are single-field additions on the
   sidecar side (a per-server `lastConnect: {connected, toolCount}` from
   `connectConfiguredMcpServers`, and an `ignoredEnvServers` array), after which
   the row copy and the env-card link become one-line Swift changes.
