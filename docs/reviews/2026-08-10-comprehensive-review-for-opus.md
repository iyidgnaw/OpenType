# OpenType 全面评审报告（2026-08-10）

> **用途**：本文档是对当前 `main`（d45905f）的一次全面评审——代码、功能、设计、UX 交互、产品方向——供下一轮改进（Opus 执行）直接使用。每条 finding 尽量带 `文件:行号`、证据和修复建议，按优先级排序。
>
> **评审方法**：主评审员精读核心链路（AppModel / SidecarClient / ContextBridge / server.ts / agent loop / 各 Store / as-built spec），另派 4 个专项评审（Swift 全量、sidecar 全量+安全、UX 走查、文档一致性）交叉覆盖；所有 P0 级结论均经过第二次人工核读代码确认。评审基线：`swift test` 59/59 通过，sidecar `bun test` 211/211 通过。
>
> **执行须知**：按仓库 CLAUDE.md 的约定，所有修复/功能实现走 4 阶段 TDD 管线（写测试 → 审测试确认红 → 实现 → 审实现后即提交），每阶段独立 Agent 分发。本文档每个 P0/P1 条目都给出了建议的回归测试，正好作为阶段 1 的输入。

---

## 0. 执行摘要

**总体判断**：这是一个 48 小时内高强度重写出来的、工程素养明显高于 hackathon 常态的 MVP——架构切分正确（Swift 壳管系统集成，sidecar 管所有 AI 调用）、注释诚实记录 tradeoff、sidecar 测试跑真路由真 SQLite、as-built 文档质量罕见地高。但它当前处于「演示可用、日用即坏」的状态：**核心听写路径存在必现故障（录音 >20 秒必失败）**，「取消」这一基础动作全线缺失，传输层（curl 子进程）同时埋着卡死、泄密、超限三颗雷，Review 模式第二次使用即坏，错误处理链条从 sidecar 到 UI 全程漏底。

**十大必修（按修复顺序）**：

| # | 问题 | 位置 | 级别 |
|---|------|------|------|
| 1 | 录音 >~20s 必失败：base64 音频经 curl argv，撞 ARG_MAX | SidecarClient.swift:400 | P0 |
| 2 | curl 响应 >64KB 管道死锁 + 无超时 + 无法取消 → 整机卡死到重启 | SidecarClient.swift:405-443 | P0 |
| 3 | Review 面板第二次会话必坏：显示旧文本、手动编辑丢失、语音纠错永久失效 | ReviewPanelController.swift:92-96 | P0 |
| 4 | 开发者真实 API key 被打进分发包 | scripts/build-app.sh:69 | P0（分发即泄漏） |
| 5 | sidecar handler 抛错返回 HTML 500，Swift 侧永远拿不到可读错误 | sidecar/src/router.ts:30-42 | P1 |
| 6 | 用户无任何取消手段：`AppModel.cancel()` 零调用方，Esc 是「任意键=提交」 | AppModel.swift:428 | P1 |
| 7 | sidecar/Whisper 进程死亡无监督无恢复，状态栏永远显示「已就绪」 | AppModel.swift:217-246, sidecar/src/server.ts:121-141 | P1 |
| 8 | 记忆投毒链：不可信文本 → `remember_fact` 全信落库 → 永久注入所有 prompt，且无查看/删除入口 | sidecar/src/agent/builtInTools.ts:88 | P1 |
| 9 | Ask 模式阻塞整条录音管线（Agent 做了非阻塞，Ask 没做） | AppModel.swift:1454-1481 | P1 |
| 10 | Onboarding 强制配 LLM key 才能进 app，纯听写用户被挡在门外 | Views.swift:62-95 | P1（产品） |

**产品方向判断**：最大的空白不是缺功能，而是「记忆系统建了一半、且已建成的部分大面积断线」。文档核查（§9）证实了三处断线：**(a) Swift 侧记忆检索层（`entriesForPrompt`/`LocalMemoryRetriever` 含 NLEmbedding 语义检索）在生产代码里零调用**——CLAUDE.md 宣称的「注入 Agent 上下文（~12 条预算）」实际不存在，这一整层只在记录、从不产出；**(b) 自动 consolidation（"dreaming"）从未接线**——12 小时门 `shouldConsolidate` 无任何调用方，整理只有手动路径；**(c) episodic 事件层只收 agent 运行**——transcribe/ask 从不进入，dreaming 的原料名不符实。同时实体词典对任何转写路径零参与：既没有作为 `initial_prompt` 喂给 Whisper 做识别偏置，也没有对转写结果做别名纠正，连 `/transcribe/correct` 都不带 MemoryStore。把这条链接通（词典 → ASR 偏置 → 转写后纠正 → episodic 全模式采集 → 自动整理）正是 CLAUDE.md「context-aware speech-to-text correction」愿景的落点，也是相对 OpenTypeless/竞品能拉开差距的地方（详见 §8/§9）。

---

## 1. 总体架构评价

**做对了的**：
- Swift 壳 + TS sidecar 的职责切分干净：系统集成（热键/AX/录音/交付）归 Swift，AI 调用全部归 sidecar，Swift 不碰任何云 API。Provider 配置系统重建时坚持 sidecar-owned（而不是复活旧的 Swift 侧 ProviderVault）是正确决策。
- Agent 非阻塞下发 + 通知 + 菜单栏徽标 + 点通知直达会话，是全产品完成度最高的一段体验。
- 纯逻辑抽取（`VoiceModeRouter`/`AgentRunHistory`/`TextSpanCorrection`/`OutputDeliveryPolicy`）体现了可测性意识；审计链 `supersedesEventId` 的 Review 会话回放设计超出 MVP 水准。
- 内置 agent 工具面克制（只有两个记忆工具，无 shell/文件访问）。

