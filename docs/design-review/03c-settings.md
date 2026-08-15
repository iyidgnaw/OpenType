# 03C · 设置 — pixel audit

Source of truth: `design_handoff_opentype_redesign_v1/OpenType 重设计（单文件·离线）.html`,
section **3C**, read as literal CSS (not via the README's prose, which rounds),
cross-checked against that folder's `README.md` §「设计语言」 and §5「设置（设计稿 03C）」.

Implementation: `Sources/OpenType/SettingsViews2.swift`. Tokens: `Sources/OpenType/DesignTokens.swift`.

The app is pinned to the light appearance (`OpenTypeApp`), so every design colour
is compared literally rather than as a semantic that could resolve differently.

**Status key** — ✅ matches · 🔧 was wrong, fixed in this pass · ⚠️ deliberate
deviation, reason given. (The first pass also used 🧩 for "blocked on a token the
scale does not have"; nothing on this screen is any more — see §11.)

## Global conventions applied throughout

Three mappings are prescribed by the handoff itself and are applied everywhere
below rather than restated per row:

1. **Material → SF Symbols.** The README says outright that the HTML's Material
   Symbols are 替身 and must be swapped (「实现时必须换回 SF Symbols」), and gives
   a name table but no size table. Material `font-size: N` sizes the *em box*;
   SF Symbols size the cap height, and a chevron fills roughly two thirds of a
   Material box. So `chevron_right` 16px → `chevron.right` 13pt, and
   `unfold_more` 14px → `chevron.up.chevron.down` 10pt (two stacked chevrons
   fill their box more completely than one, so it maps lower, not higher).
2. **11.5px is 11.5pt.** The mockup sets subtitles, notes and permission status
   at 11.5px. The README's type scale collapses that step away (「现状有 8.3 /
   8.5 / … / 11.5 / 12 / 12.5 / 13 十二档字号，这次全部收进上面六档」) and the
   first pass followed the README, so every 11.5 became `DS.Text.caption()` = 12.
   The owner has since ruled **稿子优先 —— 无条件还原设计稿**, so the markup wins
   and they are back at 11.5 through `DS.Text.size(11.5)`. Marked 🔧 per row.
3. **Text colour is a literal alpha, not a semantic.** The README maps 文字主
   `#1C1C1E` → `.primary`, 次 `rgba(28,28,30,.55)` → `.secondary`, 三级
   `rgba(28,28,30,.35–.42)` → `.tertiary`. But 03C draws `.3`, `.35`, `.4`,
   `.42`, `.45`, `.5` and `.55` — seven values that do not fit three buckets —
   and `.tertiary` resolves to ≈ .26 on macOS light, lighter than any of them.
   Every one now goes through `DS.Colour.ink(_:)` at the alpha the markup states.
   `.primary` is the exception and stays: the colour table names it for 文字主
   rather than giving a value to round into it.

---

## 1 · Page frame

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Window body | background | `#F5F5F3` | `DS.Colour.canvas` = `rgb(0.961, 0.961, 0.953)` = `#F5F5F3` | ✅ |
| Page header | height | `52px` | `DS.Size.headerHeight` = 52 (`ColumnHeader`) | ✅ |
| Page header | padding | `0 24px` | `DS.Space.pageWide` = 24 horizontal, wide layout | ✅ |
| Page header | vertical align | `align-items:center` | `.frame(height:)` + default centering | ✅ |
| Page header | bottom border | none | none on the list column (only the pushed detail column takes `.dsHairline(.bottom)`) | ✅ |
| Header title 「设置」 | font size | `20px` | `DS.Text.title()` = 20 | ✅ |
| Header title | weight | `700` | `.bold` | ✅ |
| Header title | letter-spacing | `-.02em` = −0.4pt @20 | `DS.Tracking.title` = −0.4 | ✅ |
| Header title | colour | inherited `#1C1C1E` | `.primary` | ✅ |
| Body | padding | `0 24px 24px` | `.padding(.horizontal, 24)` + `.padding(.bottom, 24)`, no top | ✅ |
| Body | column gap | `16px` | `HStack(spacing: DS.Space.group)` = 16 | ✅ |
| Column | width | `flex:1; min-width:0` (equal) | `.frame(maxWidth: .infinity)` on both | ✅ |
| Column | group gap | `16px` | `VStack(spacing: DS.Space.group)` = 16 | ✅ |
| Left column | contents | 快捷键 · 听写输出 | same order | ✅ |
| Right column | contents | 引擎 · 权限 · 数据 | same order | ✅ |
| Narrow fallback | — | not in mockup | single column, page padding drops to `DS.Space.pageNarrow` = 14 below 620pt | ⚠️ addition — the mockup is one fixed 908pt frame; the app is resizable and this column is also used as the 334pt list beside a pushed sub-page. Row metrics are unchanged, only page padding moves, which is what the handoff specifies for every other screen. |

## 2 · Group (all five)

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Group | label→card gap | `gap:8px` | `VStack(spacing: DS.Space.label)` = 8 | ✅ |
| Group label | font size | `11px` | `DS.Text.groupLabel()` = 11 | ✅ |
| Group label | weight | `600` | `.semibold` | ✅ |
| Group label | letter-spacing | `.05em` = 0.55pt @11 | `DS.Tracking.groupLabel` = 0.55 | ✅ |
| Group label | colour | `rgba(28,28,30,.42)` | was `.tertiary` (≈ .26) | 🔧 → `DS.Colour.ink(0.42)` |
| Group label | padding | `0 4px` | `.padding(.horizontal, 4)` | ✅ |
| Card | background | `#fff` | `DS.Colour.card` = `Color.white` | ✅ |
| Card | border | `.75px solid rgba(0,0,0,.07)` | `DS.Colour.border` = `primary.opacity(0.07)`, `lineWidth: 0.75` | ✅ |
| Card | radius | `14px` | `DS.Radius.card` = 14, `.continuous` | ✅ |
| Card | shadow | `0 1px 2px rgba(0,0,0,.04)` | `DS.Shadow.card` = `opacity .04, radius 1, y 1` (CSS 2px blur ≈ SwiftUI radius 1) | ✅ |
| Card | `overflow:hidden` | clips row fills to the radius | **was missing** → added `.clipShape(RoundedRectangle(14, .continuous))` on the row stack | 🔧 the ungranted-permission row is tinted full-bleed *and* is the last row of its card, so without the clip its square corners poked out past the card radius |

## 3 · Row primitives

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Standard row | padding | `12px 14px` | `.padding(.horizontal, 14)`, `.padding(.vertical, 12)` | ✅ |
| Standard row | leading↔trailing gap | `gap:12px` | `HStack(spacing: 12)` | ✅ |
| Standard row | vertical align | `align-items:center` | `HStack` default | ✅ |
| Permission row | padding | `11px 14px` | **was 12** → `compact` flag on `SettingsRow`, vertical 11 | 🔧 |
| Row title | font size / weight | `13px` regular | `DS.Text.body()` = 13 `.regular` | ✅ |
| Row title | colour | inherited `#1C1C1E` | `.primary` | ✅ |
| Row subtitle | font size | `11.5px` | was `DS.Text.caption()` = 12 | 🔧 → `DS.Text.size(11.5)` |
| Row subtitle | colour | `rgba(28,28,30,.45)` | was `.secondary` (≈ .50) | 🔧 → `DS.Colour.ink(0.45)` |
| Row subtitle | top gap | `margin-top:2px` | `VStack(spacing: 2)` | ✅ |
| Row mono line | font | `11px ui-monospace` | `DS.Text.mono()` = 11pt monospaced | ✅ |
| Row mono line | colour | `rgba(28,28,30,.45)` | was `.secondary` (≈ .50) | 🔧 → `DS.Colour.ink(0.45)` |
| Row mono line | top gap | `margin-top:3px` | **was 2** → `VStack(spacing: mono == nil ? 2 : 3)` | 🔧 |
| Hairline | colour / weight | `.75px solid rgba(0,0,0,.06)` | `DS.Colour.hairline` = `primary.opacity(0.06)`, height 0.75 | ✅ |
| Hairline | inset | none — full row width | `dsHairline(.top)`, full bleed | ✅ |
| Hairline | first row | absent | `divided: false` on every group's first row | ✅ |
| Stacked row (松开之后) | padding | `12px 14px` | 14 / 12 | ✅ |
| Stacked row | internal gap | `gap:9px` | `VStack(spacing: 9)` | ✅ |
| Stacked row | note font | `11.5px`, `line-height:1.55` | was `DS.Text.caption()` = 12 with default leading | 🔧 → `DS.Text.size(11.5)` + `lineSpacing(11.5 × 0.55)` = 6.325. The line-height was the part that had been dropped rather than rounded — SwiftUI's default is not 1.55. |
| Stacked row | note colour | `rgba(28,28,30,.5)` | was `.secondary` (≈ .50) | 🔧 → `DS.Colour.ink(0.5)` |
| Trailing cluster | gap | `gap:8px` | `HStack(spacing: 8)` | ✅ |

## 4 · 快捷键

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| 启动方式 | title | `13px` 「启动方式」 | same | ✅ |
| 启动方式 | subtitle | `11.5px` 「按住说话,松开结束;双击进入连续录音」 | `configuration.hotKeyPreset.note` — the live note for the *selected* preset | ⚠️ the mockup shows one preset's copy; the row is a picker, so the note tracks the selection |
| 启动方式 | control | dropdown chip, mono label `按住 ⌥` | `Menu` + `ControlChip(mono: true)` | ✅ |
| 录音中切换模式 | title | `13px`, no subtitle | same | ✅ |
| 录音中切换模式 | trailing | `12px ui-monospace`, `rgba(28,28,30,.5)`, read-only | `Text("Tab")`, `DS.Text.mono(12)`; colour was `.secondary` | 🔧 → `DS.Colour.ink(0.5)` |
| Shortcut-health row | — | not in mockup | conditional tinted row + 授权 button, shown only when `!(shortcutReady && preferredShortcutActive)` | ⚠️ addition. Absent in the healthy state, so the mockup's card is reproduced exactly; it exists because a hotkey that silently isn't bound is otherwise invisible. Uses the same `tinted` + `SmallButton` treatment the permissions group uses for the same situation. |

## 5 · 听写输出

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| 松开之后 | shape | stacked (control under title) | `SettingsStackedRow` | ✅ |
| 松开之后 | segment labels | 原样写入 / 轻整理 / 先复核 | `TranscribeVariant.releaseTitle`, `allCases` order `.direct/.tidy/.review` | ✅ |
| 松开之后 | note | 「三档都不经过 AI 模型 —— 轻整理只按固定规则去口癖和标点。」 | verbatim | ✅ |
| 自动写入当前输入框 | title / subtitle | `13px` / `11.5px`「结果始终会复制到剪贴板」 | verbatim | ✅ |
| 自动写入当前输入框 | control | toggle, on | `SettingsSwitch($configuration.automaticallyInsert)` | ✅ |
| 写入后恢复原剪贴板 | title | `13px`, no subtitle | same | ✅ |
| 写入后恢复原剪贴板 | control | toggle, off | `SettingsSwitch($configuration.retainClipboardAfterInsert)` | ✅ |
| 写入后恢复原剪贴板 | enabled state | always on in mockup | `.disabled(!automaticallyInsert)` → switch dims to 0.4 | ⚠️ addition; the setting has no effect without auto-insert. Row stays visible (hiding it would move the row above on every toggle). |
| 录音时显示实时字幕 | title / control | `13px`, toggle on | `SettingsSwitch($configuration.liveCaptionsEnabled)` | ✅ |
| 提示音 | title / subtitle | `13px` / `11.5px`「OpenType Air · 一组低响度提示音」 | verbatim | ✅ |
| 提示音 | 试听 button | `h24`, `padding 0 10`, `radius 6`, bg `#F5F5F3`, border `.75px rgba(0,0,0,.09)`, `12px`, no shadow | `ControlChip(showsIndicator: false, horizontalPadding: 10)` — **padding was 8** | 🔧 |
| 提示音 | mute toggle | not in mockup | `SettingsSwitch` bound to `!configuration.isMuted` | ⚠️ addition — `playFeedbackSounds` is a real preference with no other home; dropping it to match the mockup would lose a setting. Placed after 试听 inside the same 8pt trailing cluster. |

## 6 · 引擎

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| 语音识别 | title | `13px` | `SettingsRoute.speechRecognition.title` | ✅ |
| 语音识别 | second line | `11px` mono `rgba(28,28,30,.45)`, `mlx-whisper · large-v3 · 本机` | `whisperSummaryLine` — live: `mlx-whisper · 本机`, or `model · host · 远程` | ✅ (content is live, format matches) |
| 语音识别 | status dot | `5px` circle `#34A853` | `DS.Size.statusDot` = 5; `DS.Colour.ok` = `rgb(0.204,0.659,0.325)` = `#34A853` | ✅ |
| 语音识别 | dot when unconfigured | not in mockup | `DS.Colour.warning` = `#E8973A` | ⚠️ addition; the mockup only draws the healthy state |
| 语音识别 | chevron | `chevron_right` 16px `rgba(28,28,30,.3)` | `chevron.right` 13pt semibold (mapping 1); colour was `.tertiary` (≈ .26) | 🔧 → `DS.Colour.ink(0.3)` |
| 语音识别 | dot↔chevron gap | `gap:8px` | `HStack(spacing: 8)` | ✅ |
| 语音识别 | action | pushes a sub-page | `pushes: .speechRecognition` → `WhisperSetupContent` | ✅ |
| AI 模型 | second line | `deepseek-v4-flash · OpenAI 兼容` | `llmSummaryLine` = `model · type.title`, or 「未配置」 | ✅ |
| AI 模型 | dot / chevron / push | as 语音识别 | same | ✅ |
| Agent 工具 | row | **not in the HTML**; README §5 table lists it in 引擎 (「**Agent 工具 ›**」, bolded as new) | chevron row with subtitle「内置工具与 MCP 服务器」, pushes `.agentTools` | ✅ per README (HTML predates it) |
| 转写语言 | title | `13px`, no subtitle | same | ✅ |
| 转写语言 | control | dropdown chip, `12px` **non-mono** 「自动识别」 | `ControlChip(text:)`, `mono` defaults false | ✅ |

## 7 · 权限

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| Row | padding | `11px 14px` | `compact: true` → vertical 11 | 🔧 |
| Row | leading dot | `5px` circle, `flex:none`, `#34A853` granted | `Circle().frame(5×5)`, `DS.Colour.ok` | ✅ |
| Row | dot↔title gap | `gap:12px` | `HStack(spacing: 12)` | ✅ |
| Row | title | `13px`, `flex:1` | `DS.Text.body()`, `.frame(maxWidth: .infinity, alignment: .leading)` | ✅ |
| Granted status | text | `11.5px` `rgba(28,28,30,.4)` 「已授权」 | was `DS.Text.caption()` (12) + `.tertiary` (≈ .26) | 🔧 → `DS.Text.size(11.5)` + `DS.Colour.ink(0.4)` |
| Granted row | subtitle | none | `nil` when `.granted` | ✅ |
| 麦克风 / 辅助功能 | state shown | granted | live `model.microphonePermission` / `accessibilityGranted` | ✅ |
| 语音识别(实时字幕) | ungranted dot | `5px` `#E8973A` | `DS.Colour.warning` = `rgb(0.910,0.592,0.227)` = `#E8973A` | ✅ |
| 语音识别(实时字幕) | row tint | `rgba(232,151,58,.05)` full-bleed | `DS.Colour.warning.opacity(0.05)`, now clipped to the card radius | ✅ (§2 fix) |
| 语音识别(实时字幕) | subtitle | `11.5px` `rgba(28,28,30,.45)`「未授权时字幕不显示,不影响最终识别」 | verbatim | ✅ |
| 授权 button | height | `24px` | `.frame(height: 24)` | ✅ |
| 授权 button | padding | `0 10px` | `.padding(.horizontal, 10)` | ✅ |
| 授权 button | radius | `6px` | `DS.Radius.control` = 6 | ✅ |
| 授权 button | background | `#fff` | `DS.Colour.card` | ✅ |
| 授权 button | border | `.75px rgba(0,0,0,.12)` | was the bare literal `Color.primary.opacity(0.12)` — `.primary` is `labelColor`, so it rendered at .102 | 🔧 → `DS.Colour.buttonBorder`, `lineWidth: 0.75` |
| 授权 button | shadow | `0 1px 1.5px rgba(0,0,0,.05)` | `DS.Shadow.control` = `opacity .05, radius 0.75, y 1` | ✅ |
| 授权 button | label | `12px`, weight `500` | `DS.Text.caption()` + `.fontWeight(.medium)` | ✅ |
| 授权 button | denied vs. undetermined | one 「授权」 in mockup | 「打开设置」 when `.denied` (macOS gives no re-prompt), 「授权」 when undetermined | ⚠️ addition; identical styling |

## 8 · 数据

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| 本地长期记忆 | title / subtitle | `13px` / `11.5px`「听写内容不参与整理,也不发给模型」 | verbatim | ✅ |
| 本地长期记忆 | control | toggle, on | `SettingsSwitch($configuration.agentMemoryEnabled)` | ✅ |
| 每 100 条更新已学到的偏好 | row | not in mockup | toggle + live progress subtitle, `.disabled(!agentMemoryEnabled)` | ⚠️ addition — `automaticOwnerProfileUpdates` is a real preference with no other home |
| 保留本地输入历史 | row | not in mockup | toggle 「关闭后不再写入听写记录；审计记录不受影响」 | ⚠️ addition — `keepHistory` is a real preference with no other home |
| 审计记录 | title | `13px` | `SettingsRoute.auditLog.title` | ✅ |
| 审计记录 | second line | `11px` mono `audit-events.v1.jsonl · 1,842 条` | `auditSummaryLine`, live line count, `.formatted()` grouping | ✅ |
| 审计记录 | trailing | `chevron_right` only, no dot | chevron only | ✅ |
| 清除本地数据… | title | `13px`, `#D9483B` | `destructive: true` → `DS.Colour.error` = `rgb(0.851,0.282,0.231)` = `#D9483B` | ✅ |
| 清除本地数据… | trailing | `chevron_right` 16px `rgba(28,28,30,.3)` | `chevron.right` 13pt (mapping 1); colour was `.tertiary` | 🔧 → `DS.Colour.ink(0.3)`; one `SettingsRow` draws both chevrons, so they move together |
| 清除本地数据… | subtitle / dot | none | none | ✅ |
| 清除本地数据… | action | pushes a page (no `DisclosureGroup`) | `pushes: .clearLocalData` | ✅ |

## 9 · Controls

### Toggle (`SettingsSwitch`) — 5 instances on screen

| Property | Design | Implemented | Status |
|---|---|---|---|
| Size | `38×22` | `.frame(width: 38, height: 22)` | ✅ |
| Track radius | `99px` | `Capsule()` | ✅ |
| Track on | `#0D73FA` | `DS.Colour.accent` = `AppAccent.primary` = `#0D73FA` | ✅ |
| Track off | `rgba(0,0,0,.14)` | was the bare literal `Color.primary.opacity(0.14)`, i.e. .119 | 🔧 → `DS.Colour.fieldBorder` |
| Track padding | `2px` | `.padding(2)` on the knob | ✅ |
| Knob | `18×18` circle `#fff` | `Circle().frame(18×18).fill(.white)` | ✅ |
| Knob shadow | `0 1px 2px rgba(0,0,0,.25)` | was that value as a bare literal | 🔧 → `DS.Shadow.knob`; same value, now named |
| Knob alignment | flex-end on / flex-start off | `.overlay(alignment: isOn ? .trailing : .leading)` | ✅ |

### Dropdown chip (`ControlChip`) — 启动方式, 转写语言, 试听

| Property | Design | Implemented | Status |
|---|---|---|---|
| Height | `24px` | `.frame(height: 24)` | ✅ |
| Radius | `6px` | `DS.Radius.control` = 6 | ✅ |
| Background | `#F5F5F3` | `DS.Colour.canvas` | ✅ |
| Border | `.75px rgba(0,0,0,.09)` | was the bare literal `Color.primary.opacity(0.09)`, i.e. .077 | 🔧 → `DS.Colour.controlBorder`, `lineWidth: 0.75` |
| Shadow | none | none | ✅ |
| Padding (with chevron) | `0 8px` | 8 | ✅ |
| Padding (bare label) | `0 10px` | **was 8** → `horizontalPadding: 10` | 🔧 |
| Label↔chevron gap | `gap:6px` | `HStack(spacing: 6)` | ✅ |
| Label font | `12px`, mono for `按住 ⌥`, non-mono for 自动识别/试听 | `DS.Text.mono(12)` / `DS.Text.caption()` | ✅ |
| Chevron | `unfold_more` 14px `rgba(28,28,30,.35)` | `chevron.up.chevron.down` 10pt semibold (mapping 1); colour was `.tertiary` | 🔧 → `DS.Colour.ink(0.35)` |

### Segmented control (`SegmentedControl`) — 松开之后

| Property | Design | Implemented | Status |
|---|---|---|---|
| Height | `26px` (README: 26–28) | `.frame(height: 26)` | ✅ |
| Radius | `7px` | was the bare literal `7` | 🔧 → `DS.Radius.iconButton` = 7; same value, now named |
| Track colour | `#F0F0EE` | was `Color.primary.opacity(0.06)` = `#F0F0F0` over white — achromatic, so no alpha of it can be warm | 🔧 → `DS.Colour.controlTrack` = `#F0F0EE`. Not `segmentTrack` (`#EDEDEA`), which is the darker track the handoff draws on a *sheet*; 03C's sits on a white card. |
| Track padding | `2px` | `.padding(2)` | ✅ |
| Segment gap | `gap:2px` | `HStack(spacing: 2)` | ✅ |
| Segment width | `flex:1` (equal) | `.frame(maxWidth: .infinity)` per segment | ✅ |
| Selected fill | `#fff`, radius `5px` | `DS.Colour.card`; the radius was the bare literal `5` | 🔧 → `DS.Radius.tag` = 5; same value, now named |
| Selected shadow | the markup draws `0 1px 2px rgba(0,0,0,.1)`, and README §5 agrees; only §设计语言's table says `0 1px 1.5px rgba(0,0,0,.05)` | was `DS.Shadow.control` = the §设计语言 value | 🔧 → `DS.Shadow.lifted`. The first pass read the design-language table as the normative one; 稿子优先 settles the README's self-contradiction in the markup's favour instead. |
| Selected label | `12px` weight `500`, inherited colour | `DS.Text.caption()` + `.medium` + `.primary` | ✅ |
| Unselected label | `12px` regular `rgba(28,28,30,.55)` | `DS.Text.caption()` + `.regular`; colour was `.secondary` (≈ .50) | 🔧 → `DS.Colour.ink(0.55)` |

### Small button (`SmallButton`) — 授权 and the sub-pages' actions

Specced in §7. Matches on all nine properties; the `.12` border is now
`DS.Colour.ink(0.12)` rather than a bare literal.

### Chevron row

Any `SettingsRow` with `pushes:` — chevron 13pt semibold `DS.Colour.ink(0.3)`,
no separate hit target, whole row is the `Button` (`buttonStyle(.plain)`,
`contentShape(Rectangle())`). The mockup has no hover or pressed state to match.

### Status dot

`5×5` circle, `DS.Size.statusDot`. `#34A853` healthy, `#E8973A` warning. Leading
position on permission rows, trailing (before the chevron, 8pt gap) on provider
rows — exactly as the mockup places them.

---

## 10 · Setting-inventory check

The restyle touched layout only. Mechanically diffed against `HEAD` — every
binding, action and route is byte-identical:

```
git show HEAD:Sources/OpenType/SettingsViews2.swift | grep -oE 'configuration\.[a-zA-Z]+|model\.change[A-Za-z]+|…' | sort | uniq -c
→ IDENTICAL
```

All 10 user-facing preferences in `AppConfiguration` are on screen:

| Preference | Row |
|---|---|
| `hotKeyPreset` | 快捷键 › 启动方式 |
| `transcribeVariant` | 听写输出 › 松开之后 (原样写入/轻整理/先复核) |
| `automaticallyInsert` | 听写输出 › 自动写入当前输入框 |
| `retainClipboardAfterInsert` | 听写输出 › 写入后恢复原剪贴板 |
| `liveCaptionsEnabled` | 听写输出 › 录音时显示实时字幕 |
| `playFeedbackSounds` (via `isMuted`) | 听写输出 › 提示音 |
| `transcriptionLanguage` | 引擎 › 转写语言 |
| `agentMemoryEnabled` | 数据 › 本地长期记忆 |
| `automaticOwnerProfileUpdates` | 数据 › 每 100 条更新已学到的偏好 |
| `keepHistory` | 数据 › 保留本地输入历史 |

The remaining two `AppConfiguration` properties are deliberately not settings
rows: `selectedMode` (the mode switcher lives in the menubar popover and the
recording hotkey) and `localTranscriptionOnlyAcknowledged` (a one-time
onboarding acknowledgement, never user-editable).

Five sub-page routes all still reachable: `.speechRecognition`, `.languageModel`,
`.agentTools`, `.auditLog`, `.clearLocalData`.

## 11 · Token status

`DesignTokens.swift` is still not edited from here, but it grew the literal steps
03C needs in the same batch, so the four gaps the first pass recorded are down to
two — and `SettingsViews2.swift` now contains no bare colour or radius literal at
all.

All four are closed, and nothing on 03C is still blocked on a token:

1. **Recessed control track — `#F0F0EE`** → `DS.Colour.controlTrack`. The scale
   carries two segmented tracks, because the handoff draws two: `controlTrack`
   for 设置's, which sits on a white card, and the darker `segmentTrack`
   (`#EDEDEA`) for the one on a sheet.
2. **Control border — `rgba(0,0,0,.09)`** (dropdown chips) → `DS.Colour.controlBorder`.
3. **Lifted-button border — `rgba(0,0,0,.12)`** (授权 / 试听-class) →
   `DS.Colour.buttonBorder`.
4. **Segmented selected-chip shadow — `0 1px 2px rgba(0,0,0,.10)`** →
   `DS.Shadow.lifted`.

Three more that the first pass had not flagged, because their *values* were
right and only their expression was a literal, are now named too: the toggle's
off track (`DS.Colour.fieldBorder`), its knob shadow (`DS.Shadow.knob`), and the
two control radii `5` / `7` (`DS.Radius.tag` / `DS.Radius.iconButton`).

The borders and fills above are literal black; the ink values are literal
`#1C1C1E`. The handoff uses both bases and they are not interchangeable —
`Color.primary` is `labelColor`, black at 0.85, so the old
`Color.primary.opacity(0.12)` was rendering at .102.

Two literals remain by necessity, not by gap: the icon point sizes (13 / 10),
which exist only because the handoff ships no Material→SF size table, and the
control heights (24 / 26), which are per-control specs the scale does not name.

## 12 · Out-of-scope changes needed

None. `ColumnHeader` (`SidebarShell.swift`) already matches 03C's header
exactly — 52pt tall, 24pt page padding, no bottom border — and `dsCard()`
(`DesignTokens.swift`) matches the card spec on all four properties. The
`overflow:hidden` clip was added locally in `SettingsGroup` rather than inside
`dsCard()` because other screens' cards may not want their content clipped; if
the other five audits report the same need, folding a `.clipShape` into
`dsCard()` would be the right consolidation.

## 13 · Second pass — 稿子优先

Sixteen values across `SettingsViews2.swift`, every one of them something the
first pass rounded onto the README's closed scale. No row was added, removed,
reordered or rebound; §10's inventory check still holds.

- **Nine ink values off the hierarchical styles** and onto `DS.Colour.ink(_:)` at
  the markup's own alpha — group labels (.42), row subtitles and mono lines
  (.45), the 松开之后 note (.5), 「Tab」 (.5), 已授权 (.4), both chevrons (.3),
  the dropdown indicator (.35) and the unselected segment label (.55). This is
  the visible one: everything set `.tertiary` rendered at ≈ .26, lighter than any
  value on the screen.
- **Four type sizes back to 11.5** — row subtitles, the stacked-row note, 已授权.
  The note also regains its `1.55` line-height, which the first pass dropped
  rather than rounded.
- **Three bare `Color.primary.opacity(_)` literals** — the chip border (.09), the
  lifted-button border (.12) and the toggle's off track (.14) — now
  `DS.Colour.controlBorder` / `buttonBorder` / `fieldBorder`, and on literal
  black, which is what moved them: `.primary` is `labelColor`, so `.12` was
  rendering at .102.
- **Two bare radius literals and one bare shadow** — the segmented track's `7`,
  its selected chip's `5`, and the toggle knob's `0 1px 2px rgba(0,0,0,.25)` —
  now `DS.Radius.iconButton`, `DS.Radius.tag` and `DS.Shadow.knob`.
- **The segmented track** from an achromatic overlay to `DS.Colour.controlTrack`
  = `#F0F0EE`, and its **selected chip's shadow** from `DS.Shadow.control`
  (`.05`) to `DS.Shadow.lifted` (`.1`), which is what the markup draws.

Everything marked ⚠️ above for a reason other than a rounded value is untouched:
the narrow fallback, the shortcut-health row, the live 启动方式 note, the dimmed
写入后恢复原剪贴板, the mute toggle, the two 数据 preferences, the unconfigured
status dot and the 打开设置 / 授权 split all stay exactly as they were.

## 14 · Verification

`swift build` and `swift test` were run in a detached worktree at `HEAD` with
`DesignTokens.swift`, `MemoryViews.swift` and `SettingsViews2.swift` overlaid —
the shared tree has other screens' audits mid-edit and does not compile on its
own.

```
Build complete! (23.90s)
Executed 524 tests, with 0 failures (0 unexpected)
Test run with 13 tests in 4 suites passed
```

(An earlier run in a fresh worktree showed 1 failure —
`testSidecarClientStartsHealthChecksAndStopsRealDevServer` — caused by the
worktree lacking `sidecar/node_modules`; symlinking it in turns that green,
confirming it is environmental.)
