# 2026-08-15 产品批次执行计划

Status: approved（产品负责人 2026-08-15 确认「全都做了吧」）。
来源：`docs/reviews/2026-08-15-product-review.md`。基线：`main` @ `53414e4`（Release 1.0.0），
Swift 524 XCTest + 13 swift-testing 全绿，sidecar 831 pass / 0 fail。

执行方式：每条走 CLAUDE.md 约定的 4 阶段 TDD 管线（写测试 → 审测试确认红 → 实现 → 审实现后即提交），
每阶段独立 Agent 分发。本文件是每条的设计输入；实现中若偏离，回来改这份文档，不要让它烂掉。

---

## 贯穿这一批的两条主线

上一批（2026-08-14）把「用得越久越准」做成了真的在跑的代码。这一批做两件事：

```
主线一：让已经做成的事被看见
   词典替换 / 入典 / 收敛趋势 —— 三个出口今天全是静默的

主线二：补上「已发布产品」才有的那一层
   更新通道、开机自启、英文界面、首启进度 —— 1.0 之前可以拖，1.0 之后是流失路径
```

两条主线互不相干，可以并行推进；组内顺序见 §顺序与依赖。

---

## A. 开机自启（review #5）

**目标**：`SMAppService.mainApp` 注册/注销，Settings 里一个开关。

- 新纯逻辑座 `Sources/OpenType/LaunchAtLogin.swift`：
  - `protocol LoginItemRegistering { var isRegistered: Bool { get }; func register() throws; func unregister() throws }`
  - `struct SMAppServiceLoginItem: LoginItemRegistering`（生产实现，包 `SMAppService.mainApp`）
  - `enum LaunchAtLoginPolicy`：纯函数 `desiredAction(current:desired:) -> .register | .unregister | .none`，
    以及 `resolveStatus(_ status:) -> LaunchAtLoginStatus`（`.enabled / .disabled / .requiresApproval / .notSupported`）。
    **`.requiresApproval` 必须单独成一个 case**：macOS 13+ 用户可能在系统设置里把它禁用了，
    这时 `register()` 不报错但也不生效，UI 必须能说出「已被系统设置拦下」并给一个跳转按钮，
    否则用户会看到一个打开着但不起作用的开关。
- `AppConfiguration`：`@Published var launchAtLogin: Bool`，key `launchAtLogin`，默认 **false**
  （不改变现有用户的行为；新装用户在 onboarding 结束时被问一次，见 §E）。
- 写入方向是单向的：**系统状态是唯一事实来源**。开关读 `SMAppService.mainApp.status`，
  不读 UserDefaults——否则用户在系统设置里关掉之后，我们的开关还显示「开」。
  UserDefaults 只存「用户是否表达过意愿」，用于 onboarding 只问一次。
- `LSUIElement` 已经是 true，注册 mainApp 后不会有 Dock 图标闪现，无需 helper bundle。
- Settings：「通用」组第一行。文案「开机时自动启动」，副文案说明这是常驻工具。

**测试**：`LaunchAtLoginPolicy` 的纯函数（含 `.requiresApproval` 分支）+ 一个假的
`LoginItemRegistering` 驱动的 toggle 往返。不测 `SMAppService` 本身。

---

## B. 更新检查（review #4）

**目标**：应用知道自己过时了，并告诉用户怎么办。**不引入 Sparkle**——没有自动更新，只有通知。

- 新模块 `Sources/OpenType/UpdateChecker.swift`：
  - 纯函数 `compareVersions(_ a: String, _ b: String) -> ComparisonResult`，语义化版本，
    容忍 `v` 前缀、缺省 patch 位（`1.0` == `1.0.0`）、以及非数字后缀（`1.1.0-beta` < `1.1.0`）。
  - 纯函数 `UpdateCheckOutcome.from(local:latest:)` → `.upToDate | .updateAvailable(version:url:) | .unknown`。
  - `actor UpdateChecker`：`check() async -> UpdateCheckOutcome`，打
    `https://api.github.com/repos/iyidgnaw/OpenType/releases/latest`，取 `tag_name` 与 `html_url`。
    **注入 `fetch` 闭包**，测试不出网。
