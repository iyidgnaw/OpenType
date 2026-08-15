# 听写 + 统计带 — 逐元素对照

**设计稿**：`design_handoff_opentype_redesign_v1/OpenType 重设计（单文件·离线）.html`，节 **3A · 听写**（内容区 908×640）与节 **06A / 06B / 06C · 本地统计**。数值直接取自稿件的内联 CSS，不取 README 的散文（README 会四舍五入）。
**实现**：`Sources/OpenType/DictationViews.swift`。
**日期**：2026-08-14。审查后本文件与实现同批修改，✅ 表示改完之后相符。

图标一律按 README「Assets」表把 Material Symbols 换成 SF Symbols：`search`→`magnifyingglass`、`unfold_more`→`chevron.up.chevron.down`、`content_copy`→`doc.on.doc`、`replay`→`arrow.counterclockwise`、`arrow_downward`→`arrow.down`。

状态记号：✅ 相符 · 🔧 已修复 · ⚠️ 有意偏离（附理由）

---

## 第二批（2026-08-15）：稿子优先，撤销全部令牌坍缩

第一批把稿子的字面值映射到 README 的封闭刻度上：7pt 圆角收成 6，11.5pt 收成 12，`rgba(0,0,0,.09)` 收成唯一的 `.07`，`rgba(28,28,30,.3~.45)` 一律收成 `.tertiary`。产品负责人推翻了这个取舍 —— **稿子无条件优先**。所以本批把这些坍缩全部撤回，`DesignTokens.swift` 为每一个补了具名档位；本页一共撤回 23 处：原先记 🚩 的 11 行（另有 1 行随页头计数一起消失、1 行是引用别处的颜色）、记 ⚠️ 的 2 行（7pt 圆角、11.5pt 标签），以及 10 行当初按 README 的「`.45`→`.secondary`、`.35`→`.tertiary` 同档映射」记成 ✅ 的 —— 那条映射正是被推翻的东西，所以它们也算坍缩。

### 那条系统性的颜色偏离，已经修掉

设计稿的次要文字用的是 `rgba(28,28,30, α)` 这一套显式墨色：`.5 / .45 / .42 / .4 / .35 / .32 / .3`。第一批用 SwiftUI 的层级样式 `.secondary`（≈ 黑 0.50）和 `.tertiary`（≈ 黑 0.26）代替，落在 `.42–.30` 区间的一律偏浅，最坏一档差约 60% 的墨量。

