# 听写 + 统计带 — 逐元素对照

**设计稿**：`design_handoff_opentype_redesign_v1/OpenType 重设计（单文件·离线）.html`，节 **3A · 听写**（内容区 908×640）与节 **06A / 06B / 06C · 本地统计**。数值直接取自稿件的内联 CSS，不取 README 的散文（README 会四舍五入）。
**实现**：`Sources/OpenType/DictationViews.swift`。
**日期**：2026-08-14。审查后本文件与实现同批修改，✅ 表示改完之后相符。

图标一律按 README「Assets」表把 Material Symbols 换成 SF Symbols：`search`→`magnifyingglass`、`unfold_more`→`chevron.up.chevron.down`、`content_copy`→`doc.on.doc`、`replay`→`arrow.counterclockwise`、`arrow_downward`→`arrow.down`。

状态记号：✅ 相符 · 🔧 本批修复 · ⚠️ 有意偏离（附理由）· 🚩 需要改 `DesignTokens.swift`，超出本次范围，已上报

---

## 关于颜色的一处系统性偏离（影响下表大量行）

设计稿的次要文字用的是 `rgba(28,28,30, α)` 这一套显式墨色：`.5 / .45 / .42 / .4 / .35 / .32 / .3`。实现用的是 SwiftUI 的层级样式 `.secondary`（≈ 黑 0.50）和 `.tertiary`（≈ 黑 0.26）。

- `.5` → `.secondary`：几乎精确。
- `.45` → `.secondary`：偏深 0.05，肉眼难分。
- `.42 / .4 / .35 / .32 / .3` → `.tertiary`：**全部偏浅**，最坏的一档（`.42` vs `0.26`）差了约 60% 的墨量，在图注、分组标签、「最近 7 天」这些行上看得出来。

正确的修法是在 `DesignTokens.swift` 里补一个墨色刻度（见文末「Token gaps」1），而不是在本文件里硬写 `Color(white: 0, opacity: 0.42)` —— 这些 α 值六个屏幕共用，只改一个文件会让听写页和记忆页、Agent 工具页当场不一致。所以下表凡是这一类，一律记 🚩 而不是 🔧。

---