**两条主线问题**：
1. **传输层是全系统最薄弱环节**。`SidecarClient` 每请求 spawn 一个 curl 子进程，body 走 argv：带来 ARG_MAX 上限（P0-1）、`ps` 可见的 key/语音泄漏（P1-13）、64KB 管道死锁（P0-2）、无超时、无取消联动。**根治方案是换原生 Unix-socket HTTP（`Network.framework` 的 `NWConnection` + 手写极简 HTTP/1.1，或引入 SwiftNIO），一次性消掉 5 个问题**；短期止血方案见各条目。
2. **`AppModel` 已是 1916 行的 god object**：状态机、网络、审计、4 个面板同步、provider 配置全在一处，且 `init()` 携带副作用（spawn 子进程、装热键、请求通知权限），导致核心管线**零测试**（现有 59 个 Swift 测试全是外围纯逻辑）。建议拆出「录音会话状态机」+ 各领域 service，依赖协议化注入。

---

## 2. P0：必现功能故障 / 分发即事故

### P0-1 录音超过约 20 秒必然失败（听写工具的核心路径必现故障）

- **位置**：[SidecarClient.swift:400](Sources/OpenType/SidecarClient.swift:400)（`arguments += ["-d", bodyString, ...]`）；[AudioRecorder.swift:48-55](Sources/OpenType/AudioRecorder.swift:48)（16kHz/16bit/单声道 PCM）
- **机理**：音频 32KB/s，base64 后 ~42.7KB/s，作为 curl 的 argv 传递；macOS `ARG_MAX` = 1MB（argv+envp 共享），约 20-24 秒后 `process.run()` 抛 E2BIG，用户看到 "Sidecar request failed (curl exit -1)"。「把即兴讲话变成文字」的产品，说一段长话就触发。
- **修复**：短期——body 写入临时文件后 `--data-binary @file`（或经 stdin `-d @-`）；长期——原生 socket 传输（见 §1）。
- **回归测试**：构造 ~1MB 请求体走 `SidecarClient.request`，断言成功（现有测试有真 bun 集成测试基础设施可复用）。

### P0-2 curl 响应 >64KB 时管道死锁；叠加无超时、无取消 → 整机卡死到重启

- **位置**：[SidecarClient.swift:405-443](Sources/OpenType/SidecarClient.swift:405)
- **机理**：`terminationHandler` 里才 `readDataToEndOfFile()`——curl stdout 写满 64KB 管道即阻塞、永不退出、handler 永不触发、continuation 永不 resume。长对话的 `GET /conversations/:id`、带长 steps 的 `/agent/run` 响应都能超 64KB。同时 `runCurl` 无 `--max-time`，`withCheckedThrowingContinuation` 不响应 Task 取消。一旦卡在 `.transcribing/.transforming`，`isBusy` 挡住所有热键（AppModel.swift:285），而取消入口不存在（P1-6）→ 只能重启 app。
- **修复**：并发排空 stdout/stderr（`readabilityHandler` 或后台线程先读再 `waitUntilExit`）；加 `--max-time`（`/agent/run` 单独放宽或不限）；continuation 包 `withTaskCancellationHandler` 并在取消时 `process.terminate()`。
- **回归测试**：mock sidecar 返回 >64KB 响应、断言不死锁；不响应的 socket 断言超时抛错。

### P0-3 Review 面板第二次会话必坏（显示与写入不一致，纠错永久失效）

- **位置**：[ReviewPanelController.swift:92-96](Sources/OpenType/ReviewPanelController.swift:92)（`hide()` 置 `textView = nil`）、[:337-359](Sources/OpenType/ReviewPanelController.swift:337)（`onTextViewReady` 只在 `makeNSView` 触发一次）、[:361-365](Sources/OpenType/ReviewPanelController.swift:361)（`updateNSView` 刻意不写回文本）
- **机理**：panel 与 `lazy var hostingView` 复用，`orderOut` 不触发 SwiftUI 重建 NSView。第二次 `show()`：(a) NSTextView 仍显示**上一次会话的最终文本**，但 `currentText()` 因 `textView == nil` 回落到 `presentation.text`（新转写）——**用户看到的和 commit 写入的不是同一份文本**；(b) 用户在可见文本框里的手动编辑全部丢失；(c) `currentSelection()` 恒 nil → 语音纠错永远提示「请先选中文字」。已亲自核读代码确认。
- **修复**：`hide()` 不清 `textView`；`show()` 里若 `textView` 存在则显式 `textView.string = originalTranscript` 并重置选区。
- **回归测试**：连续两次 `show→hide→show` 后断言 `currentText()`/面板显示/`currentSelection()` 一致性。

### P0-4 开发者真实 API key 被打进分发包

- **位置**：[scripts/build-app.sh:69](scripts/build-app.sh)（拷 `sidecar/.env.local` → `Contents/Resources/sidecar.env`）；`sidecar/.env.local` 当前真实存在且含 `DEEPSEEK_API_KEY`，文件权限 0644
- **机理**：`dist/OpenType.app` 交给任何人（包括最近 commit 里刚做的公证/分发流程），开发者 key 即明文泄漏，且 `SidecarClient.loadBundledEnvironment` 会在对方机器上直接用它计费。
- **修复**：打包默认**排除**该文件（provider onboarding 向导本来就是为用户自配而建的）；如需保留 dev 便利，加显式 `--bundle-env` 开关 + 醒目警告。另：现有 key 已进过构建产物，**建议轮换**。

---

## 3. P1：可靠性 / 正确性 / 安全