现在这一整条轴在 `DS.Colour.ink(_:)` 里，基色是字面的 `#1C1C1E`，α 直接照抄稿子。下表写作 `ink(0.42)` 的即是。同一批里 `DS.Colour.hairline` / `border` 也从 `Color.primary.opacity(α)` 换成了 `Color.black.opacity(α)` —— `labelColor` 本身就是黑 0.85，旧写法把 `rgba(0,0,0,.07)` 解析成了 0.0595。

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
| 计数「248 条 · 全部保存在本机」 | 是否存在 | 3A 画了，6A **没画**（同一个页头，只剩 `flex:1` 的空档） | 不渲染，位置由 `Spacer(minLength: 0)` 吃掉 | ✅ 对 6A。稿子这两节自相矛盾，而实现的是 6A —— 统计带就在页头下面，那条免责声明已经把「全部保存在本机」讲了一遍。审查后由产品负责人拍板去掉（`36ff2a7`），不属于本批的令牌坍缩 |
| 搜索框 | height | `26px` | `.frame(height: 26)` | ✅ |
| 搜索框 | padding-x | `11px` | `.padding(.horizontal, 11)` | ✅ |
| 搜索框 | radius | `7px` | `DS.Radius.iconButton` = 7 | 🔧 原先 `DS.Radius.control` = 6 |
| 搜索框 | background | `#fff` | `DS.Colour.card` = `Color.white` | ✅ |
| 搜索框 | border | `.75px rgba(0,0,0,.09)` | `DS.Colour.controlBorder` = 黑 0.09，0.75pt | 🔧 原先 `DS.Colour.border`。页头控件躺在 `#F5F5F3` 上而不是卡里，明度差本来就小，这 0.02 就是稿子花在「让它看着像个控件」上的钱 |
| 搜索框 | shadow | `0 1px 1.5px rgba(0,0,0,.05)` | `DS.Shadow.control` = 黑 0.05 / radius 0.75 / y 1（CSS blur 1.5 ≈ radius 0.75） | ✅ |
| 搜索框 | gap | `6px` | `HStack(spacing: 6)` | ✅ |
| 搜索框 | width | 内容宽（`padding` + 图标 + 占位文案） | 定宽 190（窄 140） | ⚠️ `TextField` 必须有确定宽度，否则会随输入长度抖动 |
| 搜索图标 | icon / size | `search` 15px → `magnifyingglass` | `.system(size: 15)` | 🔧 原先 `DS.Text.section()`（15pt **semibold**）；字号对，字重把字形画粗了。改成 15pt regular |
| 搜索图标 | color | `rgba(28,28,30,.5)` | `ink(0.5)` | 🔧 原先 `.secondary`（≈ 0.50，只差在没锚到 `#1C1C1E`） |
| 搜索占位文案 | font | `12px` | `DS.Text.caption()` = 12pt | ✅ |
| 搜索占位文案 | color | `rgba(28,28,30,.4)` | 系统 placeholder 色 | ⚠️ `TextField` 的占位色由 `.plain` 样式给，改它要自绘占位层 |
| 清除按钮（`xmark`） | — | 稿件没有 | 有输入时出现，11pt `.tertiary` | ⚠️ 新增。稿件只画了静态态；一个 26pt 的搜索框没有清除入口，只能靠全选删除 |
| 来源下拉 | height / padding-x / radius / bg / border / shadow / gap | 同搜索框 | 同搜索框（共用 `dsHeaderControl()`） | 同上 |
| 来源下拉文案 | font / color | `12px`，继承色 | `DS.Text.caption()` = 12pt，`.primary` | ✅ |
| 来源下拉图标 | icon / size | `unfold_more` 14px → `chevron.up.chevron.down` | `.system(size: 14)` | 🔧 原先 `DS.Text.body()` = 13pt |
| 来源下拉图标 | color | `rgba(28,28,30,.35)` | `ink(0.35)` | 🔧 原先 `.tertiary` ≈ 0.26 |

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
| 值 | letter-spacing | `-.02em` = **−0.52** @26pt | `DS.Tracking.em(-0.02, at: 26)` = −0.52 | 🔧 原先复用 `DS.Tracking.title`（同样是 `-.02em`，但已在 20pt 上解析成 −0.4），在 26pt 上差 0.12。第二批把这个换算收进 `DS.Tracking.em(_:at:)` |
| 值 | color（有数据） | 继承（1–3）/ `#0D73FA`（第 4） | `.primary` / `DS.Colour.accent` = (0.05,0.45,0.98) ≈ `#0D73FA` | ✅ |
| 值 | color（无数据） | `rgba(28,28,30,.3)`（见 06C） | `ink(0.3)` | 🔧 原先 `.tertiary` ≈ 0.26 |
| 值行 | align / gap（第 4 个带趋势） | `baseline; gap: 7px` | `HStack(alignment: .firstTextBaseline, spacing: 7)` | ✅ |
| 单位「秒」 | font-size | `15px` | `DS.Text.section()` = 15pt | ✅ |
| 单位「秒」 | font-weight | `500`（medium） | `.weight(.medium)` | 🔧 原先是 `DS.Text.section()` 的 semibold |
| 单位「秒」 | color | `rgba(28,28,30,.45)` | `ink(0.45)` | 🔧 原先 `.secondary` ≈ 0.50 |
| 单位「秒」 | margin-left | `2px` | `.padding(.leading, 2)` | ✅ |
| 单位「秒」 | 无数据时 | 稿件 06C 只印「—」，不带单位 | `unit` 在 latency 为 `nil` 时为 `nil` | ✅ |
| 标签 | font | `12px / 500` | `DS.Text.caption().weight(.medium)` | ✅ |
| 标签 | color | 继承 / 无数据时 `rgba(28,28,30,.5)`（06C） | `.primary` / `ink(0.5)` | 🔧 无数据档原先 `.secondary` |
| 注 | font-size | `11px`，regular | `dsNote()` = `.system(size: 11)` | ✅ |
| 注 | color | `rgba(28,28,30,.42)` | `ink(0.42)` | 🔧 原先 `.tertiary` ≈ 0.26 |
| ① 值 / 标签 / 注 | 文案 | `4,182` / 说出的字数 / 中文按字 · 英文按词 | `summary.wordsDictated` 千分位 + 同文案 | ✅ |
| ② | 文案 | `2.4 秒` / 平均等待 / 松开快捷键 → 出字 | `averageEndToEndLatency`，`%.1f` + 同文案 | ✅ |
| ③ | 文案 | `5.1 秒` / 回答耗时 / 识别之后 · 问答与 Agent | `averageResponseLatency` + 同文案 | ✅ |
| ④ | 文案 | `1.3` / 每 100 字纠错 / 词典学得越多应越低 | `correctionsPerHundredWords` + 同文案 | ✅ |
| **上色** | — | **只有第 4 个** `#0D73FA` | 只有 `rate` 带 `accented: true` | ✅ |
| 趋势 | 布局 | `flex; align-items: center; gap: 2px` | `HStack(spacing: 2)`，默认 `.center` | ✅ |
| 趋势箭头 | icon / size | `arrow_downward` 13px → `arrow.down` | `DS.Text.body()` = 13pt | ✅ |
| 趋势箭头 | 方向 | 稿件固定画向下 | 按 `current` vs `previous` 取 `arrow.down` / `arrow.up` / `minus` | ⚠️ 稿件画向下是因为这个指标「应该往下走」；无条件画向下会在数字上升时印一个下降箭头。字形跟着比较结果走，「向下 = 更好」这层意思才留得住 |
| 趋势文案 | font | `11px` mono，「上周 2.1」 | `DS.Text.mono()` = 11pt | ✅ |
| 趋势 | color | `rgba(28,28,30,.42)` | `ink(0.42)` | 🔧 原先 `.tertiary` ≈ 0.26 |
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
| 「最近 7 天」 | color | `rgba(28,28,30,.42)` | `ink(0.42)` | 🔧 原先 `.tertiary` ≈ 0.26 |
| 「68 次交付」 | font | `11px` mono | `DS.Text.mono()` = 11pt | ✅ |
| 「68 次交付」 | color | `rgba(28,28,30,.4)` | `ink(0.4)` | 🔧 原先 `.tertiary` ≈ 0.26 |
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
| 星期字 | color | `rgba(28,28,30,.35)`，**七个一致** | `ink(0.35)`，七个一致 | 🔧 第一批：原先最后一格印「今」并用 accent 上色。稿件七格都是 `{{ b.day }}` 一个颜色，且整条带的编辑立场是「只有第四个数字有蓝色」——多一处蓝字就是多一个和它抢注意力的东西。「今天还没过完」这层意思移到 tooltip。第二批：颜色从 `.tertiary` 改成 `ink(0.35)` |
| 星期字 | 内容 | 星期 | `EEEEE`（单字母/单字），跟 locale | ✅ |
| 柱 | tooltip | 稿件没有 | 「8月13日 · N 字」；最后一格「今天 · N 字（当天还没过完）」 | ⚠️ 新增。滚动 24h 分桶下最后一格总是偏矮，不解释会被读成「今天崩了」 |