## 1 · 页头（3A，高 52pt，`padding: 0 24px`，`gap: 14px`）

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| 页头容器 | height | `52px` | `DS.Size.headerHeight` = 52（`ColumnHeader`） | ✅ |
| 页头容器 | padding-x | `24px`（窄布局 14，见 README §2） | `ColumnHeader` 的 `pageWide` 24 / `pageNarrow` 14 | 🔧 原先在 `ColumnHeader` 外面又加了 `pageWide - content` = 8pt，宽布局实际是 **32**。那句补偿是 `ColumnHeader` 还padding 16 时留下的，共享头改成 24 之后就成了双重 padding。已删除 |
| 页头容器 | gap | `14px` | 内嵌 `HStack(spacing: 14)` 作为 `ColumnHeader` 的唯一子视图 | 🔧 原先直接铺四个子视图，吃 `ColumnHeader` 的 `spacing: 8`。`ColumnHeader` 在 `SidebarShell.swift`（范围外）且被所有列共用，所以在本页内嵌一层而不是改共享头 |
| 页头容器 | align | `center` | `HStack` 默认 `.center` | ✅ |
| 标题「听写」 | font | `20px / 700` | `DS.Text.title()` = 20pt bold | ✅ |
| 标题「听写」 | letter-spacing | `-.02em` = −0.4 @20pt | `DS.Tracking.title` = −0.4 | ✅ |
| 标题「听写」 | color | 继承（≈ `#1C1C1E`） | `.primary` | ✅ |
| 计数「248 条 · 全部保存在本机」 | font | `11px` mono | `DS.Text.mono()` = 11pt monospaced regular | ✅ |
| 计数 | color | `rgba(28,28,30,.4)` | `.tertiary` ≈ 0.26 | 🚩 |
| 计数 | flex | `flex: 1`（吃掉剩余宽度，搜索框贴右） | `.frame(maxWidth: .infinity, alignment: .leading)` | 🔧 原先用 `Spacer(minLength: 8)`；在 `spacing: 14` 的行里 Spacer 两侧各加 14，等于把标题和计数推开 28 |
| 计数 | 截断 | 未指定 | `lineLimit(1)` | ⚠️ 一行内的计数不能换行把页头撑高 |
| 计数 | 窄布局 | 稿件只画了宽布局 | 窄布局整条不渲染 | ⚠️ 460pt 下计数会截成「248 条 · 全部保…」，比它下面的列表本身信息还少 |
| 搜索框 | height | `26px` | `.frame(height: 26)` | ✅ |
| 搜索框 | padding-x | `11px` | `.padding(.horizontal, 11)` | ✅ |
| 搜索框 | radius | `7px` | `DS.Radius.control` = 6 | ⚠️ 令牌表把 6 分配给「按钮 / 筛选 chip / 分段控件 / 下拉 / 标签」，这两个都是控件。守住封闭刻度比这 1pt 值钱（`dsHeaderControl()` 里已有注释） |
| 搜索框 | background | `#fff` | `DS.Colour.card` = `Color.white` | ✅ |
| 搜索框 | border | `.75px rgba(0,0,0,.09)` | `DS.Colour.border` = `primary.opacity(0.07)`，0.75pt | 🚩 宽度对，α 差 0.02 |
| 搜索框 | shadow | `0 1px 1.5px rgba(0,0,0,.05)` | `DS.Shadow.control` = 黑 0.05 / radius 0.75 / y 1（CSS blur 1.5 ≈ radius 0.75） | ✅ |
| 搜索框 | gap | `6px` | `HStack(spacing: 6)` | ✅ |
| 搜索框 | width | 内容宽（`padding` + 图标 + 占位文案） | 定宽 190（窄 140） | ⚠️ `TextField` 必须有确定宽度，否则会随输入长度抖动 |
| 搜索图标 | icon / size | `search` 15px → `magnifyingglass` | `.system(size: 15)` | 🔧 原先 `DS.Text.section()`（15pt **semibold**）；字号对，字重把字形画粗了。改成 15pt regular |
| 搜索图标 | color | `rgba(28,28,30,.5)` | `.secondary` ≈ 0.50 | ✅ |
| 搜索占位文案 | font | `12px` | `DS.Text.caption()` = 12pt | ✅ |
| 搜索占位文案 | color | `rgba(28,28,30,.4)` | 系统 placeholder 色 | ⚠️ `TextField` 的占位色由 `.plain` 样式给，改它要自绘占位层 |
| 清除按钮（`xmark`） | — | 稿件没有 | 有输入时出现，11pt `.tertiary` | ⚠️ 新增。稿件只画了静态态；一个 26pt 的搜索框没有清除入口，只能靠全选删除 |
| 来源下拉 | height / padding-x / radius / bg / border / shadow / gap | 同搜索框 | 同搜索框（共用 `dsHeaderControl()`） | 同上 |
| 来源下拉文案 | font / color | `12px`，继承色 | `DS.Text.caption()` = 12pt，`.primary` | ✅ |
| 来源下拉图标 | icon / size | `unfold_more` 14px → `chevron.up.chevron.down` | `.system(size: 14)` | 🔧 原先 `DS.Text.body()` = 13pt |
| 来源下拉图标 | color | `rgba(28,28,30,.35)` | `.tertiary` ≈ 0.26 | 🚩 |

## 2 · 内容区

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| 内容区 | padding | `0 24px 24px`（窄 14） | `.padding(.horizontal, page)` + `.padding(.bottom, page)`，`page` = 24 / 14 | ✅ |
| 内容区 | gap | `16px` | `VStack(spacing: DS.Space.group)` = 16 | ✅ |
| 页面底色 | background | `#F5F5F3` | 由外壳给 `DS.Colour.canvas` = (245,245,243) | ✅ |

