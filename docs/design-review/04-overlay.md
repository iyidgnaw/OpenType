# 悬浮层 + 菜单栏 popover — 逐元素对照

**设计稿**：`design_handoff_opentype_redesign_v1/OpenType 重设计（单文件·离线）.html`，节 **04 · 悬浮层**（4A–4E）与节 **05 · 菜单栏 popover 300**。数值直接取自稿件的内联 CSS，不取 README 的散文（README 会四舍五入）。
**实现**：`Sources/OpenType/OverlayController.swift`、`Sources/OpenType/MenuBarPopoverView.swift`。
**日期**：2026-08-14。审查后这两个文件同批修改，✅ 表示改完之后相符。

状态记号：✅ 相符 · 🔧 本批修复 · ⚠️ 有意偏离（附理由）· 🚩 需要改本次范围外的文件（`DesignTokens.swift` / `Models.swift` / `AssistantMarkdownView.swift`），已上报

---

## 关于稿件字面值（本批全部还原）

**产品决策（2026-08-15）：稿子优先 —— 无条件还原设计稿。** 上一轮把稿件的字面 CSS 收进一套封闭令牌（12.5px → 13、7pt 圆角 → 6、六种边框 α → 一种），理由是「封闭刻度才拦得住十二档字号重新长回来」。产品否掉了这个理由：稿件写多少就是多少。下面第 1–4 条因此**全部反向还原**；`DesignTokens.swift` 本批补齐对应的字面档，本文件只引用令牌，不写裸字面。第 5、6 条不是令牌折叠，保持不变。

**1 · 墨色刻度。** 稿件的次要文字是 `rgba(28,28,30, α)` 显式墨色。§04/§05 用到 `.3 / .35 / .4 / .42 / .45 / .5 / .55 / .6` 八档，此前一律折进 SwiftUI 的 `.secondary`（≈ 黑 0.50）和 `.tertiary`（≈ 黑 0.26），`.4` 及以下整体偏浅。现在逐档还原。

**2 · 字号刻度。** 稿件 §00 把字号封闭成六档（20/700、15/600、13/400、12/400、11/600、11 mono），而 04/05 两节的行内 CSS 自己漏出了 `10.5 / 11.5 / 12.5 / 13.5` 四个档外值。现在这四档都是真令牌，逐行还原。mono 不需要新令牌 —— `DS.Text.mono(_ size:)` 本来就收字号参数，`10.5 / 11.5` 直接传进去。

**3 · 圆角刻度。** 稿件 §00 封闭成四档（6 控件 / 10 行 / 14 卡 / 18 浮层），04/05 又出现了 `5 / 8 / 9 / 13`。四个都还原。

**4 · 发丝线 α。** 稿件在这两节里用了 `.06 / .07 / .08 / .09` 四种黑。§04/§05 的分隔线一律是 `.07`，`dsHairline()` 原先画的是 `.06`；现在按稿走 `.07`，`.08`/`.09` 用在稿件真的写了这两个值的地方（进度条轨道、选项列表容器、步骤日志摘要、输入区、麦克风按钮）。

**5 · 面板材质与投影。** `rgba(250,250,248,.86)` + `backdrop-filter: blur(34px) saturate(180%)` → `.regularMaterial`；`box-shadow: 0 22px 60px rgba(0,0,0,.4)`（结果卡 `0 30px 80px rgba(0,0,0,.45)`）→ `NSPanel.hasShadow = true`。两条都是 README §悬浮层 明确指定的做法：SwiftUI 的 `.shadow` 会被 hosting view 的 bounds 裁掉，而 bounds 恰好止于面板边缘。全节不再逐行重复。

**6 · 图标。** 按 README「Assets」表把 Material Symbols 换成 SF Symbols。**稿件的 `font-size` px 直接当作 SF 的 point size**；字重取 `.medium`（Material 默认 400 的笔画粗细），只有 `checkmark` / `arrow.up` 这种裸笔画字形保留 `.semibold`，否则在小尺寸下比 Material 原稿细一档。

---