## 7 · 统计带 · 免责说明条（06A）

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| 条 | padding | `9px 20px` | `.padding(.vertical, 9)` / `.horizontal, 20`（窄 16） | ✅ |
| 条 | border-top | `.75px rgba(0,0,0,.06)` | `dsHairline(.top)` → `DS.Colour.hairline` = `primary.opacity(0.06)`，0.75pt | ✅ |
| 条 | background | `#FAFAF8` = (250,250,248) | `DS.Colour.insetSurface` = 字面 `#FAFAF8` | 🔧 原先 `DS.Colour.inset`（`primary.opacity(0.035)` ≈ (246,246,246)，偏深且丢了暖调）。`inset` 这个 α 型令牌保留给浮层里那些压在毛玻璃上的凹块 —— 那里稿子本来写的就是 α |
| 文案 | font-size | `11px` | `dsNote()` = 11pt | ✅ |
| 文案 | line-height | `1.6` | `lineSpacing(4)`（11×1.6 = 17.6，11pt 自然行高 ≈ 13.5） | ✅ |
| 文案 | color | `rgba(28,28,30,.45)` | `ink(0.45)` | 🔧 原先 `.secondary` ≈ 0.50 |
| 文案 | 内容 | 「在这台 Mac 上从本地审计日志算出，不上传。中英混说时字数是两种单位的合计，适合和自己过去比，不适合跨语言比较。」 | 逐字一致 | ✅ |
| 条 | 窄布局是否保留 | 06B/06C 是 394pt 的独立卡片，没画这条 | 窄布局仍然保留 | ⚠️ README §6 对窄布局只说了「去掉柱状区、四个数折成 2×2、数字降到 22」，没说去掉免责。这条是隐私声明，窄窗口不是撤掉它的理由 |