- 触发时机：启动后 **10 秒**查一次（不和 sidecar 启动、模型下载抢带宽），此后每 **24 小时**一次；
  外加 Settings 里一个「立即检查」按钮。失败**完全静默**（`.unknown`），不弹任何东西——
  一个网络抖动不该变成用户要处理的信息。
- 展示：Settings「关于」组一行显示当前版本 + 状态。有新版本时**额外**在菜单栏 popover 底部出现一行
  「有新版本 1.1.0」+「复制安装命令」按钮（复制 `curl -fsSL https://opentype-site.vercel.app/install | zsh`）。
  popover 是常驻可见面，主窗口通常关着——只放在 Settings 里等于没做。
- **不做**：不自动下载、不自动安装、不弹模态。安装脚本是幂等的，用户自己跑就行。
- `AppConfiguration`：`@Published var updateCheckEnabled: Bool = true`（可关，local-first 产品要给这个选项），
  以及 `lastSeenUpdateVersion` 用于「同一个版本只提示一次」。

**测试**：`compareVersions` 的版本矩阵（含前缀/位数/预发布）、`UpdateCheckOutcome.from` 三分支、
`UpdateChecker` 对 mock fetch 的解析（正常 / 404 / 畸形 JSON / 超时）、「同版本不重复提示」。

---

## C. 转写语言真的传到 Whisper（review #2）

**目标**：设置里那 27 种语言影响**最终识别**，而不只是实时字幕。

- `TranscriptionLanguage` 增加 `var whisperCode: String?`——Whisper 的 ISO-639-1 码
  （`automatic` → `nil`，`chinese` → `"zh"`，`cantonese` → `"yue"`，`english` → `"en"`，…）。
  **`cantonese` 要单独确认**：Whisper 支持 `yue`，但 mlx 侧模型是否识别取决于权重；
  实现阶段实测一次，不支持就退回 `"zh"` 并在枚举上注释说明。
- `sidecar/whisper/serve.py`：`/transcribe` 增加 query 参数 `language`（与 `initial_prompt` 同一条路径），
  传进 `mlx_whisper.transcribe(..., language=...)`。**注意它不是顶层具名参数，走 `**decode_options`**
  （`2026-08-14-product-batch-plan.md` §已核实的 mlx_whisper 签名 已实测记录）。缺省不传，行为不变。
- `sidecar/src/asr/whisperClient.ts`：`transcribe(audio, { initialPrompt?, language? })`。
- `sidecar/src/asr/routes.ts`：`TranscribeRequestBody` 增加可选 `language`，透传。
- `sidecar/src/asr/remoteWhisperClient.ts`：OpenAI 的 `/audio/transcriptions` 有 `language` 表单字段，
  **两条后端都要接**，否则切到远程之后这个设置又变回假的。
- Swift：`AppModel` 发 `/asr/transcribe` 时带上 `configuration.transcriptionLanguage.whisperCode`。
- Settings 的这一项文案改成明确的「语音识别语言」，并把「自动」标注为默认。

**测试**：`whisperCode` 映射全枚举覆盖（每个 case 都要有断言，防止加了枚举忘了映射）；
`routes.ts` 透传（含缺省不传）；`remoteWhisperClient` 的表单字段；serve.py 的 query 解析。

---

## D. 学习闭环可见化（review #1）—— 本批主线

三个出口，一起做。分开做没有意义。

### D-1 `replacements` 返回并可见

- `sidecar/src/asr/routes.ts:132` 今天是 `applyAliasCorrections(text, terms).text`，`.replacements` 被丢弃。
  改成把它一起放进响应：`{ text, replacements: [{ from, to }] }`。**向后兼容**：字段可选，老调用方不受影响。
- Swift：`TranscribeResponse` 解码 `replacements`。交付后若非空，浮层 toast 追加一行
  「自动修正 N 处」，可展开看 `呸泡 → PayPal` 的清单。