## 3 · 统计带 · 卡片（06A）

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| 卡片 | background | `#fff` | `dsCard()` → `DS.Colour.card` | ✅ |
| 卡片 | border | `.75px rgba(0,0,0,.07)` | `DS.Colour.border` = `primary.opacity(0.07)`，0.75pt | ✅ |
| 卡片 | radius | `14px` | `DS.Radius.card` = 14 | ✅ |
| 卡片 | shadow | `0 1px 2px rgba(0,0,0,.04)` | `DS.Shadow.card` = 黑 0.04 / radius 1 / y 1 | ✅ |
| 卡片 | overflow | `hidden` | `.clipShape(RoundedRectangle(14, .continuous))` | ✅ |
| 上半区 | padding | `16px 20px 14px` | `.padding(.top, 16)` / `.horizontal, 20` / `.bottom, 14` | ✅ |
| 上半区 | display / gap | `flex; gap: 24px; align-items: flex-start` | `HStack(alignment: .top, spacing: DS.Space.pageWide)` = 24 | ✅ |
| 数字区 | flex | `flex: 1; display: flex; gap: 28px` | `HStack(spacing: 28).frame(maxWidth: .infinity, alignment: .leading)` | ✅ |

## 4 · 统计带 · 四个数字（宽，06A）

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| 单个数字块 | flex-direction / gap | `column; gap: 3px` | `VStack(alignment: .leading, spacing: 3)` | ✅ |
| 单个数字块 | width | 内容宽（容器 `flex:1`，`justify-content` 默认 `flex-start`） | 内容宽 | 🔧 原先每块 `.frame(maxWidth: .infinity)`，四块均分整行 —— 每块之后的空隙都比 28 大且各不相同，正好是一组用竖线分隔的数字最不能有的东西 |
| 值 | font | `600 26px/1` mono | `DS.Text.mono(26, weight: .semibold)` | ✅ |
| 值 | letter-spacing | `-.02em` = **−0.52** @26pt | `-0.02 * 26` = −0.52 | 🔧 原先复用 `DS.Tracking.title`（同样是 `-.02em`，但已在 20pt 上解析成 −0.4），在 26pt 上差 0.12 |
| 值 | color（有数据） | 继承（1–3）/ `#0D73FA`（第 4） | `.primary` / `DS.Colour.accent` = (0.05,0.45,0.98) ≈ `#0D73FA` | ✅ |
| 值 | color（无数据） | `rgba(28,28,30,.3)`（见 06C） | `.tertiary` ≈ 0.26 | ✅ 同档 |
| 值行 | align / gap（第 4 个带趋势） | `baseline; gap: 7px` | `HStack(alignment: .firstTextBaseline, spacing: 7)` | ✅ |
| 单位「秒」 | font-size | `15px` | `DS.Text.section()` = 15pt | ✅ |
| 单位「秒」 | font-weight | `500`（medium） | `.weight(.medium)` | 🔧 原先是 `DS.Text.section()` 的 semibold |
| 单位「秒」 | color | `rgba(28,28,30,.45)` | `.secondary` ≈ 0.50 | ✅ 同档 |
| 单位「秒」 | margin-left | `2px` | `.padding(.leading, 2)` | ✅ |
| 单位「秒」 | 无数据时 | 稿件 06C 只印「—」，不带单位 | `unit` 在 latency 为 `nil` 时为 `nil` | ✅ |
| 标签 | font | `12px / 500` | `DS.Text.caption().weight(.medium)` | ✅ |
| 标签 | color | 继承 / 无数据时 `rgba(28,28,30,.5)`（06C） | `.primary` / `.secondary` | ✅ |
| 注 | font-size | `11px`，regular | `dsNote()` = `.system(size: 11)` | ✅ |
| 注 | color | `rgba(28,28,30,.42)` | `.tertiary` ≈ 0.26 | 🚩 |
| ① 值 / 标签 / 注 | 文案 | `4,182` / 说出的字数 / 中文按字 · 英文按词 | `summary.wordsDictated` 千分位 + 同文案 | ✅ |
| ② | 文案 | `2.4 秒` / 平均等待 / 松开快捷键 → 出字 | `averageEndToEndLatency`，`%.1f` + 同文案 | ✅ |
| ③ | 文案 | `5.1 秒` / 回答耗时 / 识别之后 · 问答与 Agent | `averageResponseLatency` + 同文案 | ✅ |
| ④ | 文案 | `1.3` / 每 100 字纠错 / 词典学得越多应越低 | `correctionsPerHundredWords` + 同文案 | ✅ |
| **上色** | — | **只有第 4 个** `#0D73FA` | 只有 `rate` 带 `accented: true` | ✅ |
| 趋势 | 布局 | `flex; align-items: center; gap: 2px` | `HStack(spacing: 2)`，默认 `.center` | ✅ |
| 趋势箭头 | icon / size | `arrow_downward` 13px → `arrow.down` | `DS.Text.body()` = 13pt | ✅ |
| 趋势箭头 | 方向 | 稿件固定画向下 | 按 `current` vs `previous` 取 `arrow.down` / `arrow.up` / `minus` | ⚠️ 稿件画向下是因为这个指标「应该往下走」；无条件画向下会在数字上升时印一个下降箭头。字形跟着比较结果走，「向下 = 更好」这层意思才留得住 |
| 趋势文案 | font | `11px` mono，「上周 2.1」 | `DS.Text.mono()` = 11pt | ✅ |
| 趋势 | color | `rgba(28,28,30,.42)` | `.tertiary` ≈ 0.26 | 🚩 |
| 趋势 | 无数据时 | 06C 不画 | `previousCorrectionsPerHundredWords == nil` 或本周无数据时为 `nil` | ✅ |