### 错误处理链（一条线上的三个洞，建议一起修）

- **P1-1 sidecar router 无兜底**：[sidecar/src/router.ts:30-42](sidecar/src/router.ts:30) 对 handler rejection 无处理，Bun.serve 返回 **text/html 的 500 默认错误页**。受影响：`/oneshot/ask`、`/agent/run` 的 LLM 抛错（key 为空时 `env.ts:20` 默认 `""` 也走到 401）、`/transcribe/correct`、所有端点收到非法 JSON 时的 `req.json()` 抛错。目前只有 `/asr/transcribe` 自己 catch 了。**修**：`createRouter` 统一 try/catch → `Response.json({error}, {status})`，各 ApiError 透传 status/message。
- **P1-2 Swift 侧不认识自己的错误**：[Models.swift:725-748](Sources/OpenType/Models.swift:725) `ErrorMessagePresenter` 只处理 `OpenTypeError`/`URLError`，对 `SidecarClientError` 直接漏出英文技术串（"Sidecar request failed (curl exit 7): …"、"Failed to decode … — body: <整段 HTML>"）——README:31「不直接暴露底层技术报错」的承诺未兑现。`URLError` 分支（含「当前没有网络连接」文案）是**死代码**：全部流量走 curl，断网表现为 exit 6/7。**修**：增加 `SidecarClientError` 的中文归纳映射；删 URLError 分支。
- **P1-3 残留文案**：[Models.swift:765](Sources/OpenType/Models.swift:765) unauthorized 错误映射为「**DashScope** 连接已失效」——已删供应商的品牌残留；[Views.swift:1411-1414](Sources/OpenType/Views.swift:1411) 设置页脚宣称「固定的 DeepSeek 模型…不需要配置云端服务商」，与其正上方的 provider 配置区自相矛盾。

### 进程生命周期（第二条线，建议一起修）

- **P1-4 sidecar 崩溃无监督**：[SidecarClient.swift:240-250](Sources/OpenType/SidecarClient.swift:240) `terminationHandler` 只写 debug log；`sidecarStatus` 只在启动时设置一次（AppModel.swift:217-246），崩溃后永远显示「已就绪」，每次录音失败且无恢复路径。**修**：termination 回调 AppModel → 状态更新 + 带退避的自动重启 + Home/popover 显著错误卡与「重启服务」按钮。
- **P1-5 Whisper Python 进程死亡 → 本地 ASR 永久不可用**：[sidecar/src/server.ts:121-141](sidecar/src/server.ts:121) `whisperReady` 失败即永久 rejected；运行中崩溃无 onExit 监控无 respawn。**修**：`postAudio` 连接级失败时带退避 restart-and-retry，或 `Bun.spawn` `onExit` 自动 respawn（带次数上限）。
- **P1-6 子进程 stdout/stderr 管道从不排空**：[SidecarClient.swift:235-250](Sources/OpenType/SidecarClient.swift:235) 只在 terminationHandler 读；叠加 [whisperClient.ts:169-170](sidecar/src/asr/whisperClient.ts:169) `stdout/stderr: "inherit"`，MLX-Whisper 的日志（含首次模型下载进度）全部灌进这两个 64KB 管道——菜单栏常驻进程长时间运行后必然写满，Python 同步 print 阻塞 → ASR 挂起 → 叠加 P0-2 = 整机挂起。**修**：`readabilityHandler` 持续排空落盘。
- **P1-7 Whisper 孤儿进程累积**：sidecar 无 SIGTERM 处理（server.ts 全文无 `process.on`），`WhisperClient.stop()` 零生产调用方；Swift 只 terminate sidecar 本体 → 每次 app 重启孤儿化一个驻留数百 MB 模型的 Python 进程。**修**：server.ts 注册信号处理 → `whisperClient.stop()`；Swift 侧考虑杀进程组。as-built spec §11 已记录的 force-quit 孤儿问题同根。
- **P1-8 首启撞超时**：[whisper/serve.py:38-51](sidecar/whisper/serve.py:38) warm-up 会从 HuggingFace 下载模型；[whisperClient.ts:47](sidecar/src/asr/whisperClient.ts:47) 30s readiness 超时到即 kill → 慢网络用户首启本地 ASR 直接坏死（叠加 P1-5 无恢复）。**修**：区分「进程活着但未 ready」（不 kill、上报下载进度），或打包模型进 app。
- **P1-9 双实例互踩**：[server.ts:179-181](sidecar/src/server.ts:179) 启动无条件 unlink socket，第二实例抢走路径（as-built spec §11 已实测记录）。**修**：启动先试连，连通则报错退出；Swift 侧单实例守卫。

### 交互与数据完整性