## 4A · 听音（`listeningContent`，420×132）

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| 面板 | width | `420px` | `VoiceSurfacePanelMetrics.pill.width` = 420 | ✅ |
| 面板 | radius | `18px` | `DS.Radius.panel` = 18 | ✅ |
| 面板 | border | `.75px rgba(255,255,255,.45)` | `.strokeBorder(.white.opacity(0.45), lineWidth: 0.75)` | ✅ |
| 面板 | padding | `14px 16px` | `.padding(.horizontal, 16)` + `.padding(.vertical, 14)` | ✅ |
| 面板 | gap | `11px` | `VStack(spacing: 11)` | ✅ |
| 头行 | gap / align | `9px` / `center` | `HStack(spacing: 9)`，默认 center | ✅ |
| 波形容器 | height | `16px` | `.frame(height: 16)` | 🔧 原先 18 |
| 波形容器 | width | 内容宽 = 5×2.5 + 4×3 = `24.5` | `.frame(width: 24.5)` | 🔧 原先 26 |
| 波形容器 | gap | `3px` | `HStack(spacing: 3)` | ✅ |
| 波形竖条 | width | `2.5px` | `.frame(width: 2.5)` | ✅ |
| 波形竖条 | height | `7 / 14 / 16 / 10 / 5` | `peaks = [7,14,16,10,5]`，按电平在 4…peak 之间插值 | 🔧 原式 `5 + level*22*weight` 在 level=1 时最高 **27pt**，把波形顶出自己 16pt 的行、压到旁边的模式标签上；`normalizedLevel` 把 −55…−10 dBFS 映到 0…1，日常说话就在 0.6 上下，早就越界了。改成以稿件的五个高度为满电平轮廓，天然封顶 16 |
| 波形竖条 | radius | `99px`（胶囊） | `Capsule()` | ✅ |
| 波形竖条 | color | `#0D73FA` | `DS.Colour.accent` | ✅ |
| 模式标签 | font | `11px / 600` | `DS.Text.groupLabel()` = 11pt semibold | ✅ |
| 模式标签 | padding | `2px 7px` | `.padding(.horizontal, 7)` + `.padding(.vertical, 2)` | ✅ |
| 模式标签 | radius | `5px` | `DS.Radius.tag` = 5 | 🔧 原先 `control` = 6 |
| 模式标签 | background | `rgba(13,115,250,.12)` | `fill.opacity(0.12)`，fill = accent | ✅ |
| 模式标签 | color | `#0A5CC8`（accent 压暗） | `DS.Colour.askTag` = `#0A5CC8` | 🔧 稿件只在**蓝色**标签上压暗文字，Agent 标签的 `#4B45E8` 不压暗 —— 所以 `ModeTag` 把填充色和文字色拆成了 `fill`/`tint` 两个入参 |
| 计时 | font | `11px` mono | `DS.Text.mono()` = 11pt monospaced | ✅ |
| 计时 | color | `rgba(28,28,30,.45)` | `DS.Colour.ink(0.45)` | 🔧 原先 `.secondary` |
| 计时 | 超时后 | 稿件没有 | 两分钟警告触发后转 `DS.Colour.warningText` | ⚠️ 新增（P2-10）。稿件只画了常态 |
| 「松开结束」 | font | `11px` mono | `DS.Text.mono()` | ✅ |
| 「松开结束」 | color | `rgba(28,28,30,.3)` | `DS.Colour.ink(0.3)` | 🔧 原先 `.tertiary` ≈ 0.26 |
| 字幕 | font-size / weight | `15px / 500` | `.system(size: 15, weight: .medium)` | ✅ |
| 字幕 | min-height | `38px` | `.frame(minHeight: 38)` | ✅ |
| 字幕 | line-height | `1.45` = 21.75 | SF 15pt 默认行高 ≈ 20，未加 `lineSpacing` | ⚠️ pill 是定高 132pt，字幕给的是两行的余量。补 3.6pt 行距后两行 43.5 > 预算 42，第二行会被裁。定高面板里行距不值这个风险 |
| 字幕 | letter-spacing | `-.005em` = −0.075pt @15 | 未设 | ⚠️ 小于 1/10 pt，不可见 |
| 字幕 | color | 继承 `#1C1C1E` | 有字幕 `.primary`，空态 `.secondary`（占位文案） | ✅ |
| 字幕 | 截断 | 未指定 | `lineLimit(2)` + `.head` | ⚠️ 实时字幕要留住**最新**的词，所以从头截 |
| Tab 提示行 | border-top | `.75px rgba(0,0,0,.07)` | `dsHairline(.top, color: DS.Colour.border)` (.07) | 🔧 原先画 `.06` |
| Tab 提示行 | padding-top | `9px` | `.padding(.top, 9)` | ✅ |
| Tab 提示行 | gap | `7px` | `HStack(spacing: 7)` | ✅ |
| 「Tab 切换到」 | font / color | `11px` mono / `rgba(28,28,30,.35)` | `DS.Text.mono()` / `DS.Colour.ink(0.35)` | 🔧 色原先 `.tertiary` |
| 模式小胶囊 | font | `11px` | `DS.Text.size(11)` | ✅ |
| 模式小胶囊 | padding | `2px 6px` | `.padding(.horizontal, 6)` + `.padding(.vertical, 2)` | ✅ |
| 模式小胶囊 | radius | `5px` | `DS.Radius.tag` = 5 | 🔧 原先 6 |
| 模式小胶囊 | background | `rgba(0,0,0,.05)` | `DS.Colour.control`（黑 .05） | 🔧 原先 `inset` = .035，中途走过 `ink(0.05)`（基色是 `#1C1C1E` 不是黑） |
| 模式小胶囊 | color | `rgba(28,28,30,.5)` | `DS.Colour.ink(0.5)` | 🔧 原先 `.secondary` |
| Tab 提示行 | 是否渲染 | 稿件恒有 | `modeSwitchHintAvailable` 为假时整行不渲染 | ⚠️ Space 和弦那几个 preset 没有 Tab 切换；宣传一个按下去没反应的键比不说更糟 |

## 4B · 执行中（`WorkingPill`，420×132）

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| 面板 | width / radius / border / padding / gap | 同 4A | 同 4A | ✅ |
| 呼吸点 | size / radius | `5px` / `50%` | `DS.Size.statusDot` = 5，`Circle()` | ✅ |
| 呼吸点 | color | `#4B45E8` | `DS.Colour.agent`（问答态取 accent） | ✅ |
| 呼吸点 | animation | `otPulse 1.4s ease-in-out infinite`：opacity 1→.35、scale 1→.82 | `.easeInOut(duration: 1.4).repeatForever(autoreverses: true)`，opacity 0.35、scale 0.82 | ✅ |
| 类型标签 | font / padding / radius | `11px / 600`、`2px 7px`、`5px` | `DS.Text.groupLabel()`、7/2、`DS.Radius.tag` = 5 | 🔧 圆角原先 6 |
| 类型标签 | bg / color | `rgba(75,69,232,.12)` / `#4B45E8` | `DS.Colour.agent.opacity(0.12)` / `DS.Colour.agent`（= 0.294,0.271,0.910 = `#4B45E8`） | ✅ |
| 步数 · 耗时 | font | `11px` mono | `DS.Text.mono()` | ✅ |
| 步数 · 耗时 | color | `rgba(28,28,30,.45)` | `DS.Colour.ink(0.45)` | 🔧 原先 `.secondary` |
| 步数 · 耗时 | 文案 | `第 6 / ~9 步 · 42s` | `第 6 步 · 42s` | ⚠️ `/agent/run` 只报已走的步，没有预估总数。README §悬浮层 对这种情况的指示就是「拿不到就只显示当前步号」 |
| 「停止」 | font | `11.5px / 500` | `DS.Text.size(11.5, .medium)` | 🔧 原先 12pt regular |
| 「停止」 | color | `#0D73FA` | `DS.Colour.accent` | ✅ |
| 任务原文 | font | `13px`，line-height `1.5` | `DS.Text.body()` = 13pt，未加 `lineSpacing` | ⚠️ 同 4A 字幕：定高 pill，两行余量吃紧 |
| 任务原文 | color | `rgba(28,28,30,.6)` | `DS.Colour.ink(0.6)` | 🔧 原先 `.secondary` |
| 任务原文 | 是否渲染 | 稿件恒有 | 实时字幕关掉时整行不渲染 | ⚠️ 与其填「（无字幕）」不如让工具块顶上来 |
| 工具块 | background | `rgba(0,0,0,.035)` | `DS.Colour.inset` = `primary.opacity(0.035)` | ✅ |
| 工具块 | radius | `9px` | `DS.Radius.nested` = 9 | 🔧 原先 10 |
| 工具块 | padding | `9px 11px` | `.padding(.horizontal, 11)` + `.padding(.vertical, 9)` | ✅ |
| 工具块 | gap | `6px` | `VStack(spacing: 6)` | 🔧 原先 7 |
| 工具块图标行 | gap | `8px` | `HStack(spacing: 8)` | ✅ |
| 工具图标 | icon | `build` → `wrench.and.screwdriver` | `wrench.and.screwdriver` | ✅ |
| 工具图标 | size | `14px` | `.system(size: 14, weight: .medium)` | 🔧 原先 12 |
| 工具图标 | color | `#4B45E8` | `DS.Colour.agent` | ✅ |
| 工具名 · 参数 | font | `11.5px` mono | `DS.Text.mono(11.5)` | 🔧 原先 `mono()` = 11。mono 本来就收字号参数，不需要新令牌 |
| 工具名 · 参数 | 截断 | `ellipsis`（尾） | `lineLimit(1)` + `.middle` | ⚠️ 这一行几乎总是路径或命令，尾截会把最有信息量的文件名截掉 |
| 进度条 | height / radius | `2px` / `99px` | `.frame(height: 2)`，`Capsule()` | ✅ |
| 进度条 | 轨道色 | `rgba(0,0,0,.08)` | `DS.Colour.borderStrong`（黑 .08） | 🔧 原先 `border` = .07 |
| 进度条 | 填充色 | `#0D73FA` | `DS.Colour.accent` | ✅ |
| 进度条 | 填充比例 | `64%`（确定进度） | 36% 宽的往复扫动（不定进度） | ⚠️ 与「第 N 步」同一个理由：没有分母。填一个 64% 是我们编的数，扫动只声称「在动」 |