## 5 · 统计带 · 竖分隔线

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| 竖线 | width | `.75px` | `.frame(width: 0.75)` | ✅ |
| 竖线 | color | `rgba(0,0,0,.07)` | `DS.Colour.border` = `primary.opacity(0.07)` | ✅ |
| 竖线 | height | `align-self: stretch` | `.frame(maxHeight: .infinity)`（在 `.top` 对齐的 `HStack` 内） | ✅ |
| 竖线 | 数量 / 位置 | 3 条，夹在四个数字之间 | 3 条，同位置 | ✅ |

## 6 · 统计带 · 7 天柱状区（06A）

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| 柱状区 | width | `flex: none; width: 190px` | `.frame(width: 190)` | ✅ |
| 柱状区 | gap | `7px` | `VStack(spacing: 7)` | ✅ |
| 标题行 | align | `baseline` | `HStack(alignment: .firstTextBaseline, spacing: 8)` | ✅ |
| 「最近 7 天」 | font | `11px / 600` | `DS.Text.groupLabel()` = 11pt semibold | ✅ |
| 「最近 7 天」 | letter-spacing | `.05em` = 0.55 @11pt | `DS.Tracking.groupLabel` = 0.55 | ✅ |
| 「最近 7 天」 | color | `rgba(28,28,30,.42)` | `.tertiary` ≈ 0.26 | 🚩 |
| 「68 次交付」 | font | `11px` mono | `DS.Text.mono()` = 11pt | ✅ |
| 「68 次交付」 | color | `rgba(28,28,30,.4)` | `.tertiary` ≈ 0.26 | 🚩 |
| 「68 次交付」 | 来源 | 交付次数 | `summary.deliveries` | ✅ |
| 柱行 | align / gap | `align-items: flex-end; gap: 6px` | `HStack(alignment: .bottom, spacing: 6)` | ✅ |
| 柱行 | height | `46px` | 自然高（34 柱 + 5 gap + 10pt 字行 ≈ 51） | ⚠️ 稿件的 46 装不下它自己写的 34 + 5 + 10pt 行；写死 46 会切掉星期字。让它按内容撑开 |
| 单根柱容器 | width / height | `flex: 1; width: 100%; height: 34px; align-items: flex-end` | `.frame(height: 34).frame(maxWidth: .infinity)`，`ZStack(alignment: .bottom)` | ✅ |
| 单根柱容器 | gap（柱↔星期字） | `5px` | `VStack(spacing: 5)` | ✅ |
| 柱基线 | — | 稿件没有 | — | 🔧 原先每格底部画了一条 0.75pt `hairline`；七格连起来就是一条稿件里不存在的坐标轴。已删除 |
| 柱 | background | `rgba(13,115,250,.55)` | `DS.Colour.accent.opacity(0.55)` | ✅ |
| 柱 | radius | `3px 3px 0 0` | `UnevenRoundedTop(radius: 3)`（半径随柱高收缩，避免 2pt 高的柱变成药丸） | ✅ |
| 柱 | height | 按值比例 | `34 * count / peak`，非零时至少 2pt | ⚠️ 最小 2pt：不给下限的话，一个有字数的日子和一个没有的日子长得一样 |
| 柱 | 分桶 | 7 天 | `summary.dailyWords`（滚动 24h 桶，`UsageStats.bucketCount` = 7） | ✅ |
| 星期字 | font | `10px` mono | `DS.Text.mono(10)` = 10pt | ✅ |
| 星期字 | color | `rgba(28,28,30,.35)`，**七个一致** | `.tertiary`，七个一致 | 🔧 原先最后一格印「今」并用 accent 上色。稿件七格都是 `{{ b.day }}` 一个颜色，且整条带的编辑立场是「只有第四个数字有蓝色」——多一处蓝字就是多一个和它抢注意力的东西。「今天还没过完」这层意思移到 tooltip（🚩 颜色档位同上） |
| 星期字 | 内容 | 星期 | `EEEEE`（单字母/单字），跟 locale | ✅ |
| 柱 | tooltip | 稿件没有 | 「8月13日 · N 字」；最后一格「今天 · N 字（当天还没过完）」 | ⚠️ 新增。滚动 24h 分桶下最后一格总是偏矮，不解释会被读成「今天崩了」 |