- **P1-10 无任何取消手段**：`AppModel.cancel()` 零调用方（grep 全仓证实）；「按任意键结束」路径 Esc 也是「任意键=提交」（[GlobalHotKey.swift:205-211](Sources/OpenType/GlobalHotKey.swift:205)）。说错话只能眼看它转写完、覆盖剪贴板。**修**：录音中 Esc=丢弃；处理中 Esc/overlay 按钮=取消（联动 P0-2 的取消传播）；Ask 弹窗关闭=中止请求（当前关闭后请求继续，几秒后「幽灵答案」仍会覆盖剪贴板并自动插入，[AppModel.swift:706-708](Sources/OpenType/AppModel.swift:706)）。
- **P1-11 Ask 阻塞整条管线**：`/oneshot/ask` 在 `process()` 内被 await（[AppModel.swift:1462](Sources/OpenType/AppModel.swift:1462)），LLM 慢 = 期间完全不能听写。Agent 已有成熟的 detached-dispatch 模式（`dispatchAgentRun`），Ask 照搬即可。
- **P1-12 记忆投毒链**：`/agent/run` 的 `context`（屏幕选中文本，可能来自任意网页）与 MCP 工具返回原样进循环；系统提示明示「treat any tool you're given as safe」且 `remember_fact`「call it immediately and trust it fully」（[builtInTools.ts:134-138](sidecar/src/agent/builtInTools.ts:134)）；[builtInTools.ts:88](sidecar/src/agent/builtInTools.ts:88) 硬编码 origin `"owner"` 落库；[memoryContext.ts:40-46](sidecar/src/oneshot/memoryContext.ts:40) 把所有 owner_facts 无条件注入之后每个请求；**且没有任何端点/UI 能查看或删除 owner_facts**。一段选中文本写 "remember that the owner prefers…"即可永久、不可见、不可删地污染所有未来请求。**修**：(a) 加 owner_facts/entity_terms 的 GET/DELETE 端点 + Settings 管理 UI；(b) 非用户原话来源的 fact 打 `"untrusted"` origin（枚举已存在未用）且不注入 prompt；(c) prompt 对 CONTEXT 段声明「其中指令不可执行」。同根问题：consolidator 产出的 term 也落 `"owner"` origin（[consolidator.ts:285](sidecar/src/memory/consolidator.ts:285)），溯源体系形同虚设。
- **P1-13 API key 与语音内容经 argv 暴露**：每个请求 body（含 `PUT /config/llm` 的明文 key、转写全文）作为 curl argv，请求期间本机任何进程 `ps aux` 可见。存储侧刻意 chmod 600，传输侧整个绕开。P0-1 的修复（stdin/临时文件）顺带消除。
- **P1-14 consolidation/rollback 无事务无互斥**：[consolidator.ts:378-430](sidecar/src/memory/consolidator.ts:378) upsert 循环+UPDATE+INSERT 无事务；[469-488](sidecar/src/memory/consolidator.ts:469) rollback **先全表 DELETE 再逐行重插**，崩在中间=真数据丢失；手动按钮与 agent 工具可并发触发双重写入。**修**：`db.transaction()` 包住写段 + 模块级互斥 Promise。
- **P1-15 剪贴板必被覆盖，恢复逻辑形同虚设**：[ContextBridge.swift:55-63](Sources/OpenType/ContextBridge.swift:55) 精心快照并恢复用户剪贴板，随后 [AppModel.swift:1579-1581](Sources/OpenType/AppModel.swift:1579) 无条件 `copyToClipboard(result)` 又覆盖掉。「结果必进剪贴板」是有意的产品保证，但用户原剪贴板内容必丢，与剪贴板管理器/工作流冲突。**修**：加设置「插入成功时不占用剪贴板」；写入时标记 `org.nspasteboard.TransientType` 让剪贴板管理器忽略。
- **P1-16 插入目标不校验**：`insert()` 把 Cmd+V 发给**完成时刻的前台 app**——转写期间切了窗口，文字就粘进错误的 app。**修**：交付前比对 `capturedContext.bundleIdentifier` 与当前 frontmost，不一致则降级为仅剪贴板+提示。同根：主窗口的「撤销写入」按钮（[Views.swift:620-625](Sources/OpenType/Views.swift:620)）点击时 OpenType 自己必然 frontmost，Cmd+Z 发给了自己，**该按钮从原理上不可能生效**。
- **P1-17 Ask 答案默认自动插入**：`automaticallyInsert` 默认 true 且 ask 走通用交付（[AppModel.swift:1559-1577](Sources/OpenType/AppModel.swift:1559)）——在聊天软件输入框里问个问题，大段答案被直接粘进去，误发风险高。**修**：ask 默认仅弹窗+剪贴板；插入设为显式动作。
- **P1-18 `.idle` overlay 永不消失**：[OverlayController.swift:42-58](Sources/OpenType/OverlayController.swift:42) 对 `.idle` 不安排隐藏且取消了旧隐藏任务；`processCorrection` 三条路径都直接 `setState(.idle)`（[AppModel.swift:842](Sources/OpenType/AppModel.swift:842) 等）→ 每做一次语音纠错，「就绪」HUD 常驻屏幕直到下次录音。**修**：`.idle` 直接 `hide()`。
- **P1-19 Onboarding 挡住纯听写用户**：向导替换全部 tab 内容并隐藏 TabBar（[Views.swift:62-95](Sources/OpenType/Views.swift:62)），`ready` 要求 Whisper+LLM 双配置（transcribe 根本不需要 LLM）；权限引导卡被排在 API key 之后。**修**：向导加「仅本地听写，跳过 AI 配置」路径；把麦克风/辅助功能提为向导第 0 步；LLM 未配置时仅在切到 ask/agent 时引导。

---

## 4. P2：代码质量 / 健壮性（凝练清单）