## 4C · 已交付（`deliveryContent`，420×66/108/141）

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| 面板 | width | `420px` | `VoiceSurfacePanelMetrics.delivery(...)`.width = 420 | ✅ |
| 面板 | height | 内容高 | 66 + 有正文 42 + 有纠错行 33 | ⚠️ 面板定高，按实际内容算，避免文案缺席时留一条空材质 |
| 面板 | padding | `14px 16px` | 16/14 | ✅ |
| 面板 | gap | `10px` | `VStack(spacing: 10)` | ✅ |
| 头行 | gap | `9px` | `HStack(spacing: 9)` | ✅ |
| 对勾 | icon | `check` → `checkmark` | `checkmark` | ✅ |
| 对勾 | size | `16px` | `.system(size: 16, weight: .semibold)` | 🔧 原先 15 |
| 对勾 | color | `rgba(28,28,30,.55)` | `DS.Colour.ink(0.55)` | 🔧 原先 `.secondary`。中性而非绿色 —— §00「"完成"不再是绿色」 |
| 「已写入 Notes」 | font | `13px / 600` | `DS.Text.body(.semibold)` | ✅ |
| 「已写入 Notes」 | color | 继承 | `.primary` | ✅ |
| 「已写入 Notes」 | 文案 | 落地位置 | `deliveryTargetApp` 有值取应用名，否则「已写入当前输入框」；仅剪贴板时「已复制」 | ✅ |
| 「也已复制」 | font / color | `11px` mono / `rgba(28,28,30,.35)` | `DS.Text.mono()` / `DS.Colour.ink(0.35)` | 🔧 色原先 `.tertiary` |
| 正文 | font | `12.5px` | `DS.Text.size(12.5)` | 🔧 原先 12 |
| 正文 | line-height | `1.55` | `.lineSpacing(4)` | 🔧 原先无 |
| 正文 | color | `rgba(28,28,30,.55)` | `DS.Colour.ink(0.55)` | 🔧 原先 `.secondary` |
| 合并行 | border-top | `.75px rgba(0,0,0,.07)` | `dsHairline(.top, color: DS.Colour.border)` (.07) | 🔧 原先 .06 |
| 合并行 | padding-top / gap | `9px` / `9px` | `.padding(.top, 9)` / `HStack(spacing: 9)` | ✅ |
| 倒计时条 | flex / height / radius | `flex:1` / `2px` / `99px` | `GeometryReader` 吃剩余宽（提示文字 `layoutPriority(1)`），高 2，`Capsule()` | ✅ |
| 倒计时条 | 轨道 / 填充 | `rgba(0,0,0,.08)` / `#0D73FA` | `DS.Colour.borderStrong` / `DS.Colour.accent` | 🔧 轨道原先 `border` = .07 |
| 倒计时条 | 动画 | 静态 62% | 一条 `.linear(duration: seconds)` 从 1 走到 0，`.id(startedAt)` 保证重新武装时从满格重来 | ✅ 稿件是静帧 |
| 提示文字 | font / color | `11px` mono / `rgba(28,28,30,.45)` | `DS.Text.mono()` / `DS.Colour.ink(0.45)` | 🔧 色原先 `.secondary` |
| 提示文字 | 文案 | 「再按 ⌥ 可口述修改」 | 「选中说错的词，再按一次快捷键即可纠正」 | ⚠️ **按指示保留**。已发布的手势要求先选中文本，`CorrectionWindowTests` 钉住了「选中」「再按一次」两个词。稿件描述的是一个比现有实现更简单的功能 |