## 7 · 统计带 · 免责说明条（06A）

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| 条 | padding | `9px 20px` | `.padding(.vertical, 9)` / `.horizontal, 20`（窄 16） | ✅ |
| 条 | border-top | `.75px rgba(0,0,0,.06)` | `dsHairline(.top)` → `DS.Colour.hairline` = `primary.opacity(0.06)`，0.75pt | ✅ |
| 条 | background | `#FAFAF8` = (250,250,248) | `DS.Colour.inset` = `primary.opacity(0.035)` ≈ (244,244,244)，且偏中性无暖调 | 🚩 令牌值本身和稿件对不上，见文末 Token gaps 2 |
| 文案 | font-size | `11px` | `dsNote()` = 11pt | ✅ |
| 文案 | line-height | `1.6` | `lineSpacing(4)`（11×1.6 = 17.6，11pt 自然行高 ≈ 13.5） | ✅ |
| 文案 | color | `rgba(28,28,30,.45)` | `.secondary` ≈ 0.50 | ✅ 同档 |
| 文案 | 内容 | 「在这台 Mac 上从本地审计日志算出，不上传。中英混说时字数是两种单位的合计，适合和自己过去比，不适合跨语言比较。」 | 逐字一致 | ✅ |
| 条 | 窄布局是否保留 | 06B/06C 是 394pt 的独立卡片，没画这条 | 窄布局仍然保留 | ⚠️ README §6 对窄布局只说了「去掉柱状区、四个数折成 2×2、数字降到 22」，没说去掉免责。这条是隐私声明，窄窗口不是撤掉它的理由 |

## 8 · 日期分组标签

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| 分组 | flex-direction / gap | `column; gap: 8px` | `VStack(alignment: .leading, spacing: DS.Space.label)` = 8 | ✅ |
| 标签 | padding | `0 4px` | `.padding(.horizontal, 4)` | ✅ |
| 标签 | font | `11px / 600` | `DS.Text.groupLabel()` = 11pt semibold | ✅ |
| 标签 | letter-spacing | `.05em` = 0.55 | `DS.Tracking.groupLabel` = 0.55 | ✅ |
| 标签 | color | `rgba(28,28,30,.42)` | `.tertiary` ≈ 0.26 | 🚩 |
| 标签 | 文案 | 「今天」「昨天」 | 今天 / 昨天 / `MMMd` 模板（跟 locale） | ✅ |
| 分组卡 | bg / border / radius / shadow / overflow | 同统计带卡片 | `dsCard()` + `clipShape(14)` | ✅ |
| 分组结构 | — | **一张白卡装 N 行**，不是一行一张卡 | 一个 `VStack(spacing: 0)` 套 N 行，整体一张卡 | ✅ |