**死代码/残留**（建议一轮集中清理）：
- **整个 Swift 侧记忆检索面是死代码**：`AgentMemoryStore.entriesForPrompt/memoriesForPrompt/profileContextForPrompt`（AgentMemoryStore.swift:213/234/267）与整个 `LocalMemoryRetriever.swift`（含 NLEmbedding 语义检索）生产端零调用，仅测试引用——但其**采集/归纳侧仍在每次录音后跑全表扫描付出实时代价**（见下）。需要产品决策：要么接线（注入 agent context，见 §10 Phase 3），要么整层删除。
- `OpenTypeError.missingCredential/.invalidResponse` 无 throw 点；`missingEditInstruction` 只有 catch 没有 throw（AppModel.swift:1607）；`InputMode.requiresSelection` 恒 false 仍有两处守卫；`OutputDeliveryPolicy.strategy` 忽略 `mode` 参数；`AppModel.cancel()` 无调用方（修 P1-10 时接上）；sidecar 侧 `rollbackRun`/`shouldConsolidate` 无生产调用方——rollback 内部已完整实现（快照恢复+`rolledBackAt`，consolidator.ts:450-491），只差 HTTP 路由与 UI，要么补 `/memory/rollback` 端点+UI，要么删；`shouldConsolidate` 的 12h 自动门无人调用（见 §9-A2）。
- dev 回退路径硬编码 `/Users/diywang/hackathon/OpenType/sidecar`（SidecarClient.swift:227）。
- `/tmp/opentype-sidecar-client-debug.log`：固定路径、无上限、会落 sidecar stdout/stderr 内容，与审计文件 0600 的隐私标准不一致——release 构建应移除或收敛到 App Support + 轮转。

**正确性隐患**：
- `HistoryView` 只观察 `model`，`HistoryStore.entries` 变化不触发刷新，目前「碰巧能刷新」（Views.swift:635-681）——加 `@ObservedObject var history`。
- `AudioRecorder.stop()` 不清 `currentURL`，其后 `cancel()` 会误删正在转写的音频文件（AudioRecorder.swift:73-97 + AppModel.swift:437）。
- `refreshConversations`/`refreshMemoryPanel` 失败时把已有列表清成 `[]`，瞬断即闪空态（AppModel.swift:647-650）。
- `GlobalHotKey` 非 `@MainActor`，C 回调裸改可变状态，Swift 6 严格并发必炸（GlobalHotKey.swift:5, 179-251）。
- `VoiceModeRouter` 跨字符串复用 `String.Index`（VoiceCommandRouting.swift:29-35），Swift 不保证的用法。
- 审计 append 全部 `try?` 静默吞错——「事实源」写失败应至少置用户可见标志。
- `AgentMemoryStore` 迁移事务无回滚（BEGIN 失败照跑、insert 失败仍 COMMIT）。
- 主线程性能：init 同步 backfill 中文 NLEmbedding、每次 record() 全表扫描+重算 insights、`memory_snapshots` 每事件一行无限增长、多 MB 音频在 MainActor 上 base64（AgentMemoryStore.swift:56-62, 433-442, 667-684；AppModel.swift:1335-1346）。
- sidecar：`readJsonBody` 裸 cast，`task`/`question` 缺失静默变 `""` 照跑全流程（应 400）；四个 provider 客户端近似复制的 JSON 解析/错误提取（提取 `provider/http.ts`）；所有出网 fetch 无 `AbortSignal.timeout`；agent loop 对 MCP 工具结果无大小预算（大结果撑爆上下文，经 P1-1 变 HTML 500）；配了远程 Whisper 也无条件启动本地 MLX 进程白吃数百 MB 内存（server.ts:121-136）；dev 相对路径 + README 的 `cd sidecar` 启动方式已实际产生**两份数据库**（`sidecar/.data/` 与 `sidecar/sidecar/.data/` 并存，env.ts:24 默认值应基于 `import.meta.dir` 解析）。
- configStore：先写后 chmod 有 0644 窗口（应 `writeFileSync(path, data, {mode: 0o600})`）、无 tmp+rename 原子写、损坏时静默回落空配置；`maskApiKey` 对 9 字符 key 露出 8 字符（阈值提到 ≥12）；baseUrl 零校验（保存时 `new URL()` + 限定 http/https + 去尾斜杠）。

**i18n 双轨制**：`OpenTypeL10n.text(_:english:)` 丢弃 english 参数，同时大量视图裸中文字面量走 `LocalizedStringKey` → en.lproj——而 en.lproj 里满是已删功能的旧词条（「X Reply」「外观」等），英文系统下新旧术语混排。短期全部收口到 `OpenTypeL10n`，长期换 String Catalog。

---

## 5. 安全与隐私专项汇总

| 项 | 级别 | 说明 |
|----|------|------|
| 开发者 key 进分发包 | P0-4 | 见上；**建议轮换现有 key** |
| 记忆投毒 + owner_facts 不可见不可删 | P1-12 | 持久 prompt 注入链 |
| key/语音过 argv | P1-13 | `ps` 可见 |
| configStore chmod 竞态 + 非原子写 | P2 | 见 §4 |
| Unix socket 无鉴权 | P2 | 同用户任意进程可读全部对话/改 provider 指向/烧额度；packaged 路径在 App Support（受 ~/Library 权限保护）尚可，dev socket 在 `/tmp` 世界可写目录应挪走；进阶：spawn 时传一次性 token |
| 语音内容持久落盘无治理 | P2 | contextDebugLog 每请求追加前 200 字符、永不轮转、不受「历史重置」影响；SQLite/日志 0644；audit JSONL 只增不减无轮转。建议：数据目录整体 0700、日志轮转、纳入重置范围、加保留期设置 |
| MCP 子进程环境隔离 | ✅ 确认无泄漏 | SDK 白名单环境变量，key 不会传给 MCP server；但「只连无副作用 server」纯靠自律，系统提示还写着「treat any tool as safe」——至少在文档/设置里醒目声明，中期做工具允许清单 + 副作用工具确认弹窗 |

---

## 6. UX / 交互专项

（完整走查含 48 条，这里列改动价值最高的，其余见 P1/P2 已合并项）