## 4D · 反问（`AgentQuestionCard`，420×(160 + 36n)）

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| 面板 | width | `420px` | `VoiceSurfacePanelMetrics.asking(...)`.width = 420 | ✅ |
| 面板 | padding / gap | `14px 16px` / `11px` | 16/14 / `VStack(spacing: 11)` | ✅ |
| 头行 | gap | `9px` | `HStack(spacing: 9)` | ✅ |
| Agent 标签 | 同 4B | 同 4B | 同 4B | ✅ |
| 「需要你选一下」 | font | `13px / 600` | `DS.Text.body(.semibold)` | ✅ |
| 「需要你选一下」 | flex | `flex:1` | 后接 `Spacer(minLength: 4)` | ✅ 等效 |
| 「停止」 | font | `11.5px / 500` | `DS.Text.size(11.5, .medium)` | 🔧 原先 12pt regular |
| 「停止」 | color | `rgba(28,28,30,.45)` | `DS.Colour.ink(0.45)` | 🔧 原先 `.secondary`。注意：4D 的停止是灰的，4B 的是蓝的，两处实现一致 |
| 问题正文 | font | `13.5px` | `DS.Text.size(13.5)` | 🔧 原先 13 |
| 问题正文 | line-height | `1.55` | `.lineSpacing(4)` | 🔧 原先无 |
| 问题正文 | color | 继承 | `.primary` | ✅ |
| 选项列表容器 | border | `.75px rgba(0,0,0,.09)` | `DS.Colour.controlBorder`（黑 .09） | 🔧 原先 `border` = .07 |
| 选项列表容器 | radius | `10px` | `DS.Radius.inset` = 10 | ✅ |
| 选项列表容器 | background | `rgba(255,255,255,.6)` | `DS.Colour.card.opacity(0.6)` | ✅ |
| 选项列表容器 | overflow | `hidden` | 行内容不越界（定高行 + 圆角背景） | ✅ |
| 选项行 | padding | `10px 12px` | `.padding(.horizontal, 12)` + `.frame(height: 36)` | ✅ 10+14+10 ≈ 36，且 36 与 `asking(optionCount:)` 的每行预算同源 |
| 选项行 | gap | `10px` | `HStack(spacing: 10)` | ✅ |
| 选项行分隔线 | border-top | `.75px rgba(0,0,0,.07)` | `Rectangle().fill(DS.Colour.border)`，0.75pt，仅 index>0 | 🔧 原先 `hairline` = .06 |
| 选项名 | font | `12px` mono | `DS.Text.mono(12)` | ✅ |
| 选项名 | flex / 截断 | `flex:1` | `.frame(maxWidth: .infinity, alignment: .leading)` + `.middle` | ✅ |
| 选项元信息 | font / color | `11px` mono / `rgba(28,28,30,.4)` | `DS.Text.mono()` / `DS.Colour.ink(0.4)` | 🔧 色原先 `.secondary` |
| 编号 | font | `11px` mono | `DS.Text.mono()` | ✅ |
| 编号 | color | `rgba(28,28,30,.3)` | `DS.Colour.ink(0.3)` | 🔧 原先 `.tertiary` |
| 编号 | 形态 | 纯 mono 数字，不是徽章 | 纯 `Text("\(number)")` | ✅ |
| 数字键 | 行为 | 「支持数字键选择」 | 仅 **local** monitor，1…9，带修饰键的忽略 | ⚠️ **按指示保留 local**。global monitor 会让别的 app 里敲的一个「1」替用户回答 Agent，而 Agent 拿着这个答案去调工具 |
| 底部麦克风行 | background | `rgba(0,0,0,.035)` | `DS.Colour.inset` | ✅ |
| 底部麦克风行 | radius | `10px` | `DS.Radius.inset` = 10 | ✅ |
| 底部麦克风行 | padding / gap | `9px 11px` / `9px` | 11/9 / `HStack(spacing: 9)` | ✅ |
| 麦克风图标 | icon | `mic`（filled）→ `mic.fill` | `mic.fill` | ✅ |
| 麦克风图标 | size | `15px` | `.system(size: 15, weight: .medium)` | 🔧 原先 14 |
| 麦克风图标 | color | `#0D73FA` | `DS.Colour.accent` | ✅ |
| 提示文案 | font | `12.5px` | `DS.Text.size(12.5)` | 🔧 原先 12 |
| 提示文案 | color | `rgba(28,28,30,.4)` | 系统 placeholder 色 | ⚠️ 稿件是死文字，实现是 `TextField` 的占位符 —— 这样「说点别的」不用再加一个控件。占位色由 `.plain` 样式给 |