## 9 · 听写行（3A / 06A 同规格）

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| 行 | padding | `13px 16px` | `.padding(.vertical, 13)` / `.horizontal, DS.Space.content` = 16 | ✅ |
| 行 | display / gap / align | `flex; gap: 16px; align-items: flex-start` | `HStack(alignment: .top, spacing: DS.Space.content)` = 16 | ✅ |
| 行 | border-top | `.75px rgba(0,0,0,.06)`，行与行之间 | `dsHairline(.top)`，`index > 0` 才画 | ✅ 首行不画：卡边内 0.75pt 再来一条会读成第二道卡边 |
| 左列 | width | `64px; flex: none` | `.frame(width: 64, alignment: .leading)` | ✅ |
| 左列 | gap | `3px` | `VStack(spacing: 3)` | ✅ |
| 左列 | padding-top | `1px` | `.padding(.top, 1)` | ✅ |
| 时间 | font | `11px` mono | `DS.Text.mono()` = 11pt | ✅ |
| 时间 | color | `rgba(28,28,30,.45)` | `.secondary` ≈ 0.50 | ✅ 同档 |
| 时间 | 格式 | `21:47` | `HH:mm` | ✅ |
| 应用名 | font-size | `11px`，regular | `dsNote()` = 11pt | ✅ |
| 应用名 | color | `rgba(28,28,30,.35)` | `.tertiary` ≈ 0.26 | 🚩 |
| 应用名 | 截断 | 未指定（64pt 定宽内） | `lineLimit(1)` | ⚠️ 64pt 内换行会把行高顶起来 |
| 转写文本 | flex | `flex: 1; min-width: 0` | `.frame(maxWidth: .infinity, alignment: .leading)` | ✅ |
| 转写文本 | font-size | `13px` | `DS.Text.body()` = 13pt | ✅ |
| 转写文本 | line-height | `1.6` | `lineSpacing(5)`（13×1.6 = 20.8，13pt 自然行高 ≈ 16） | ✅ |
| 转写文本 | color | 继承 | `.primary` | ✅ |
| 转写文本 | 截断 | 稿件不截 | `lineLimit(4)` | ⚠️ 稿件里每条都是一两句话；一段五分钟口述会把单行撑成半屏，把它下面的日期分组全推走。四行是「读得出这是哪条」和「列表还能扫」的折中，全文永远在剪贴板和复核面板里 |
| 转写文本 | 选中 | — | `textSelection(.enabled)` | ⚠️ 新增。一条转写的主要用途就是取走它 |
| 动作区 | flex / gap / padding-top | `flex: none; gap: 8px; padding-top: 1px` | `HStack(spacing: 8)` + `.padding(.top, 1)` | ✅ |
| 动作图标 | icon | `content_copy` / `replay` → `doc.on.doc` / `arrow.counterclockwise` | 同 | ✅ |
| 动作图标 | size | `16px` | `.system(size: 16)` | 🔧 原先 `DS.Text.section()` = 15pt semibold，字号小 1pt 且字重画粗了 |
| 动作图标 | **常驻 vs hover 出现** | 稿件在静止行里就画了这两个图标，README 只把 hover 描述成「升到 .55」 | 常驻 | 🔧 原先 `opacity(hovering ? 1 : 0)`，整组 hover 才出现。稿件对「hover 才出现」是会明说的（记忆页写了「编辑/删除改为 hover 出现，不常驻」），听写页没写 —— 扫一周转写时应该看得出哪行能复制，而不是靠指针去发现 |
| 动作图标 | color | `rgba(28,28,30,.32)`，hover 升到 `.55` | `.tertiary` ≈ 0.26 → 行 hover 时 `.secondary` ≈ 0.50 | 🚩 档位对，α 差一点 |
| 动作图标 | hover 主体 | README 未指明 | **行** hover 时两个一起变深 | ⚠️ 稿件把 `.32 → .55` 写成这一对图标的共同属性，所以按行响应；原先的逐图标 hover 已去掉，避免多出一个稿件没有的第三态 |
| 动作 | tooltip / a11y | 稿件没有 | 「复制」「重新使用」 | ⚠️ 新增。两个无标签图标按钮必须有可访问名 |
| 空列表 | — | 稿件没画 | 「还没有听写记录」/「没有匹配的记录」两态 | ⚠️ 新增。稿件是满数据稿，首次启动和搜不到都会落到这里 |

