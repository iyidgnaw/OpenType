# 03C · 设置 — pixel audit

Source of truth: `design_handoff_opentype_redesign_v1/OpenType 重设计（单文件·离线）.html`,
section **3C**, read as literal CSS (not via the README's prose, which rounds),
cross-checked against that folder's `README.md` §「设计语言」 and §5「设置（设计稿 03C）」.

Implementation: `Sources/OpenType/SettingsViews2.swift`. Tokens: `Sources/OpenType/DesignTokens.swift`.

The app is pinned to the light appearance (`OpenTypeApp`), so every design colour
is compared literally rather than as a semantic that could resolve differently.

**Status key** — ✅ matches · 🔧 was wrong, fixed in this pass · ⚠️ deliberate
deviation, reason given · 🧩 blocked on a token the scale does not have.

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
2. **11.5px → 12pt.** The mockup sets subtitles, notes and permission status at
   11.5px. The README's type scale is six closed steps and explicitly lists 11.5
   among the twelve sizes being collapsed away (「现状有 8.3 / 8.5 / … / 11.5 /
   12 / 12.5 / 13 十二档字号，这次全部收进上面六档」). `DS.Text.caption()` = 12pt
   is therefore correct and the mockup is the looser document. Marked ⚠️ once
   here, ✅ per row.
3. **Text colour → semantic.** The README maps 文字主 `#1C1C1E` → `.primary`,
   次 `rgba(28,28,30,.55)` → `.secondary`, 三级 `rgba(28,28,30,.35–.42)` →
   `.tertiary`. The mockup's .45 and .5 fall between the two named steps; the
   README's mapping decides them. Any residual is a platform semantic, not a
   chosen value.

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
| Group label | colour | `rgba(28,28,30,.42)` | `.tertiary` | ✅ (mapping 3) |
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
| Row subtitle | font size | `11.5px` | `DS.Text.caption()` = 12 | ⚠️ mapping 2 |
| Row subtitle | colour | `rgba(28,28,30,.45)` | `.secondary` | ✅ (mapping 3) |
| Row subtitle | top gap | `margin-top:2px` | `VStack(spacing: 2)` | ✅ |
| Row mono line | font | `11px ui-monospace` | `DS.Text.mono()` = 11pt monospaced | ✅ |
| Row mono line | colour | `rgba(28,28,30,.45)` | `.secondary` | ✅ (mapping 3) |
| Row mono line | top gap | `margin-top:3px` | **was 2** → `VStack(spacing: mono == nil ? 2 : 3)` | 🔧 |
| Hairline | colour / weight | `.75px solid rgba(0,0,0,.06)` | `DS.Colour.hairline` = `primary.opacity(0.06)`, height 0.75 | ✅ |
| Hairline | inset | none — full row width | `dsHairline(.top)`, full bleed | ✅ |
| Hairline | first row | absent | `divided: false` on every group's first row | ✅ |
| Stacked row (松开之后) | padding | `12px 14px` | 14 / 12 | ✅ |
| Stacked row | internal gap | `gap:9px` | `VStack(spacing: 9)` | ✅ |
| Stacked row | note font | `11.5px`, `line-height:1.55` | `DS.Text.caption()` = 12, default leading | ⚠️ mapping 2; SwiftUI's default line spacing for 12pt sits at the same optical density |
| Stacked row | note colour | `rgba(28,28,30,.5)` | `.secondary` | ✅ (mapping 3) |
| Trailing cluster | gap | `gap:8px` | `HStack(spacing: 8)` | ✅ |

## 4 · 快捷键

| Element | Property | Design | Implemented | Status |
|---|---|---|---|---|
| 启动方式 | title | `13px` 「启动方式」 | same | ✅ |
| 启动方式 | subtitle | `11.5px` 「按住说话,松开结束;双击进入连续录音」 | `configuration.hotKeyPreset.note` — the live note for the *selected* preset | ⚠️ the mockup shows one preset's copy; the row is a picker, so the note tracks the selection |
| 启动方式 | control | dropdown chip, mono label `按住 ⌥` | `Menu` + `ControlChip(mono: true)` | ✅ |
| 录音中切换模式 | title | `13px`, no subtitle | same | ✅ |
| 录音中切换模式 | trailing | `12px ui-monospace`, `rgba(28,28,30,.5)`, read-only | `Text("Tab")`, `DS.Text.mono(12)`, `.secondary` | ✅ |
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
| 语音识别 | chevron | `chevron_right` 16px `rgba(28,28,30,.3)` | `chevron.right` **13pt** (was 12) semibold, `.tertiary` | 🔧 (mapping 1) |
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
| Granted status | text | `11.5px` `rgba(28,28,30,.4)` 「已授权」 | `DS.Text.caption()` + `.tertiary` | ✅ (mappings 2, 3) |
| Granted row | subtitle | none | `nil` when `.granted` | ✅ |
| 麦克风 / 辅助功能 | state shown | granted | live `model.microphonePermission` / `accessibilityGranted` | ✅ |
| 语音识别(实时字幕) | ungranted dot | `5px` `#E8973A` | `DS.Colour.warning` = `rgb(0.910,0.592,0.227)` = `#E8973A` | ✅ |
| 语音识别(实时字幕) | row tint | `rgba(232,151,58,.05)` full-bleed | `DS.Colour.warning.opacity(0.05)`, now clipped to the card radius | ✅ (§2 fix) |
| 语音识别(实时字幕) | subtitle | `11.5px` `rgba(28,28,30,.45)`「未授权时字幕不显示,不影响最终识别」 | verbatim | ✅ |
| 授权 button | height | `24px` | `.frame(height: 24)` | ✅ |
| 授权 button | padding | `0 10px` | `.padding(.horizontal, 10)` | ✅ |
| 授权 button | radius | `6px` | `DS.Radius.control` = 6 | ✅ |
| 授权 button | background | `#fff` | `DS.Colour.card` | ✅ |
| 授权 button | border | `.75px rgba(0,0,0,.12)` | `primary.opacity(0.12)`, `lineWidth: 0.75` | 🧩 value correct, but as a literal — no border token at .12 (see §11) |
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
| 清除本地数据… | trailing | `chevron_right` 16px `rgba(28,28,30,.3)` | `chevron.right` 13pt `.tertiary` | ✅ (mapping 1) |
| 清除本地数据… | subtitle / dot | none | none | ✅ |
| 清除本地数据… | action | pushes a page (no `DisclosureGroup`) | `pushes: .clearLocalData` | ✅ |

## 9 · Controls

### Toggle (`SettingsSwitch`) — 5 instances on screen

| Property | Design | Implemented | Status |
|---|---|---|---|
| Size | `38×22` | `.frame(width: 38, height: 22)` | ✅ |
| Track radius | `99px` | `Capsule()` | ✅ |
| Track on | `#0D73FA` | `DS.Colour.accent` = `AppAccent.primary` = `#0D73FA` | ✅ |
| Track off | `rgba(0,0,0,.14)` | `Color.primary.opacity(0.14)` | ✅ |
| Track padding | `2px` | `.padding(2)` on the knob | ✅ |
| Knob | `18×18` circle `#fff` | `Circle().frame(18×18).fill(.white)` | ✅ |
| Knob shadow | `0 1px 2px rgba(0,0,0,.25)` | `.black.opacity(0.25), radius: 1, y: 1` | ✅ |
| Knob alignment | flex-end on / flex-start off | `.overlay(alignment: isOn ? .trailing : .leading)` | ✅ |

### Dropdown chip (`ControlChip`) — 启动方式, 转写语言, 试听

| Property | Design | Implemented | Status |
|---|---|---|---|
| Height | `24px` | `.frame(height: 24)` | ✅ |
| Radius | `6px` | `DS.Radius.control` = 6 | ✅ |
| Background | `#F5F5F3` | `DS.Colour.canvas` | ✅ |
| Border | `.75px rgba(0,0,0,.09)` | `primary.opacity(0.09)`, `lineWidth: 0.75` | 🧩 value correct, literal — no token at .09 (see §11) |
| Shadow | none | none | ✅ |
| Padding (with chevron) | `0 8px` | 8 | ✅ |
| Padding (bare label) | `0 10px` | **was 8** → `horizontalPadding: 10` | 🔧 |
| Label↔chevron gap | `gap:6px` | `HStack(spacing: 6)` | ✅ |
| Label font | `12px`, mono for `按住 ⌥`, non-mono for 自动识别/试听 | `DS.Text.mono(12)` / `DS.Text.caption()` | ✅ |
| Chevron | `unfold_more` 14px `rgba(28,28,30,.35)` | `chevron.up.chevron.down` 10pt semibold `.tertiary` | ✅ (mapping 1) |

### Segmented control (`SegmentedControl`) — 松开之后

| Property | Design | Implemented | Status |
|---|---|---|---|
| Height | `26px` (README: 26–28) | `.frame(height: 26)` | ✅ |
| Radius | `7px` | 7, `.continuous` | ✅ |
| Track colour | `#F0F0EE` (README: `#F0F0EE`/`#EDEDEA`) | `Color.primary.opacity(0.06)` = `#F0F0F0` over white (**was 0.05** = `#F2F2F2`) | 🔧 closer; last 2/255 on the blue channel is 🧩 (see §11) |
| Track padding | `2px` | `.padding(2)` | ✅ |
| Segment gap | `gap:2px` | `HStack(spacing: 2)` | ✅ |
| Segment width | `flex:1` (equal) | `.frame(maxWidth: .infinity)` per segment | ✅ |
| Selected fill | `#fff`, radius `5px` | `DS.Colour.card`, radius 5 `.continuous` | ✅ |
| Selected shadow | §5 says `0 1px 2px rgba(0,0,0,.10)`; §设计语言 says `0 1px 1.5px rgba(0,0,0,.05)` for 「分段控件的选中片」 | `DS.Shadow.control` = the §设计语言 value | ⚠️ the README contradicts itself; the design-language table is the global normative one and names this exact part, so it wins |
| Selected label | `12px` weight `500`, inherited colour | `DS.Text.caption()` + `.medium` + `.primary` | ✅ |
| Unselected label | `12px` regular `rgba(28,28,30,.55)` | `DS.Text.caption()` + `.regular` + `.secondary` | ✅ |

### Small button (`SmallButton`) — 授权 and the sub-pages' actions

Specced in §7. Matches on all nine properties; the only literal is the `.12` border.

### Chevron row

Any `SettingsRow` with `pushes:` — chevron 13pt semibold `.tertiary`, no separate
hit target, whole row is the `Button` (`buttonStyle(.plain)`, `contentShape(Rectangle())`).
The mockup has no hover or pressed state to match.

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

## 11 · Token gaps (reported, not hardcoded around)

`DesignTokens.swift` is out of scope for this pass. Four values on this screen
have no token and are literals in `SettingsViews2.swift`:

1. **Recessed control track — `#F0F0EE`.** The segmented control's track. Darker
   and warmer than `DS.Colour.inset` (`primary.opacity(0.035)` ≈ `#F7F7F7`),
   which is the token for 「卡内凹陷块」. No achromatic overlay can produce the
   warm channel; `opacity(0.06)` lands on `#F0F0F0`, 2/255 off on blue.
   *Suggested:* `DS.Colour.recessed = Color(red: 0.941, green: 0.941, blue: 0.933)`.
2. **Control border — `rgba(0,0,0,.09)`.** Dropdown chips. `DS.Colour.border` is
   `.07` (cards). *Suggested:* `DS.Colour.controlBorder`.
3. **Lifted-button border — `rgba(0,0,0,.12)`.** The 授权 / 试听-class buttons.
   *Suggested:* `DS.Colour.buttonBorder`.
4. **Segmented selected-chip shadow.** Only needed if the product owner rules
   that §5's `0 1px 2px rgba(0,0,0,.10)` beats §设计语言's
   `0 1px 1.5px rgba(0,0,0,.05)` (= `DS.Shadow.control`). Currently resolved in
   favour of the design-language table; no token needed unless that flips.

Two more sizes are literals by necessity, not by gap: the icon point sizes (13 /
10), which exist only because the handoff ships no Material→SF size table, and
the control heights/radii (24 / 26 / 5 / 7), which are per-control specs the
scale intentionally does not name.

## 12 · Out-of-scope changes needed

None. `ColumnHeader` (`SidebarShell.swift`) already matches 03C's header
exactly — 52pt tall, 24pt page padding, no bottom border — and `dsCard()`
(`DesignTokens.swift`) matches the card spec on all four properties. The
`overflow:hidden` clip was added locally in `SettingsGroup` rather than inside
`dsCard()` because other screens' cards may not want their content clipped; if
the other five audits report the same need, folding a `.clipShape` into
`dsCard()` would be the right consolidation.

## 13 · Verification

`swift build` and `swift test` were run in a detached worktree at `HEAD` with
only `SettingsViews2.swift` overlaid, because two other files in the working
tree (`SessionsViews.swift`, `MemoryViews.swift`) are mid-edit by parallel
audits and do not currently compile.

```
Build complete! (23.19s)
Executed 524 tests, with 0 failures (0 unexpected)
```

(The first run showed 1 failure —
`testSidecarClientStartsHealthChecksAndStopsRealDevServer` — caused by the
worktree lacking `sidecar/node_modules`; symlinking it in turned that green,
confirming it was environmental.)