**旅程级**：
1. 首启弹窗风暴：init 无条件请求通知权限，叠加麦克风/语音识别/辅助功能（AppModel.swift:205-214）——通知授权推迟到首次 Agent 下发时。
2. 「开始试用」练习按钮是**死 UI**：SetupCard 仅在 `!setupReady` 渲染（Views.swift:213-215），内部按钮却要求 `setupReady`（Views.swift:466-476），条件互斥，练习功能不可达。已核读确认。设置就绪后应以独立卡片保留练习入口。
3. Review 面板：点击面板外部=无确认静默丢弃全部内容（ReviewPanelController.swift:197-207）——长口述+几轮纠错误点一下就全没了。改为「点外部收起」或内容已编辑时弹确认。面板不可拖动且固定居中，可能正好盖住目标输入框；「再按热键=语音纠错」只有 10pt footer 一处教学；面板打开期间热键被完全征用（无法开始新听写）且无任何说明。
4. Ask 弹窗：答案纯 `Text` 渲染，markdown 原样露出；无复制/追问/「在主窗口打开会话」按钮——多轮追问要经主窗口四步操作，成本过高（AskPanelController.swift:174-179）。
5. 连续两次 Ask 不构成对话：新会话的 `conversationId` 返回后不自动 focus（AppModel.swift:1473-1475），弹窗内连续问两个相关问题各自成新会话。建议：弹窗存续期间默认延续上一会话，或提供「追问」按钮。

**热键系统**：
6. 左 Option 长按 0.3s 触发，但 Option+拖拽/点击/滚轮等纯鼠标手势不会取消计时（GlobalHotKey.swift:197-218, 527）——按住 Option 拖文件即误触录音。默认预设建议改为误触面更小的 fn 或双击 Ctrl。
7. 模式循环 chord 永远绑定左 Option+Shift/Tab，与用户所选热键脱节（GlobalHotKey.swift:365-395）；popover 的提示文案对 fn/双击用户是错误指引。
8. `⌃Space` 预设与 macOS 输入法切换默认键正面冲突而 note 无提示（Models.swift:465-467）。
9. USER_GUIDE 宣称「录音过程中可切换模式」，实现却 guard `state != .listening`（AppModel.swift:448-451）——文档与实现二选一。
10. 无录音计时显示、无最大时长保护（双击进入连续录音后忘了就无限录）。

**状态与视觉**：
11. overlay 固定主屏底部中央，不跟随焦点屏/光标；多屏可能出现在错误屏幕（OverlayController.swift:97-103）。
12. 菜单栏图标 `isTemplate = false` 彩色方块违反 HIG，状态纯靠颜色编码，色觉障碍不可区分（OpenTypeApp.swift:296-360, 428-438）。
13. 字号全部硬编码且大量 8.3-9pt 三级灰正文；无文本样式体系；不适配动态字体；固定面板尺寸。强调色硬编码不随系统 Accent；成功色蓝/绿混用。
14. 术语混乱：同一动作「写入/插入/粘贴」三种叫法；ask 处理中 overlay 显示「正在整理」弹窗显示「正在思考」；「Sidecar」「Agent Runtime」等实现词汇直接面向用户；模式名中英混排（听写/问答/Agent）。
15. 可访问性：纯图标按钮缺 `accessibilityLabel`（popover 齿轮、会话返回、弹窗关闭）；选中态仅靠视觉圆点无 `.isSelected` trait；主窗口 tab 无 Cmd+1…5。
16. 「转写语言」选择器名不副实：27 种语言只影响 Apple 实时字幕预览、不影响 Whisper 最终识别（Models.swift:138-142）——改名「实时字幕语言」，或真正把语言 hint 传给 Whisper（见 §8-2）。
17. Provider 设置：改任何配置都要重贴 API key（masked 不回填）；保存不强制先测试，坏配置到下次录音才暴露。

---

## 7. 测试与工程实践

**现状**：sidecar 测试质量高于平均（真路由+真 `:memory:` SQLite+注入 fetch，211 个）；Swift 59 个全是外围纯逻辑，**核心管线零覆盖**（`AppModel.init` 副作用导致不可实例化于测试）。无 CI。

**最值得补的测试（性价比排序）**：
1. `SidecarClient.request` 全链路：1MB body（抓 P0-1）、>64KB 响应（抓 P0-2）、非 2xx、超时——一个本地 mock Unix-socket server 即可。
2. `ReviewPanelController` 两次会话生命周期（抓 P0-3）。
3. `AppModel.process()` 管线：三模式分派、审计事件序列、开关矩阵——前置工作是把 `SidecarClient`/`ContextBridge` 协议化注入。
4. sidecar router 的「handler 抛错时 HTTP 层表现」（正是它掩盖了 P1-1）。
5. `server.ts` 的 `resolveChat`/`resolveTranscribe` 内联在 `main()` 里不可测——提出为导出工厂函数。
6. `GlobalHotKey` 手势状态机（先抽纯逻辑）；`OverlayController` 状态→隐藏映射（抓 P1-18）；`ErrorMessagePresenter` 对 `SidecarClientError` 的映射。

**工程**：加 GitHub Actions（`swift test` + `bun test`，macOS runner）；per-worktree 运行时资源命名空间（as-built spec §11 已记录的 socket/DB 互踩）；`swift-format`/`eslint` 基线。

---

## 8. 产品功能建议（对标 Wispr Flow / superwhisper / MacWhisper）

按「差异化价值 ÷ 实现成本」排序：