## 10 · 窄布局统计带（06B，394pt）

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| 卡片 | bg / border / radius / shadow | 同宽布局 | 同 | ✅ |
| 标题行 | padding | `12px 16px 10px` | `.padding(.top, 12)` / `.horizontal, 16` / `.bottom, 10` | ✅ |
| 标题行 | align | `baseline` | `HStack(alignment: .firstTextBaseline, spacing: 8)` | ✅ |
| 「最近 7 天」/「N 次交付」 | font / color | 同宽布局 | 复用同一对 `weekLabel` / `deliveriesLabel` | ✅ / 🚩 颜色同上 |
| 柱状区 | — | **去掉** | 窄布局不渲染 `barStrip` | ✅ |
| 数字网格 | padding | `0 16px 14px` | `.padding(.horizontal, 16)` / `.bottom, 14` | ✅ |
| 数字网格 | columns | `1fr 1fr` | `LazyVGrid`，两个 `.flexible()` | ✅ |
| 数字网格 | gap | `14px 20px`（行 14 / 列 20） | `spacing: 14`（行）+ `GridItem(spacing: 20)`（列） | ✅ |
| 数字块 | gap | `2px` | `VStack(spacing: 2)` | ✅ |
| 值 | font | `600 22px/1` mono | `DS.Text.mono(22, weight: .semibold)` | ✅ |
| 值 | letter-spacing | **无**（06B 没写 `letter-spacing`） | `tracking(0)` | 🔧 原先窄宽两档共用 `DS.Tracking.title` = −0.4 |
| 值 | color | 前三个继承 / 第四个 `#0D73FA` | 同宽布局的 `valueStyle` | ✅ |
| 单位「秒」 | font | `13px / 500` | `DS.Text.body(.medium)` = 13pt medium | 🔧 原先窄宽共用 15pt semibold |
| 单位「秒」 | margin-left | **无**（06B 没写 `margin-left`） | `.padding(.leading, 0)` | 🔧 原先两档都加 2 |
| 单位「秒」 | color | `rgba(28,28,30,.45)` | `.secondary` | ✅ 同档 |
| 标签 | font-size | `11.5px`，regular | `DS.Text.caption()` = 12pt regular | ⚠️ `DS.Text` 是六级封闭刻度，没有 11.5 这一步；`DesignTokens.swift` 的开篇就是为了不让 0.5pt 的临时值再长回来。差 0.5pt，字重和颜色都对 |
| 标签 | 截断 | 未指定 | `lineLimit(1)` + `minimumScaleFactor(0.85)` | ⚠️ 394pt 下单列约 171pt，「每 100 字纠错」刚好放得下；缩放只是英文界面的保险 |
| 趋势「上周 2.1」 | — | 06B 不画 | 窄布局不渲染 | ✅ |
| 折叠断点 | — | README §2 建议窗口 < 720 | 本页按**自身宽度** < 700 折叠 | ⚠️ 这条带折叠与否取决于它自己有多少地方（4 个数 + 3 条线 + 190pt 柱区 ≈ 780），不取决于窗口；`DS.Size.narrowBreakpoint` 回答的是另一个问题 |

## 11 · 空值规则（06C）

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| ① 说出的字数 | 无数据时的值 | 印 **`0`**，不是「—」 | `Self.grouped(summary.wordsDictated)` → `"0"` | ✅ |
| ① 说出的字数 | 无数据时的色 | `rgba(28,28,30,.3)` | `hasData == false` → `.tertiary` ≈ 0.26 | ✅ 同档 |
| ② 平均等待 | 无数据时 | 印 **`—`** | `latencyValue(nil)` → `"—"` | ✅ |
| ③ 回答耗时 | 无数据时 | 印 **`—`** | `latencyValue(nil)` → `"—"` | ✅ |
| ④ 每 100 字纠错 | 无数据时 | 印 **`—`** | `wordsDictated == 0` 时 `"—"`（`Summary` 这时把比率算成 0，印「0.0」会读成满分） | ✅ |
| ④ 每 100 字纠错 | 无数据时的色 | `rgba(28,28,30,.3)`，**不上 accent** | `valueStyle` 在 `!hasData` 时先返回 `.tertiary`，accent 不生效 | ✅ |
| 四个标签 | 无数据时的色 | `rgba(28,28,30,.5)` | `.secondary` ≈ 0.50 | ✅ |
| 交付次数 | 无数据时 | 「0 次交付」 | `summary.deliveries` = 0 | ✅ |
| 单位「秒」 | 无数据时 | 不画 | `unit` 为 `nil` | ✅ |