- **必须可撤销**。展开后每一条给一个「撤销并删除该词条」——一次点击把这次替换还原（重新交付原文）
  **并且**删掉那条别名（`DELETE /memory/terms/:id` 已经有了）。
  理由写在 review #1：入典是启发式的，学错的别名今天在界面上没有任何解释，用户唯一的修法是去记忆页翻词典。
  这是这一条真正的产品价值，不是装饰。
  - 撤销要还原的是**交付出去的文本**：走和就地纠错同一条 `ContextBridge.insert` 路径，
    并且只在「前台应用未变 + 交付后 8 秒内」有效（复用 `CorrectionWindow` 的判据，不新造一套时限）。
    超时或应用已变 → 只删词条，不动已交付文本，并把这一点说清楚（「已删除该词条，但这次的文本没有改回」）。

### D-2 入典结果可见（「已记住」）

- `AppModel.swift:1538` 的 `CorrectionResponseBody.learned` 今天零读取。接上：
  纠错成功且 `learned != nil` 时，toast 显示「已记住：呸泡 → PayPal」，点击跳转记忆页并选中该行。
- 两条纠错路径都要（Review 面板的、就地纠错的），因为它们共用 `requestCorrection`。

### D-3 收敛趋势

- `UsageStats` 增加 `correctionsPerHundredWordsTrend(days:)` → `[(date, value)]`，7 天。
- 统计面板把「每百字纠错次数」从单点改成折线（沿用 `DS.*`，不引第三方图表库——一条 7 点折线用
  `Path` 画即可）。
- 增加一个数字：「词典已学会 N 个词」（`GET /memory/terms` 的计数，按 `origin` 分组显示 owner 的那部分）。
- **注意 current-state §11 记录的既有口径边**：`recordingEndedAt` 可选字段缺失的老行必须继续排除，
  不能在趋势里当 0 算。

**测试**：`applyAliasCorrections` 已有测试不动，新增响应形状测试；Swift 侧 `replacements`/`learned` 解码；
撤销的时限判据（复用 `CorrectionWindow` 的纯函数，新增「超时只删词条不改文本」分支）；
`UsageStats` 趋势聚合（含缺失 `recordingEndedAt` 的老行排除、不足 7 天的补齐行为）。

---

## E. Whisper 模型 UI + 首启下载进度（review #3）

**目标**：消灭「装完、按热键、说完、松开、什么都没有」这一分钟。

### E-1 serve.py 先起服务，后加载模型

今天 `_warm_up_model()` 在 socket 服务之前跑，所以模型下载期间**根本没有人能问它在干嘛**。翻过来：

- 先 `UnixHTTPServer` 起服务，模型加载放后台线程。
- 新增 `GET /status` → `{"state": "downloading"|"loading"|"ready"|"failed", "model": "...",
  "downloadedBytes": N, "totalBytes": M|null, "error": "..."}`。
- `POST /transcribe` 在模型未就绪时**阻塞等待**（保持今天的语义，Swift 侧已有超时），不要改成报错。
- 进度：`huggingface_hub.snapshot_download(MODEL, tqdm_class=…)` 传一个自定义 tqdm 累加字节。
  **拿不到就退化成 `totalBytes: null`**——状态机（downloading/loading/ready）比字节数重要得多，
  不能因为进度条拿不到就整条不做。

### E-2 sidecar 暴露状态

- `GET /asr/status` 代理 serve.py 的 `/status`，并补一个 whisper 进程还没起来时的 `"starting"`，
  远程 Whisper 配置下直接返回 `{"state":"ready","backend":"remote"}`。

### E-3 Swift 侧的可见性

- 启动后轮询 `/asr/status`（**只在非 ready 时轮询**，ready 之后停，不做常驻定时器）。
- 未就绪时：菜单栏 popover 顶部一条「正在准备语音模型…（首次约 460 MB）」+ 进度；
  主窗口 onboarding 向导最后增加一步同样的进度，让用户在**第一次按热键之前**就看到它。