1. **【快赢·差异化核心】实体词典反哺 ASR**。记忆系统已经在积累实体词典（canonical term + aliases + confidence），但 [serve.py](sidecar/whisper/serve.py) 调 `mlx_whisper.transcribe()` 只传了 `path_or_hf_repo`——把高置信度词条拼成 `initial_prompt` 传入（mlx-whisper 原生支持），专有名词识别率立涨；再叠加转写后的别名替换（aliases→canonical 的确定性文本替换，无需 LLM）。这正是 CLAUDE.md「context-aware speech-to-text correction」愿景的第一块落地，也是 OpenTypeless 明确没做的（其 reference 文档自认 no ASR-level biasing）。
2. **【快赢】把「转写语言」变成真的**：`/asr/transcribe` 增加 `language` 参数透传 `mlx_whisper.transcribe(language=…)`，设置项即刻名副其实（混合中英场景 auto 仍是默认）。
3. **【快赢】词典/替换规则管理 UI**：实体词典目前只读、唯一写入方式是对 Agent 口述「记住…」——做成 Settings 里可增删改的表格（顺手解决 P1-12 的可见性问题），这是 superwhisper/MacWhisper 用户的高频刚需。
4. **轻整理档位**：在「一字不改」与「问答」之间补一个可选开关：去口癖（嗯/呃/um）、断句、标点规整（先做确定性规则版，后做 LLM 版）。这是砍掉旧 polish 模式后留下的真实空档，也是 Wispr Flow/superwhisper 的默认体验。
5. **流式体验**：Ask 答案流式渲染、Agent 步骤实时推送（loop.ts 的 `onProgress` 钩子已存在，只差 SSE/chunked 传输——这也是换掉 curl 传输层的又一理由）、录音结束前对已缓冲音频做分段预转写降低整体时延。
6. **按 app 的行为规则**：`bundleIdentifier` 已被采集（ContextBridge.swift:34-41）——落地为「微信=直出、IDE=英文优先、邮件=复核模式」的 per-app 默认，是竞品「context awareness」的本地版。
7. **MCP 工具配置 UI**：当前只能靠 `OPENTYPE_MCP_SERVERS` 环境变量，打包 app 用户实际无法给 Agent 接任何工具——Agent 模式的产品价值被锁死在两个内置记忆工具上。Settings 加 MCP server 管理（含「此工具可能产生副作用」标注 + 允许清单，联动 §5 安全项）。
8. **历史体验**：搜索/筛选/单条删除/「粘贴上一条」全局热键；HistoryStore 目前 JSON 100 条上限（竞品全量保留+全文搜索）；顺带统计面板（本周听写字数/节省时间，Wispr 式留存钩子）。
9. **Whisper 模型选择**：`OPENTYPE_WHISPER_MODEL` 已支持环境变量覆盖，暴露成 Settings 里的 small/medium/large-v3-turbo 选择器 + 下载管理（MacWhisper 的核心 UX）。
10. **录音安全网**：录音计时显示、连续录音超时提醒、（联动 P1-10）Esc 取消。

**暂不建议做的**：第二平台（iOS/Android 刚刚整体移除，方向已定）；云端账户/同步（与 local-first 定位冲突）；自研 ASR 微调（词典偏置的性价比高一个数量级）。

---

## 9. 文档一致性核查 + 愿景-实现差距

本仓库把文档当一等公民（CLAUDE.md 明文要求），所以文档失真按 bug 对待。核查覆盖 CLAUDE.md、README、USER_GUIDE、sidecar/README、3 个 reference、5 个 spec，逐条对码。

### 9-A 「文档说 X，代码实际是 Y」（重大项）

1. **Swift 侧记忆「注入 Agent 上下文（~12 条预算）」是假的**。CLAUDE.md 与 current-state §6 均如此描述；实际 `/agent/run` 请求体只有 `task + selectedText + conversationId`（AppModel.swift:1690-1698），`entriesForPrompt` 一族与 `LocalMemoryRetriever.swift` 生产端零调用。USER_GUIDE §10「已学到的偏好」参与优先级的暗示同样失真。
2. **「周期性/自动 consolidation」不存在**。`shouldConsolidate`（12h+≥5 事件门，consolidator.ts:44-72）全仓库无调用方；只有 Settings 按钮与 agent 工具两条手动路径，且都绕过该门。`AGENT_SYSTEM_PROMPT` 里 "bypasses the normal automatic schedule" 指向一个不存在的 schedule。
3. **episodic 层只收 agent 事件**：只有 `/agent/run` 自记（agent/routes.ts:94-103）；transcribe/ask 完成事件不进 episodic → dreaming 的原料实际只有 agent 任务，`consolidate_memory_now` 工具描述 "review recent dictation history" 名不符实。
4. **隐私披露失真（两处）**：(a) USER_GUIDE §13 说只发送「少量与本次输入**相关**的已知术语」，实际 `buildOwnerFactsContext`（memoryContext.ts:40-46）把**全部** owner_facts 无条件注入每次 ask/agent 请求；(b) `context-debug.log` 持久记录每次 ask/agent 输入文本（截断 200 字符），USER_GUIDE §13 的本机存储清单与 README 隐私节均未列出，「重置输入历史」也不清理它。
5. **Memory 面板并非纯只读**：`POST /memory/consolidate-now` 是写端点，CLAUDE.md/sidecar README/current-state §2 端点表三处漏记；§2 表还漏 `POST /transcribe/correct` 与全部 7 个 `/config/*` 路由。
6. **「无 MCP 则 Agent 调不了任何工具」已过时**：两个内置记忆工具无条件可用（server.ts:106-108），current-state §3 与 CLAUDE.md 未更新（USER_GUIDE §7 写对了）。
7. **USER_GUIDE §2「录音过程中切换模式」与代码矛盾**：`cycleMode()` guard `state != .listening`（AppModel.swift:448-451），chord 实际只在「按住修饰键但录音未启动」的窗口生效；录音中唯一换模式途径是「agent 模式」口令。
8. **CLAUDE.md 称 HistoryStore「SQLite-backed」**：实为 JSON 文件、100 条上限（HistoryStore.swift:28, 12）。
9. 其余中轻度失真：README「双击 Ctrl+Option+Shift」读起来像三键同双击、实为三个独立 preset；README/CLAUDE.md 未跟上 build-app.sh 已支持的 opt-in 公证签名（最近 3 个 commit）；CLAUDE.md/current-state §5 审计枚举漏 `.corrected`；current-state 记载 Swift 测试 64/64、实测 59/59；SidecarClient.swift:300 注释称无 `applicationWillTerminate` 钩子、实际存在（OpenTypeApp.swift:112-113）；sidecar README 漏列 builtInTools/toolSets/contextDebugLog 三个文件、`/oneshot/ask` 仍写 "one DeepSeek call"；「About Me」profile 在 current-state §6 仍列为在用系统、实际已不可填写不可注入，是仅存库表的死数据。