## 4E · 结果卡（`VoiceSurfaceCard`，640×520）

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| 卡 | width × height | `640 × 520` | `VoiceSurfacePanelMetrics.card` | ✅ |
| 卡 | radius | `18px` | `DS.Radius.panel` | ✅ |
| 卡 | background | `rgba(250,250,248,.9)` | `.regularMaterial` | ⚠️ 见系统性偏离 5（4A–4D 是 `.86`，卡是 `.9`；材质不分档） |
| 卡 | overflow | `hidden` | 三段定位 + `ScrollView` 夹在中间 | ✅ |
| 头部 | flex / padding / gap | `none` / `14px 18px` / `10px` | `.padding(.horizontal, 18)` + `.padding(.vertical, 14)`，`HStack(spacing: 10)` | ✅ |
| 头部 | border-bottom | `.75px rgba(0,0,0,.07)` | `dsHairline(.bottom, color: DS.Colour.border)` (.07) | 🔧 原先 .06 |
| 类型标签 | 同 4B | 同 4B | 同 4B | ✅ |
| 「完成」 | font | `13px / 600` | `DS.Text.body(.semibold)` | ✅ |
| 「完成」 | color | 继承（失败态稿件未画） | `.primary`；失败时 `DS.Colour.error` | ⚠️ 失败态是稿件没画的第六个状态 |
| 「9 步 · 24.1s」 | font / color | `11px` mono / `rgba(28,28,30,.35)` | `DS.Text.mono()` / `DS.Colour.ink(0.35)` | 🔧 色原先 `.tertiary` |
| 「9 步 · 24.1s」 | 取值 | 静帧 | 步数取 `card.steps.count`，耗时在卡出现的那一刻冻结 | ✅ 一直走的秒表量的是用户读卡的时间，不是这次运行 |
| 打开主窗口 | icon | `open_in_new` → `arrow.up.forward.app` | `arrow.up.forward.app` | ✅ |
| 打开主窗口 | size | `17px` | `.system(size: 17, weight: .medium)` | 🔧 原先 15 |
| 打开主窗口 | color | `rgba(28,28,30,.4)` | `DS.Colour.ink(0.4)` | 🔧 原先 `.secondary` |
| 关闭 | icon / size / color | `close` → `xmark` / `17px` / `rgba(28,28,30,.4)` | `xmark` / 17 / `DS.Colour.ink(0.4)` | 🔧 原先 15pt `.secondary` |
| 两个图标按钮 | 命中区 | 稿件是裸 span | `.frame(width: 22, height: 22)` + `contentShape` | ⚠️ 17pt 的字形不是一个能点的目标 |
| 内容区 | flex / padding / gap | `1` / `16px 18px` / `14px` | `.padding(.horizontal, 18)` + `.padding(.vertical, 16)`，`VStack(spacing: 14)` | ✅ |
| 内容区 | overflow | `hidden` | `ScrollView` + `.scrollIndicators(.visible)` | ⚠️ 稿件按刚好装下画；真答案会更长 |
| 用户气泡 | max-width | `78%` | `(640 − 18×2 − 4) × 0.78` = 468 | 🔧 原先 `Spacer(minLength: 40)`，实际上限 ≈ 93% |
| 用户气泡 | padding | `9px 13px` | `.padding(.horizontal, 13)` + `.padding(.vertical, 9)` | ✅ |
| 用户气泡 | radius | `13px 13px 4px 13px` | `UserBubbleShape`：三角 `DS.Radius.sheet` = 13，右下 4 | 🔧 原先取 `card` = 14 |
| 用户气泡 | background / color | `#0D73FA` / `#fff` | `DS.Colour.accent` / `.white` | ✅ |
| 用户气泡 | font | `12.5px` | `DS.Text.size(12.5)` | 🔧 原先 13，中途落到 12，现按稿 12.5 |
| 用户气泡 | line-height | `1.55` | `.lineSpacing(4)` | 🔧 原先无 |
| 用户气泡 | 对齐 | `justify-content:flex-end` | `HStack(spacing: 0) { Spacer(minLength: 0); … }` | ✅ 与 `SessionsViews.SessionTurn` 同一写法 |
| 步骤日志摘要 | border | `.75px rgba(0,0,0,.08)` | `DS.Colour.borderStrong` | 🔧 原先 `border` = .07 |
| 步骤日志摘要 | radius | `9px` | `DS.Radius.nested` = 9 | 🔧 原先 10 |
| 步骤日志摘要 | background | `rgba(255,255,255,.5)` | `DS.Colour.card.opacity(0.5)` | 🔧 原先 `DS.Colour.inset`（黑 .035）—— 稿件这一行是**抬起**的白，不是凹陷的灰 |
| 步骤日志摘要 | padding / gap | `7px 11px` / `8px` | 11/7 / `HStack(spacing: 8)` | ✅ |
| 折叠箭头 | icon | `chevron_right` → `chevron.right` | `chevron.right` / 展开时 `chevron.down` | ✅ |
| 折叠箭头 | size | `14px` | `.system(size: 14, weight: .medium)` | 🔧 原先 11pt semibold |
| 折叠箭头 | color | `rgba(28,28,30,.4)` | `DS.Colour.ink(0.4)` | 🔧 原先 `.tertiary` |
| 「执行了 9 步」 | font | `12px / 600` | `DS.Text.caption()` + `.fontWeight(.semibold)` | ✅ |
| 「执行了 9 步」 | color | `rgba(28,28,30,.55)` | `DS.Colour.ink(0.55)` | 🔧 原先 `.secondary` |
| 工具名列表 | font / color | `11px` mono / `rgba(28,28,30,.35)` | `DS.Text.mono()` / `DS.Colour.ink(0.35)` | 🔧 色原先 `.tertiary` |
| 工具名列表 | 内容 | `bash · python · open_file` | 去重后前 4 个，`·` 连接 | ✅ |
| 展开后的步骤表 | — | 稿件没画 | 序号 mono / 工具名 mono agent 色 / 参数 mono `.secondary` | ⚠️ 新增。稿件只画了收起态，但折叠得有个展开 |
| 正文 | font | `13.5px` | `AssistantMarkdownView(fontSize: 13.5)` | 🔧 原先 13。`fontSize` 是 `CGFloat`，调用点在本文件内 |
| 正文 | line-height | `1.75` | 由 `AssistantMarkdownView` 决定 | 🚩 范围外文件（字号已在调用点给到 13.5，行高在渲染器内部） |
| 正文 · 小标题 | font | `15px / 600`，`margin-bottom:8px` | 由 `AssistantMarkdownView` 决定 | 🚩 范围外文件 |
| 正文 · `code` | `12.5px` mono，`rgba(0,0,0,.045)` 底，`1.5px 5px`，radius `4px` | 同上 | 🚩 范围外文件 |
| 结构化产出块 | border / radius / 行 padding / 行分隔 / 文件名 `12px` mono / 尺寸 `11.5px` mono `rgba(28,28,30,.4)` | `.75px rgba(0,0,0,.08)` / `9px` / `7px 12px` / `.06` | **未实现** | 🚩 `VoiceSurfaceState.ResultCard` 只有 `kind/query/body/steps`，没有结构化产出这个字段；渲染成带边框的行组要么在 `AssistantMarkdownView` 里认表格，要么给 `ResultCard` 加字段 —— 两个都在范围外 |
| 页脚 | flex / padding | `none` / `12px 18px 16px` | `.padding(.horizontal, 18)` + `.padding(.top, 12)` + `.padding(.bottom, 16)` | ✅ |
| 页脚 | border-top | `.75px rgba(0,0,0,.07)` | `dsHairline(.top, color: DS.Colour.border)` (.07) | 🔧 原先 .06 |
| 页脚 | gap | `10px` | `VStack(spacing: 10)` | ✅ |
| 动作行 | gap | `7px` | `HStack(spacing: 7)` | ✅ |
| 动作 chip | height | `24px` | `.frame(height: 24)` | ✅ |
| 动作 chip | padding-x | `10px` | `.padding(.horizontal, 10)` | ✅ |
| 动作 chip | radius | `6px` | `DS.Radius.control` = 6 | ✅ |
| 动作 chip | background | `rgba(0,0,0,.05)` | `DS.Colour.control` | 🔧 原先 `inset` = .035 |
| 动作 chip | font | `11.5px` | `DS.Text.size(11.5)` | 🔧 原先 12 |
| 动作 chip | color | `rgba(28,28,30,.6)` | `DS.Colour.ink(0.6)` | 🔧 原先 `.secondary` |
| 动作 chip | 内容 | 按结果类型给具体动作 | 有产出文件 → 打开 X / 复制路径；否则 → 展开说说 / 换个说法（`VoiceResultActions`） | ✅ |
| 「复制」 | — | 稿件没有 | 动作行右端 | ⚠️ 新增。稿件的三个动作里「复制路径」只在有文件时出现，答案类结果就没有任何复制入口了 |
| 输入区 | background | `rgba(255,255,255,.7)` | `DS.Colour.card.opacity(0.7)` | ✅ |
| 输入区 | border | `.75px rgba(0,0,0,.09)` | `DS.Colour.controlBorder` | 🔧 原先 `border` = .07 |
| 输入区 | radius | `13px` | `DS.Radius.sheet` = 13 | 🔧 原先 `card` = 14 |
| 输入区 | padding | `9px 9px 9px 13px` | `.padding(.leading, 13)` + `.padding(.trailing, 9)` + `.padding(.vertical, 9)` | ✅ |
| 输入区 | gap / align | `9px` / `flex-end` | `HStack(alignment: .bottom, spacing: 9)` | ✅ |
| 占位文案 | font | `13px` | `DS.Text.body()` = 13pt | ✅ |
| 占位文案 | color | `rgba(28,28,30,.35)` | 系统 placeholder 色 | ⚠️ 同 4D |
| 占位文案 | padding-bottom | `5px` | `.padding(.bottom, 5)` | 🔧 原先 4 |
| 麦克风按钮 | size | `28 × 28` | `.frame(width: 28, height: 28)` | ✅ |
| 麦克风按钮 | radius | `8px` | `DS.Radius.block` = 8 | 🔧 原先 10 |
| 麦克风按钮 | background | `#fff` | `DS.Colour.card` | ✅ |
| 麦克风按钮 | border | `.75px rgba(0,0,0,.09)` | `DS.Colour.controlBorder` | 🔧 原先 `border` = .07 |
| 麦克风按钮 | shadow | `0 1px 1.5px rgba(0,0,0,.05)` | `DS.Shadow.control`（黑 .05 / radius 0.75 / y 1） | ✅ CSS 的 blur 1.5px ≈ SwiftUI 的 radius 0.75，这个令牌就是这条投影 |
| 麦克风图标 | icon / size / color | `mic`（filled）→ `mic.fill` / `15px` / `#0D73FA` | `mic.fill` / 15 / `DS.Colour.accent` | 🔧 原先 14 |
| 送出按钮 | size / radius | `28 × 28` / `8px` | 28×28 / `DS.Radius.block` = 8 | 🔧 原先 10 |
| 送出按钮 | background | `#0D73FA` | `DS.Colour.accent`（草稿为空时 `.opacity(0.35)`） | ⚠️ 空态是稿件没画的；一个永远满色的送出键会让人以为按了有用 |
| 送出按钮 | shadow | `0 1px 2px rgba(13,115,250,.3)` | `DS.Shadow.accentControl` | 🔧 原先无投影 |
| 送出图标 | icon / size / color | `arrow_upward` → `arrow.up` / `15px` / `#fff` | `arrow.up` / 15 semibold / `.white` | 🔧 原先 14 |