- 用户在未就绪时按了热键：录音照常进行（不阻止），浮层文案从「识别中」变成
  「正在准备语音模型（首次约 460 MB）…」+ 进度。**录音不能丢**——等就绪后照常转写交付。
- 失败态给出可操作出口：重试 + 「改用远程识别」（跳到 provider 设置）。

### E-4 模型选择

- `sidecar` 新增 `GET/PUT /config/whisper-model`（复用 `ProviderConfigStore` 同目录的写法，
  **不新造存储策略**）。值是 HF repo id，预置三档：
  `mlx-community/whisper-small-mlx`（默认）/ `…medium-mlx` / `…large-v3-mlx`，
  UI 标注体积与相对速度。改动后需要重启 whisper 子进程才生效——**面板要说这一点**
  （沿用 MCP 面板「下次启动生效」的既有惯例，或者直接实现重启子进程；实现阶段二选一，取简单可靠的那个）。
- `serve.py` 的 `OPENTYPE_WHISPER_MODEL` 环境变量保留为覆盖项，**保存的配置优先**
  （与 MCP 的 `saved-beats-env` 精确一致）。

**测试**：serve.py 的 `/status` 状态机（单测 python 侧的纯状态持有者）；`/asr/status` 的三种后端分支；
Swift 侧轮询策略的纯函数（何时开始、何时停、失败退避）；模型配置的 saved-beats-env 优先级。

---

## F. 界面语言跟随系统（review #10）

**目标**：英文用户装完看到英文。**文案已经写好了**——670 个调用点都带着 `english:` 参数。

- `OpenTypeL10n` 从「永远返回中文」改成读一个 `static var current: InterfaceLanguage`：
  - `enum InterfaceLanguage { case system, chinese, english }`，存在 `AppConfiguration`，默认 `.system`。
  - `.system` 的解析：`Locale.preferredLanguages.first` 以 `zh` 开头 → 中文，否则英文。
  - `text(_:english:)` 按 `current` 返回；`locale` 同步返回 `zh-Hans` 或 `en`。
- **立即生效**：`AppConfiguration` 上加一个 `interfaceLanguageToken`，`RootView` / popover / 浮层
  用它做 `.id()`，切换语言时整棵树重建。不要求重启。
- Settings「通用」组：跟随系统 / 中文 / English。
- **`Resources/Localization/en.lproj/Localizable.strings` 已经过期**（72 行，还留着「智能编辑分支」
  这种早已删除的 Prompt Studio 文案）。真正的资产是那 670 个内联 `english:`。
  这一条要做的收尾：**审计所有绕过 `OpenTypeL10n` 的裸中文字面量**
  （`Text("中文")` / `.help("中文")` / 通知文案 / `Info.plist` 的三条 usage description）。
  审计脚本化：一个 grep 规则加进 `scripts/tests/`，让下一个漏网的字面量在 CI 里被抓住，
  而不是靠人再读一遍 670 处。
- `Info.plist` 的 `CFBundleDevelopmentRegion` 从 `zh_CN` 改成 `en`，并补 `zh-Hans` 本地化的
  usage description（麦克风/语音识别/AppleEvents 三条现在是硬编码中文，英文用户会在系统弹窗里看到中文）。

**测试**：`.system` 解析（zh-Hans / zh-Hant / en / fr / 空）、三种设置下 `text()` 的返回、
`locale` 同步；裸字面量审计脚本自身要有一个「能抓到已知样例」的测试。

---

## G. MCP 启动失败的可见性（review #11）