---

## Token gaps（需要改 `DesignTokens.swift`，本次范围外，已上报）

1. **墨色刻度缺失（影响最大）** —— 稿件全篇用 `rgba(28,28,30, α)`，α 取 `.5 / .45 / .42 / .4 / .35 / .32 / .3`；`DS.Colour` 只有 `.primary/.secondary/.tertiary` 三级可用（≈ 0.85 / 0.50 / 0.26）。落在 `.42–.30` 区间的一律偏浅，最差一档差约 60% 墨量。建议加：

   ```swift
   /// 稿件的次要墨色。基色 #1C1C1E 与 `.primary`(labelColor, 黑 0.85) 同档，
   /// 所以只需要 α 这一维。
   enum Ink {
       static let strong  = Color(red: 0.110, green: 0.110, blue: 0.118).opacity(0.50)
       static let medium  = Color(red: 0.110, green: 0.110, blue: 0.118).opacity(0.45)
       static let soft    = Color(red: 0.110, green: 0.110, blue: 0.118).opacity(0.42)
       static let faint   = Color(red: 0.110, green: 0.110, blue: 0.118).opacity(0.35)
       static let ghost   = Color(red: 0.110, green: 0.110, blue: 0.118).opacity(0.30)
   }
   ```

   本页会用到：`soft`（图注、分组标签、「最近 7 天」、趋势、计数）、`faint`（应用名、星期字、下拉箭头）、`ghost`（空值数字）、`.32`（行动作图标，可归到 `faint`）。这一档改动一旦落地，本文件里 8 处 🚩 会一次性变 ✅ —— 但它同时影响另外五个屏幕，必须一批改、一批验。

2. **`DS.Colour.inset` 的值和稿件不符** —— 稿件的凹陷面一律 `#FAFAF8`（免责条、07A 的分组小标题都是它），令牌是 `Color.primary.opacity(0.035)`，在白底上解析成约 (244,244,244)：偏深约 6 个色阶，而且丢了稿件那点暖调。建议改成字面值 `Color(red: 250/255, green: 250/255, blue: 248/255)`（应用锁在 light 外观，字面色是安全的，`DS.Colour.card` 已经是同样的处理）。同样跨屏幕，不在本次范围内单独硬写。

3. **`dsNote()`（11pt regular）仍在本文件里私有** —— `DS.Text` 的 11pt 只有 `groupLabel()`（semibold）和 `mono()`。稿件把图注、应用名、免责条都设成 11pt 常规西文字面，semibold 在这个字号上会读成小标题。已按原注释留在本文件顶部，等 `DesignTokens.swift` 下次打开时收进去。

4. **`DS.Text` 没有 11.5pt** —— 06B 的窄布局标签是 11.5px。当前用 12pt。是否值得为 0.5pt 破封闭刻度，请产品/设计定；不加的话这一行永远是 ⚠️。

5. **`DS.Radius` 没有 7pt** —— 稿件的页头小控件是 7px，令牌只有 6（控件）和 10（内嵌块）。当前取 6，`dsHeaderControl()` 里已写明理由。

## 需要改其他文件（本次范围外，已上报）

- **`Sources/OpenType/SidebarShell.swift` · `ColumnHeader`** —— 它的 `HStack(spacing: 8)` 和稿件 3A 的 `gap: 14px` 不一致。本页用「内嵌一层 `HStack(spacing: 14)` 当唯一子视图」绕开了，但如果别的列的页头 gap 也是 14，正确的修法是把 `ColumnHeader` 的 spacing 改成 14，然后各页把这层内嵌拆掉。需要先确认会话 / 记忆 / 设置三页稿件里的页头 gap。