## 8 · 日期分组标签

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| 分组 | flex-direction / gap | `column; gap: 8px` | `VStack(alignment: .leading, spacing: DS.Space.label)` = 8 | ✅ |
| 标签 | padding | `0 4px` | `DS.Space.labelInset` = 4 | ✅（第二批把这个 4 收成具名令牌，六个屏幕共用） |
| 标签 | font | `11px / 600` | `DS.Text.groupLabel()` = 11pt semibold | ✅ |
| 标签 | letter-spacing | `.05em` = 0.55 | `DS.Tracking.groupLabel` = 0.55 | ✅ |
| 标签 | color | `rgba(28,28,30,.42)` | `ink(0.42)` | 🔧 原先 `.tertiary` ≈ 0.26。全 app 的分组标签是同一档，同批一起改 |
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
| 时间 | color | `rgba(28,28,30,.45)` | `ink(0.45)` | 🔧 原先 `.secondary` ≈ 0.50 |
| 时间 | 格式 | `21:47` | `HH:mm` | ✅ |
| 应用名 | font-size | `11px`，regular | `dsNote()` = 11pt | ✅ |
| 应用名 | color | `rgba(28,28,30,.35)` | `ink(0.35)` | 🔧 原先 `.tertiary` ≈ 0.26 |
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
| 动作图标 | color | `rgba(28,28,30,.32)`，hover 升到 `.55` | `ink(0.32)` → 行 hover 时 `ink(0.55)` | 🔧 原先 `.tertiary` → `.secondary` |
| 动作图标 | hover 主体 | README 未指明 | **行** hover 时两个一起变深 | ⚠️ 稿件把 `.32 → .55` 写成这一对图标的共同属性，所以按行响应；原先的逐图标 hover 已去掉，避免多出一个稿件没有的第三态 |
| 动作 | tooltip / a11y | 稿件没有 | 「复制」「重新使用」 | ⚠️ 新增。两个无标签图标按钮必须有可访问名 |
| 空列表 | — | 稿件没画 | 「还没有听写记录」/「没有匹配的记录」两态 | ⚠️ 新增。稿件是满数据稿，首次启动和搜不到都会落到这里 |

## 10 · 窄布局统计带（06B，394pt）

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| 卡片 | bg / border / radius / shadow | 同宽布局 | 同 | ✅ |
| 标题行 | padding | `12px 16px 10px` | `.padding(.top, 12)` / `.horizontal, 16` / `.bottom, 10` | ✅ |
| 标题行 | align | `baseline` | `HStack(alignment: .firstTextBaseline, spacing: 8)` | ✅ |
| 「最近 7 天」/「N 次交付」 | font / color | 同宽布局 | 复用同一对 `weekLabel` / `deliveriesLabel` | ✅ 颜色随宽布局一起改成 `ink(0.42)` / `ink(0.4)` |
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
| 单位「秒」 | color | `rgba(28,28,30,.45)` | `ink(0.45)` | 🔧 原先 `.secondary` |
| 标签 | font-size | `11.5px`，regular | `DS.Text.size(11.5)` | 🔧 原先 `DS.Text.caption()` = 12pt。394pt 下单列约 171pt，「每 100 字纠错」正是靠这半个点排得下 |
| 标签 | 截断 | 未指定 | `lineLimit(1)` + `minimumScaleFactor(0.85)` | ⚠️ 394pt 下单列约 171pt，「每 100 字纠错」刚好放得下；缩放只是英文界面的保险 |
| 趋势「上周 2.1」 | — | 06B 不画 | 窄布局不渲染 | ✅ |
| 折叠断点 | — | README §2 建议窗口 < 720 | 本页按**自身宽度** < 700 折叠 | ⚠️ 这条带折叠与否取决于它自己有多少地方（4 个数 + 3 条线 + 190pt 柱区 ≈ 780），不取决于窗口；`DS.Size.narrowBreakpoint` 回答的是另一个问题 |