> **2026-08-15 范围更正（stage-1 发现，已独立核实）。** 本节原本要求「每个 server 加 8 秒超时」。
> **那一半早就做完了**：`1245eb7`（1.0.0 的祖先）已经让 `startMcpConnections` 并发、
> 每 server 受 `MCP_CONNECT_TIMEOUT_MS = 12_000` 约束且可注入，并且 `server.ts:181` 不再 await 它——
> `test/agent/mcpBootResilience.test.ts` 钉着这些。误判来源是 `current-state §11` 的过期条目，
> 详见 `docs/reviews/2026-08-15-product-review.md` §11 的更正块。
>
> **8 秒这个数不要去「修正」成 12 秒。** 8s 是在「连接仍然阻塞 `Bun.serve`、必须塞进 Swift 5s 预算」
> 这个前提下算出来的，而那个前提已经不存在了。本节不钉任何一个数。

**目标**：一个因为超时/失败被跳过的 server，不能在面板上和正常工作的 server 长得一样。

`startMcpConnections` 已经把每个 server 的结局记成 `connecting | connected | failed | timedOut` 外加错误文本，
但这份报告**没有出口**——`LazyMcpToolSet.status()` 无人读取，`buildMcpConfigRoutes` 也拿不到它。要做的是接上出口：

- `McpConfigRouteDeps` 增加**可选**的 `connectionReport?: () => McpConnectionReport`，
  `GET /config/mcp` 的每一行增加可选 `lastStartupError?: string`。可选是为了让
  `mcpConfigRoutes.test.ts` 既有的约 50 个测试与「没有 MCP 工具集可交」的装配保持原样。
- `buildApp` 多一个可选参数，`main()` 把 `mcpTools.status` 传进去。
- 三条载重性质，各有测试：
  1. **按请求读，不在建路由时快照**（所以是 getter 不是值）。路由在启动时构建，那时每个 server 都还是
     `connecting`；快照会永久报告「无错误」，等于把静默跳过原样搬到上一层。
  2. **按 name 匹配，绝不按下标**。响应列的是 `allServers`（含被禁用的，以便还能重新启用），
     而只有 enabled 子集会被连接——一旦有 server 被关掉，两个列表的长度和顺序就不同，
     按下标 zip 会把失败扣到一个从没被启动过的行上。
  3. **timeout 与 outright failure 在文本里保持可区分**。用户的修法不同（「太慢/连不上，已跳过」
     vs「你的 command 写错了」），而面板只有一个字符串可渲染。
- 响应的顶层形状不变（仍是 `{ configured, source, servers }`）——`mcpConfigRoutes.test.ts` 第一个测试
  用严格 `toEqual` 钉着它，而这是 per-server 信息。
- **不做**：不改成完全非阻塞的 lazy `openAiTools`（那是独立的一块工作）。

**测试**：见 `sidecar/test/agent/mcpStartupErrorReporting.test.ts`（stage-1 已写，红在可见性这一半）。
连接超时行为本身**不重复测**——`mcpBootResilience.test.ts` 已经覆盖，再写一遍只是引入第二套假 transport。

---

## H. Ask 结果卡片的「交给助理去做」（review #6）

- 结果卡片（`OverlayController` 的 result card）与会话详情页各加一个按钮：
  把**同一个问题**用完整工具集重跑一次，复用 `conversationId`。
- 实现上就是用原 transcript 调 `/agent/run`，`conversationId` 沿用，卡片切到 agent 的步骤流。
- **单向**：只有 ask → agent，没有反向（agent 跑完发现只是个问题，没有代价）。
- 不改模式数量、不改热键。这不是 P1-5 合并的复活——那条已被否决，此处只给「我选错了」一个出口。

**测试**：会话 `kind` 的迁移语义（ask 会话被升级后，后续轮次走哪条路）——这是唯一有歧义的地方，
决定：**升级只影响这一轮，会话 kind 不变**，否则用户问一次工具类问题就把整个会话变成 agent 了。

---

## I. 历史：正文搜索 / 单条删除 / 导出（review #7）

- `HistoryStore`：`delete(id:)`，`entries` 上限从 100 提到 **1000**（JSON 文件，1000 条量级完全够用；
  真要再大就该换存储，那是另一件事）。