### 4E 之外：稿件没画、实现里有的两个面板态

| 面板态 | 说明 |
|---|---|
| `compactContent`（420×66） | 模式切换 / 失败 / 取消的一行式 toast。§04 只列了五态，这三个 toast 没有对应稿件；沿用同一材质、圆角、内边距 |
| `pendingDispatchContent`（420×96） | 下发前 1.5s 的确认窗（P1-6），同样早于本次改稿。倒计时条与 4C 共用 `WindowCountdownBar` |

---

## 05 · 菜单栏 popover（`MenuBarPopoverView`，300pt）

| 元素 | 属性 | 设计 | 实现 | 状态 |
|---|---|---|---|---|
| popover | width | `300px` | `.frame(width: 300)`，`configurePopover()` 的 `contentSize` 同步 | ✅ |
| popover | background | `rgba(250,250,248,.94)` | `DS.Colour.insetSurface` = `#FAFAF8` | 🔧 两轮：先从 `.windowBackgroundColor`（浅色下 `#ECECEC`）改到 `canvas`，现在按稿走 `#FAFAF8` |
| popover | radius / shadow / border | `12px` / `0 20px 60px rgba(0,0,0,.24), 0 1px 3px rgba(0,0,0,.14)` / `.75px rgba(0,0,0,.08)` | 由 `NSPopover` 自绘 | ⚠️ popover 的外框是系统的，画不进内容视图 |
| popover | overflow | `hidden` | 同上 | ⚠️ |
| 头部 | padding | `12px 14px 10px` | `.padding(.horizontal, 14)` + `.top 12` + `.bottom 10` | ✅ |
| 头部 | gap | `9px` | `HStack(spacing: 9)` | ✅ |
| 品牌方块 | size | `20 × 20` | `.frame(width: 20, height: 20)` | ✅ |
| 品牌方块 | radius | `6px` | `DS.Radius.control` = 6 | ✅ |
| 品牌方块 | background | `linear-gradient(135deg,#0D73FA,#5751FA)` | `LinearGradient([DS.Colour.accent, DS.Colour.brandGradientEnd], .topLeading → .bottomTrailing)` | 🔧 端点原先是行内 `Color(0.341,0.318,0.980)`，令牌已有名字 |
| 品牌图标 | icon / size / color | `graphic_eq` → `waveform` / `12px` / `#fff` | `waveform` / 12 semibold / `.white` | ✅ |
| 「OpenType」 | font | `13px / 600` | `DS.Text.body(.semibold)` | ✅ |
| 右上图标 | icon | `settings`（齿轮） | `slider.horizontal.3` | ⚠️ README 的对照表没有 `settings` 一行。这个按钮打开的是**主窗口**（会话 / 听写 / 记忆 / 设置），不是设置页；画个齿轮会误导。`slider.horizontal.3` 与侧边栏「设置」同字形，语义上是「OpenType 的控制面」 |
| 右上图标 | size | `16px` | `.system(size: 16, weight: .medium)` | 🔧 原先 14 |
| 右上图标 | color | `rgba(28,28,30,.4)` | `DS.Colour.ink(0.4)` | 🔧 原先 `.secondary` |
| 模式行 | padding | `0 10px 10px` | `.padding(.horizontal, 10)` + `.padding(.bottom, 10)` | ✅ |
| 模式行 | gap | `4px` | `HStack(spacing: 4)` | ✅ |
| 模式格 | flex / height | `flex:1` / `52px` | `.frame(maxWidth: .infinity)` + `.frame(height: 52)` | ✅ |
| 模式格 | radius | `9px` | `DS.Radius.nested` = 9 | 🔧 原先 10 |
| 模式格 | gap | `3px` | `VStack(spacing: 3)` | ✅ |
| 模式格（选中） | background / color | `#0D73FA` / `#fff` | `DS.Colour.accent` / `.white` | ✅ |
| 模式格（未选） | background | `rgba(0,0,0,.045)` | `DS.Colour.codeFill`（黑 .045） | 🔧 原先 `inset` = .035。令牌名说的是行内代码底，值是这一档唯一的黑 |
| 模式格（未选） | color | `rgba(28,28,30,.6)` | `DS.Colour.ink(0.6)` | 🔧 原先 `.secondary` |
| 模式图标 | icon | `mic`(filled) / `contact_support` / `auto_awesome` → `mic.fill` / `questionmark.bubble.fill` / `wand.and.stars` | `InputMode.symbol`，三个完全一致 | ✅ |
| 模式图标 | size | `17px` | `.system(size: 17, weight: .medium)` | ✅ |
| 模式名 | font | 选中 `11px / 600`、未选 `11px / 500` | `.system(size: 11, weight: isSelected ? .semibold : .medium)` | ✅ |
| 状态行 | padding | `9px 14px` | 14/9 | ✅ |
| 状态行 | border-top | `.75px rgba(0,0,0,.07)` | `dsHairline(.top, color: DS.Colour.border)` (.07) | 🔧 原先 .06 |
| 状态行 | gap | `8px` | `HStack(spacing: 8)` | ✅ |
| 状态文案 | font | `11px` mono | `DS.Text.mono()` | ✅ |
| 状态文案 | color | `rgba(28,28,30,.45)` | `DS.Colour.ink(0.45)` | 🔧 原先 `.secondary` |
| 状态文案 | 内容 | 「按住 ⌥ 说话 · Tab 切换」 | 取自装好的 preset（`hotKeyPreset.modeSwitchHint`） | ✅ 给 fn 用户写「按住 ⌥」是文案版的同一个 bug |
| 状态点 | size / radius / color | `5px` / `50%` / `#34A853` | `DS.Size.statusDot` = 5，`Circle()`，`DS.Colour.ok` (= 0.204,0.659,0.325 = `#34A853`) | ✅ |
| 状态行（异常态） | — | 稿件没画 | 文案换成 `sidecarStatusText`，点转 `DS.Colour.warning`，右侧多一个「重启服务」 | ⚠️ 新增 |
| 进行中块 | padding | `10px 14px` | 14/10 | ✅ |
| 进行中块 | border-top | `.75px rgba(0,0,0,.07)` | `dsHairline(.top, color: DS.Colour.border)` (.07) | 🔧 原先 .06 |
| 进行中块 | background | `rgba(13,115,250,.05)` | `DS.Colour.accent.opacity(0.05)` | ✅ |
| 进行中块 | gap | `9px` | `VStack(spacing: 9)` | ✅ |
| 进行中 · 首行 | gap | `7px` | `HStack(spacing: 7)` | ✅ |
| 进行中 · 呼吸点 | size / color / 动画 | `5px` / `#0D73FA` / `otPulse 1.4s` | 5 / `DS.Colour.accent` / 与浮层同一条 1.4s 呼吸 | ✅ |
| 「进行中」 | font | `11px / 600`，`letter-spacing:.05em` | `DS.Text.groupLabel()` + `DS.Tracking.groupLabel` = 0.55 | ✅ |
| 「进行中」 | color | `rgba(28,28,30,.45)` | `DS.Colour.ink(0.45)` | 🔧 原先 `.tertiary` ≈ 0.26。注意 §05 的分组标签有两个值：「进行中」是 `.45`，「最近」是 `.42` |
| 进行中 · 耗时 | font | `10.5px` mono | `DS.Text.mono(10.5)` | 🔧 原先 11 |
| 进行中 · 耗时 | color | `rgba(28,28,30,.4)` | `DS.Colour.ink(0.4)` | 🔧 原先 `.tertiary` |
| 进行中 · 耗时 | 取值 | 静帧 `42s` | `TimelineView(.periodic(by: 1))` 从 `dispatchedAt` 起算 | ✅ |
| 进行中 · 任务名 | font | `12.5px`，line-height `1.5` | `DS.Text.size(12.5)` | 🔧 原先 13。行高对单行无意义（`lineLimit(1)`） |
| 进行中 · 任务名 | 截断 | `ellipsis`（尾） | `lineLimit(1)` + `.tail` | ✅ |
| 进行中 · 工具行 | font | `10.5px` mono | `DS.Text.mono(10.5)` | 🔧 原先 11 |
| 进行中 · 工具行 | color | `rgba(28,28,30,.45)` | `DS.Colour.ink(0.45)` | 🔧 原先 `.secondary` |
| 进行中 · 工具行 | 截断 | `ellipsis`（尾） | `lineLimit(1)` + `.middle` | ⚠️ 同 4B：这一行是命令，尾截会截掉文件名 |
| 进行中 · 工具行 | 内容 | `bash · pandoc 季度复盘.md` | `AgentToolLine.parse` 解出的 `工具 · 摘要`，与浮层同一个解析 | ✅ |
| 最近区 | padding | `8px 0 4px` | `.padding(.top, 8)` + `.padding(.bottom, 4)` | ✅ |
| 最近区 | border-top | `.75px rgba(0,0,0,.07)` | `dsHairline(.top, color: DS.Colour.border)` (.07) | 🔧 原先 .06 |
| 「最近」 | padding | `0 14px 6px` | `.padding(.horizontal, 14)` + `.padding(.bottom, 6)` | ✅ |
| 「最近」 | font | `11px / 600`，`letter-spacing:.05em` | `DS.Text.groupLabel()` + tracking | ✅ |
| 「最近」 | color | `rgba(28,28,30,.42)` | `DS.Colour.ink(0.42)` | 🔧 原先 `.tertiary` |
| 会话行 | padding / gap | `6px 14px` / `8px` | 14/6 / `HStack(spacing: 8)` | ✅ |
| 会话行 · 色点 | size / color | `5px` / `#0D73FA`（问答）、`#4B45E8`（Agent） | 5 / `DS.Colour.accent`、`DS.Colour.agent` | ✅ |
| 会话行 · 标题 | font | `12.5px` | `DS.Text.size(12.5)` | 🔧 原先 13 |
| 会话行 · 标题 | 截断 | `ellipsis` | `lineLimit(1)` + `.tail` | ✅ |
| 会话行 · 时间 | font | `10.5px` mono | `DS.Text.mono(10.5)` | 🔧 原先 11 |
| 会话行 · 时间 | color | `rgba(28,28,30,.35)` | `DS.Colour.ink(0.35)` | 🔧 原先 `.tertiary` |
| 会话行 · 时间 | 格式 | `13:20` / `昨天` | `MenuBarSessionTime`：当天 `HH:mm`、昨天「昨天」、更早 `MM-dd` | ✅ |
| 会话行 | 条数 | 2 | `sessionConversations.prefix(2)` | ✅ |
| 页脚 | padding | `9px 14px` | 14/9 | ✅ |
| 页脚 | border-top | `.75px rgba(0,0,0,.07)` | `dsHairline(.top, color: DS.Colour.border)` (.07) | 🔧 原先 .06 |
| 页脚 | gap | `8px` | `HStack(spacing: 8)` | ✅ |
| 「打开主窗口」 | font | `12.5px` | `DS.Text.size(12.5)` | 🔧 原先 13 |
| 「打开主窗口」 | color | `rgba(28,28,30,.5)` | `DS.Colour.ink(0.5)`，加在整行上 | 🔧 原先 `.secondary` |
| 「⌘O」 | font | `11px` mono | `DS.Text.mono()` | ✅ |
| 「⌘O」 | color | `rgba(28,28,30,.5)` | 继承整行的 `DS.Colour.ink(0.5)` | 🔧 原先 `.tertiary`。稿件把颜色写在行上，两个 run 同色 |
| 「⌘O」 | 是否真的绑定 | 稿件只是文字 | `.keyboardShortcut("o", modifiers: .command)` | ✅ |
| 「退出 OpenType」行 | — | 稿件没有 | `power` 11pt + 12.5pt 文案，`ink(0.5)`，同样的 14/9 padding 和 .07 发丝线 | ⚠️ 新增。主窗口关着时 app 是 `.accessory`，没有 Dock 图标也没有 app 菜单，菜单栏是唯一能退出的地方。稿件没画，所以照抄它紧邻的「打开主窗口」行 |
| AI 模型提示条 | — | 稿件没有 | 选了问答/Agent 但没配 LLM 时插在模式行下方，`DS.Colour.warningFill` 底 | ⚠️ 新增。否则这两个模式会静默失败 |