## 11 · 空值规则（06C）

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| ① 说出的字数 | 无数据时的值 | 印 **`0`**，不是「—」 | `Self.grouped(summary.wordsDictated)` → `"0"` | ✅ |
| ① 说出的字数 | 无数据时的色 | `rgba(28,28,30,.3)` | `hasData == false` → `ink(0.3)` | 🔧 原先 `.tertiary` ≈ 0.26 |
| ② 平均等待 | 无数据时 | 印 **`—`** | `latencyValue(nil)` → `"—"` | ✅ |
| ③ 回答耗时 | 无数据时 | 印 **`—`** | `latencyValue(nil)` → `"—"` | ✅ |
| ④ 每 100 字纠错 | 无数据时 | 印 **`—`** | `wordsDictated == 0` 时 `"—"`（`Summary` 这时把比率算成 0，印「0.0」会读成满分） | ✅ |
| ④ 每 100 字纠错 | 无数据时的色 | `rgba(28,28,30,.3)`，**不上 accent** | `valueStyle` 在 `!hasData` 时先返回 `ink(0.3)`，accent 不生效 | 🔧 原先 `.tertiary` |
| 四个标签 | 无数据时的色 | `rgba(28,28,30,.5)` | `ink(0.5)` | 🔧 原先 `.secondary` ≈ 0.50 |
| 交付次数 | 无数据时 | 「0 次交付」 | `summary.deliveries` = 0 | ✅ |
| 单位「秒」 | 无数据时 | 不画 | `unit` 为 `nil` | ✅ |

---

## Token gaps —— 五条全部关闭（2026-08-15）

1. **墨色刻度缺失（影响最大）** —— 已加 `DS.Colour.ink(_:)`：基色是字面 `#1C1C1E`，α 直接传稿子的值。做成函数而不是五个具名档，是因为六个屏幕合起来用了十三档（`.7 / .65 / .6 / .55 / .5 / .45 / .42 / .4 / .35 / .32 / .3 / .28 / .25`），给十三个档编角色名只会编出假语义。本页 8 处 🚩 已全部变 🔧。

   顺带修的一件事：`hairline` / `border` 原先写作 `Color.primary.opacity(α)`。`labelColor` 本身是黑 0.85，所以 `.opacity(0.07)` 解析成 0.0595 —— 稿子写的是 `rgba(0,0,0,.07)`。两个令牌都换成了 `Color.black.opacity(α)`。

2. **`DS.Colour.inset` 的值和稿件不符** —— 没有改 `inset` 的值，而是新加了 `DS.Colour.insetSurface` = 字面 `#FAFAF8`，本页免责条改用它。理由：`inset`（α 0.035）在浮层里是对的 —— §04 的工具块压在毛玻璃上，稿子那里写的就是 `rgba(0,0,0,.035)` 而不是十六进制；把它改成不透明色会让浮层那几处当场错掉。两个值各有各的位置，所以是两个令牌。

3. **`dsNote()`（11pt regular）仍在本文件里私有** —— 已删除，改用 `DS.Text.size(11)`。第二批给 `DS.Text` 加了通用的 `size(_:_:)`，稿子用到的 SF 字号（`10.5 / 11 / 11.5 / 12.5 / 13.5 / 14 / 15 medium`）都从它取，档位表写在该函数的文档注释里。

4. **`DS.Text` 没有 11.5pt** —— 关闭，见上。06B 的标签现在是 `DS.Text.size(11.5)`。

5. **`DS.Radius` 没有 7pt** —— 已加 `DS.Radius.iconButton` = 7（另有 `4 / 5 / 8 / 9 / 13 / 99`），`dsHeaderControl()` 改用它，边框同时换成 `DS.Colour.controlBorder` = 黑 0.09。

## 需要改其他文件（本次范围外，已上报）

- **`Sources/OpenType/SidebarShell.swift` · `ColumnHeader`** —— 它的 `HStack(spacing: 8)` 和稿件 3A 的 `gap: 14px` 不一致。本页用「内嵌一层 `HStack(spacing: 14)` 当唯一子视图」绕开了。会话页从另一头撞上了同一个组件：它的两个页头要 16/16 和 20/20、10/14 三种 gutter，`ColumnHeader` 写死 24/14，于是那边也自己开了一个私有的 `SessionColumnHeader`。两个屏幕各自绕开同一个组件，就是该改组件了 —— `ColumnHeader` 应当接 `leading` / `trailing` / `spacing`，两份私有拷贝随之删掉。属于 `SidebarShell.swift` 的活，不在本批范围内。

- **`DS.Space.rowH` = 13 只有会话页在用** —— 稿子里 听写 / 记忆 / 设置 / MCP 的卡内行 gutter 都是 14，只有会话页是 13。第二批加了 `DS.Space.rowHWide` = 14 并在文档注释里写明这是两个真实值，不是一个笔误。本页的行 gutter 用的是 `DS.Space.content` = 16（稿子 `13px 16px`），不受影响。