- 听写页与会话页的搜索改为**匹配正文**（`SessionsViews.swift:98` 的注释自己承认了今天只匹配标题）。
  会话正文在 sidecar，需要 `GET /conversations?q=` 或本地已缓存的 detail——
  实现阶段先做本地已加载部分的正文匹配，并在无结果时明确说「只搜索了已加载的会话」，
  **不要假装搜了全部**。
- 导出：听写历史与单个会话导出为 Markdown / JSON。放在各自列表的 `…` 菜单里。
- 单条删除：听写历史行的右键菜单 + 会话的 `…` 菜单。

**测试**：`HistoryStore.delete` / 上限迁移（老的 100 条文件读进来不丢）；搜索匹配的纯函数
（大小写、CJK 子串、空查询返回全部）；导出格式的快照测试。

---

## J. 按应用规则（review #8）

- 新纯模块 `Sources/OpenType/AppRules.swift`：
  `struct AppRule { bundleIdentifier: String; autoInsert: Bool?; transcribeVariant: TranscribeVariant? }`
  + `func rule(for bundleId:) -> AppRule?`。
- **内置默认，先不做通用规则引擎**（review §14 的判断）：
  - 终端类（`com.apple.Terminal`、`com.googlecode.iterm2`、`dev.warp.Warp-Stable`、`net.kovidgoyal.kitty`、
    `com.github.wez.wezterm`）→ **默认不自动插入**。理由是把带换行的口述粘进终端可能直接执行，
    这是当前配置下真实可达的破坏路径，且比 Agent 的 `opentype__bash` 更没人看着。
  - 即时通讯/笔记类（微信、Slack、备忘录、Notion）→ 默认 `tidy`。
  - 代码编辑器（Xcode、VS Code、JetBrains）→ 默认 `direct`。
- 接入点：`OutputDeliveryPolicy.shouldInsert` 已经拿到 `capturedBundleId`/`frontmostBundleId`，
  规则在这一层生效，**不新开一条交付路径**。
- Settings 里可见且可关（一个「按应用调整行为」总开关 + 一张只读的默认表）。
  用户改单条规则不在本批——先看默认值是不是真的需要改。

**测试**：`AppRules` 查表（含未知 app 返回 nil）；`OutputDeliveryPolicy` 在规则存在/不存在时的行为；
总开关关闭时规则完全不生效。

---

## K. 麦克风设备可见（review #9）—— 已完成（2026-08-15）

- Settings「语音识别」组显示**当前系统默认输入设备名**（`AVCaptureDevice.default(for: .audio)`），
  设备变化时更新（`AVCaptureDevice.wasDisconnectedNotification` / 默认设备变化通知）。
- **只显示，不做选择器**（review #9 的判断：让用户能自己诊断「今天识别特别差」，比让他猜强）。

**测试**：设备名解析的纯函数（无设备 / 无权限 / 正常）。不测 AVFoundation 本身。

**落地**：`Sources/OpenType/InputDevice.swift`（`InputDeviceSnapshot` / `InputDeviceName.resolve(from:)` /
`InputDeviceMonitor`）+ `SettingsViews2.swift`「引擎」组末行「输入设备」，
`Tests/OpenTypeTests/InputDeviceNameTests.swift` 13 例。三处与本节字面写法不同，都是有意的：

- 落在**「引擎」组**而不是「语音识别」组——2026-08-14 重设计之后，「语音识别」已经是那一组里的
  一行（推送到服务商子页），组名叫「引擎」。放在同组末行，跟两行服务商行一样用 mono，语义没变。
- **无权限时不说「没有设备」**：两种空状态分开成两句话，因为解法不同（插设备 vs 给权限）。
  并且**有名字时不看权限**——macOS 常常在授权之前就能报出默认输入的名字，把它藏到权限提示后面
  等于让这一行比它替换掉的空行更没用。
- 默认设备变化没有 AVFoundation 通知（只有 Core Audio 的属性监听），所以用
  `NSApplication.didBecomeActiveNotification` 兜住「去系统设置改完再切回来」这条路径，
  加上设置页 `.task` 的一次重读。全程无轮询。