---

## §04/§05 需要的字面档（`DesignTokens.swift` 本批补，本文件只引用）

还原稿件字面值之后，这两节用到的、原先没有令牌的值。逐条都是从 `OpenType 重设计.dc.html`
第 693–925 行的行内 CSS 读出来的，不是从 README 的散文推的。

1. **墨色刻度。** `rgba(28,28,30, α)`，§04/§05 用到 `.3 / .35 / .4 / .42 / .45 / .5 / .55 / .6` 八档。原先只有 `.secondary`（≈ .50）和 `.tertiary`（≈ .26）两档可用，`.4` 及以下全部偏浅。与 `03-dictation.md` 第 1 条、`07-mcp.md` 是同一套刻度，六个屏幕共用，必须一批改一批验。→ `DS.Colour.ink(_:)`。
2. **发丝线 α。** §04/§05 的分隔线一律 `.07`，而 `dsHairline()` 画的是 `.06`。`dsHairline` 现在收颜色参数，`.06` 留给稿件真的写 `.06` 的地方；另需 `.08`（4B 进度条轨道、4C 倒计时轨道、4E 步骤日志摘要边框）和 `.09`（4D 选项列表容器、4E 输入区与麦克风按钮边框）。→ `border` / `borderStrong` / `controlBorder`。**这三档和下面两档都是纯黑**：`ink(α)` 的基色是 `#1C1C1E`，拿它画稿件写的 `rgba(0,0,0,α)` 会浅半档，本批把这类调用点全部换成黑基令牌。
3. **黑色浅填充两档。** `rgba(0,0,0,.045)`（05 未选中模式格）与 `rgba(0,0,0,.05)`（4A Tab 提示小胶囊、4E 动作 chip）。`DS.Colour.inset` 的 `.035` 仍然正确 —— 4B 工具块和 4D 麦克风行稿件就写 `.035` —— 所以是**新增两档，不是改 `inset`**。→ `codeFill` / `control`。两个令牌的文档注释说的是别的调用者（行内代码底、未选中 chip），值是对的；改名不值得为此单开一轮。
4. **`#FAFAF8` 面色。** popover 的 `rgba(250,250,248,.94)`。浮层走 `.regularMaterial` 绕过去了，popover 没有材质可走，原先只能借 `canvas`（`#F5F5F3`）。
5. **`#0A5CC8`。** 蓝色标签上的文字色，比 accent 暗一档。稿件只在**蓝色**标签上压暗（Agent 标签的 `#4B45E8` 不压暗），所以 `ModeTag` 需要把填充色和文字色拆成两个入参。
6. **accent 色的控件投影。** 4E 送出键的 `0 1px 2px rgba(13,115,250,.3)`。`DS.Shadow` 只有中性的 `control` 和 α .10/radius 4 的 `running`。
7. **字号档 10.5 / 11.5 / 12.5 / 13.5（SF）。** mono 不在此列 —— `DS.Text.mono(_ size:)` 本来就收字号参数。
8. **圆角档 5 / 8 / 9 / 13。**