### 9-B current-state §11 known gaps 复核

13 条逐一复核：全部**仍成立**（无一条被悄悄修复），其中「无 Memory 回滚 UI」可以更肯定——`rollbackConsolidationRun` 内部已完整实现，只差路由与 UI。建议向 §11 **补录** 5 条本次新发现的 gap：自动 consolidation 未接线、Swift 记忆注入断线、episodic 只覆盖 agent、owner facts 全量注入未披露、context-debug.log 无治理。

### 9-C 设计愿景 vs 实现（specs + references）

- **Module A（context-aware 转写纠错）完全未开始**：实体词典对任何转写路径零参与，`.transcribe` 纯透传，`/transcribe/correct` 不带 MemoryStore（server.ts:60）。已有决策记录：对标 OpenTypeless 的 prompt 注入水平、不做语音学匹配（closed topic）——但连这个降级版也还没做。
- **OpenTypeless reference 点名可借鉴、完全没动的**：可编辑词典+导入导出（现方向相反：编辑 UI 被删）；"always use these exact spellings" 指令式注入 + pattern→replacement 对（现只有一行 "Known terms: X, Y."，且不进任何转写 prompt）；ASR 级 hotword/initial_prompt 偏置（双方共同空白，OpenType 的机会）。
- **OpenClaw reference 点名可借鉴、完全没动的**：trigger-phrase+importance 的预过滤限额注入（现在是全表子串扫描+owner facts 无条件全量，与 reference 强调的 budget 受控注入相反）；两 lane 检索；provenance 结构性 gating（origin 列三张表都有但 consolidation 取候选不按 origin 过滤——`/agent/run` 已把含 MCP 工具输出的内容写入 episodic 层，reference 说的「开始摄入非 owner 内容就该 gating」前提已成立而 gating 缺席，与 P1-12 同根）。
- **已消失的设计承诺**：忠实性 validator（fidelity.ts 随 3 模式裁剪删除，仅剩 Review 按 offset 拼接的结构性保证）；B2 spec 要求的「provider 无原生 tool-calling 时 Settings 明示 Agent 不可用」未实现（自建兼容端点不支持 tools 时静默失败）。
- **超预期完成的**：Ask/Agent 会话续接（超出原 spec 的增量）、Review 审计链、非阻塞 Agent 下发。

---

## 10. 给 Opus 的执行顺序建议

**Phase 1 — 止血（每条半天内，先测试后实现，逐条提交）**：
1. P0-1 + P1-13：curl body 改临时文件/stdin 传输（一个改动消两颗雷）
2. P0-2：并发排空管道 + `--max-time` + 取消传播
3. P0-3：Review 面板会话重置
4. P0-4：build-app.sh 排除 `.env.local` + 轮换已泄漏 key
5. P1-1 + P1-2 + P1-3：sidecar router 统一错误 envelope + Swift 侧错误映射 + 清残留文案

**Phase 2 — 可靠性（1-2 天）**：
6. P1-4~P1-9：进程监督/自动重启/信号清理/首启下载容错/单实例守卫（一个「进程生命周期」主题分支）
7. P1-10 + P1-11 + P1-18：取消体系 + Ask 非阻塞 + overlay 隐藏
8. P1-14：consolidation 事务化

**Phase 3 — 信任与默认值（1-2 天）**：
9. P1-12：owner_facts 可见可删 + origin 溯源修正
10. P1-15~P1-17 + P1-19：剪贴板选项、插入目标校验、ask 默认不插入、onboarding 跳过路径
11. **记忆系统接线决策**（§9-A1/A2/A3）：三选一并落实——(a) 把 Swift 侧记忆按文档承诺注入 agent context；(b) 判定其为死层整体删除、统一到 sidecar 记忆；(c) 保留采集但明确降级文档。同时补 episodic 全模式采集 + 自动 consolidation 触发（launch/quit 检查 `shouldConsolidate`，spec1 §4.4 本来就是这么设计的）。**无论选哪个，先把失真文档改对**（CLAUDE.md/USER_GUIDE §10/§13 的记忆与隐私描述）。

**Phase 4 — 打磨与增长（按 §8 顺序做 1-3-4-2）**

**过程要求**（来自 CLAUDE.md，不可省略）：每条走 4 阶段 TDD 管线；`docs/superpowers/specs/2026-08-09-current-system-state.md` 与 USER_GUIDE/README 在相应行为变化时同步更新（把文档更新当作完成定义的一部分）；长录音（P0-1）与管道死锁（P0-2）修复后，务必用真实打包 app + 真实长音频回归一次（as-built spec 的验证一节有现成方法论）。

---

*评审人：Claude（Fable 5），2026-08-10。四个专项子评审（Swift 全量 / sidecar+安全 / UX 走查 / 文档一致性）的原始报告未随库存档，如需可向本次会话索取。*