---

## L. 菜单栏模板图标（review #12）—— 已完成（2026-08-15）

- `OpenTypeApp.swift:389` 的 `image.isTemplate = false` → `true`，状态改用**形状**区分
  （idle 点 / listening 波形 / processing 齿轮或进度），而不是颜色。
- 录音中允许保留一点强调色（这是 HIG 认可的例外），但 idle/processing 必须是模板图。

**测试**：状态 → 图标名的纯映射函数（每个状态一个断言）。

**落地**：`MenuBarStatusIcon`（`OpenTypeApp.swift`）拆成三个纯函数——`symbolName(for:mode:)` /
`tint(for:)` / `accessibilityDescription(for:mode:runningAgentCount:)`——加一个只负责合成的
`image(...)`，`Tests/OpenTypeTests/MenuBarStatusIconTests.swift` 22 例。红的证据不是「函数还不存在」，
是把旧图标栅格化之后只留 alpha 通道（模板图就只有这个）：**idle / listening / processing / 三个 mode
两两之间全部 0.0000**，即彩色去掉之后它们是同一张图——review #12 说的就是这件事，只是现在量出来了。

四处与本节字面写法不同：

- **idle 不是「点」，是当前 mode 的图形**（`InputMode.symbol`，跟 popover 里那张 mode 卡同一个形状）。
  一个图形答不了两个问题，所以让它答当前活着的那个：静止时是「下一次按下会做什么」，
  一旦有事发生就被状态接管。这条也是 `listening` 不能用 `mic.fill` 的原因——那是 transcribe 的
  mode 图形，复用它会让**用得最多的那个 mode** 的 idle 和录音变成同一张图。
- **processing 不用齿轮**：菜单栏里的齿轮读作「设置」。用 `ellipsis.circle`，而且是带圈的——
  先试了裸 `ellipsis`，它的视觉重量只有其他图形的三分之一，工作那一秒图标像是消失了又回来。
- **允许合并的状态是列出来的，不是漏掉的**：`transcribing`/`transforming`/`inserting` 共用一个
  「在做」的记号（各自只有几百毫秒，用户没有依赖于区分它们的动作），`success`/`copied` 共用一个，
  `idle`/`modeChanged` 共用一个（宣布 mode 本身就是 mode）。其余两两必须不同，测试里按这个清单断言。
  `switch` **不写 `default:`**，所以 `ProcessingState` 新增 case 是编译失败而不是静默继承别人的形状。
- **角标丢掉了数字，这是变好不是妥协**：原来是 36px 精灵图里的 9.5pt 字，屏幕上不到 5 点，
  彩色时就已经读不出来，而 mask 里根本没有第二种颜色可以印它。现在是 5pt 圆点 + 一圈**挖空**
  （mask 里两个不透明形状挨在一起会糊成一块，分隔只能是「没有」），数字移进 tooltip 和 VoiceOver
  标签——这两处也从常量 `"OpenType"` 改成随状态更新，因为形状之外只剩文字能说清楚现在是什么状态。

---

## 顺序与依赖

```
第一轮（互不冲突，主线二为主）
  A 开机自启 ──┐
  B 更新检查 ──┼── 都只加新文件 + AppConfiguration/Settings 各一行
  G MCP 超时 ──┘   （G 是纯 sidecar，与 A/B 无交集）

第二轮（主线一）
  C 转写语言 ──→ D 学习闭环可见化
     （C 先，因为两条都改 asr/routes.ts 与 SidecarClient，串行避免互相踩）

第三轮
  E Whisper 状态 + 模型 UI   （最大的一条，独立）
  F 界面语言                  （触及面最广，放在功能都落地之后做，否则新加的文案要改两遍）

第四轮（收尾）
  H 升级按钮 → I 历史 → J 按应用规则 → K 麦克风 → L 模板图标
```

**F 必须最后做**，理由写在上面：它要审计全部裸中文字面量，而 A–E 会新增文案。
把它放在前面等于让每一条后续改动都去改两遍。