## 范围外需要别人动的

1. **`AssistantMarkdownView.swift`** — 4E 正文的 `line-height:1.75`、`已完成` 小标题 `15px/600 + margin-bottom:8px`、行内 `code` 的 `12.5px mono / rgba(0,0,0,.045) / 1.5px 5px / radius 4px`。字号本身已经能在调用点给（本批已改成 `fontSize: 13.5`），剩下三项在渲染器内部。
2. **`Models.swift` 或 `AssistantMarkdownView.swift`** — 4E 的**结构化产出块**（带边框的文件行组）完全没有实现。`VoiceSurfaceState.ResultCard` 没有承载它的字段，Markdown 渲染器也不认表格。二选一：给 `ResultCard` 加一个结构化产出字段，或让 Markdown 渲染器把表格画成这个行组。

## 没有动的行为（按指示）

1. 面板只有 **420 / 640** 两档，`VoiceSurfacePanelMetrics` 是唯一的表，`VoiceSurfacePanelLayout.size(for:)` 转发给它。本次没有引入第二张表。
2. 纠错提示保持「选中说错的词，再按一次快捷键即可纠正」，不改成稿件的「再按 ⌥ 可口述修改」。
3. 数字键回答只装 **local** monitor。

## 验证

`swift build` 干净；`swift test` **524 passed, 0 failures**，未改动任何测试。
