# DeepSeek Harness 借鉴计划 — OpenType agent runtime

日期：2026-08-13（2026-08-14 校订：对齐 `dc31b91` 统一语音面板落地后的实际代码）
状态：待实现 — **T1–T9 全部在范围内**，建议执行顺序见 §14

## 1. 背景

DeepSeek 于 2026-08 开源了 `dsh`（DeepSeek Harness），一个插件化的 agent harness。
完整通读笔记在**另一个仓库**：`../deepseek-harness/docs/analysis/`
（`01-overview.md` / `02-architecture.md` / `03-mechanism-catalog.md` / `04-opentype-takeaways.md`）。

它的核心结论：`dsh` 的 agent 循环本体只有 1643 行，压缩、审批、超时、护栏、技能目录、
工作区指令注入**一行都不在循环里**——全部挂在循环留出的几个 waterfall 扩展点上。
这证明一个小循环可以在不被改动的前提下长出这些能力。

本文件只保留**决定要落到 OpenType 的部分**，以及为什么。不需要读 dsh 就能执行本文件。

## 2. 现状（截至 `7a749f4`）

`sidecar/src/agent/`：

| 文件 | 行 | 职责 |
|---|---|---|
| `loop.ts` | 211 | `runAgentLoop`：装消息 → 带工具调模型 → 执行工具 → 回灌。`MAX_ITERATIONS = 10`，`MAX_TOOL_RESULT_CHARS = 20_000` |
| `toolSets.ts` | 77 | `ToolSet = { openAiTools, callTool }`，`mergeToolSets` / `filterToolSet` |
| `approval.ts` | 51 | `ApprovalPolicy` seam + `withApproval`，目前只有 `yoloApprovalPolicy` |
| `coreTools.ts` | 577 | bash / python / read_file / list_dir / grep / web_search / web_fetch / open_file。`DEFAULT_EXEC_TIMEOUT_MS = 60_000`，`SOURCE_CLAMP_MAX_CHARS = 25_000` |
| `builtInTools.ts` | 200 | 记忆工具 |
| `mcpClient.ts` | 173 | MCP server 接入 |
| `progressRegistry.ts` | 128 | 进程内**展示用**进度 feed，`GET /agent/progress/:runId` |
| `routes.ts` | 188 | `POST /agent/run`（阻塞），会话续跑，记忆上下文注入 |

测试在 `sidecar/test/agent/*.test.ts`（10 个文件，与 src 同构）。

**Swift 侧**（行号核对于 `7a749f4`）。注意：**主窗口 UI 没有变**——最近加的唯一新入口是
**实时字幕输入提示栏**，它在用户说完之后**morph 成一个临时会话卡片**
（`dc31b91`，spec `docs/superpowers/specs/2026-08-13-hud-morph-result-surface-design.md`）。

- `AppModel.dispatchAgentRun`（`AppModel.swift:2236`）把 `/agent/run` 作为 **detached Task** 发出，
  **总是**带一个客户端生成的 `runId`（`AppModel.swift:2261`）；
- `AppModel.startAgentProgressPolling`（`:2288`）以 ~0.7s 轮询 `GET /agent/progress/:runId`，写进 `agentPanelState`；
- UI 是**一个**底部居中 `NSPanel`（`OverlayController.swift`，851 行），由纯 reducer
  `VoiceSurfaceState.reduce(mode:processing:ask:agent:)`（`Models.swift:251`）推导。
  `AskPanelController` / `AgentProgressPanelController` 已删除；
- 面板状态机：`hidden | listening | processing | working(WorkingDetail) | result(ResultCard) | failed(ResultCard)`。
  结果卡片现有三个动作：**复制 / 打开主窗口 / 关闭**（`OverlayController.swift:779-791`）；
- `dismissVoiceSurface()`（`AppModel.swift:1052`）走 `VoiceSurfaceState.dismissalEffect`：
  **只有还在思考的 ask 会被取消，dismiss 一个 agent run 从不取消它**——注释写明这是刻意的
  （"面板是 run 的一个视图，不是它的所有者"）；
- `AgentRunRecord.Status`（`AgentRunTracking.swift:12`）= `running | completed(String) | failed(String)`，
  **没有取消态**；
- Agent tab 有一条「进行中」条带（`Views.swift:843` `AgentConversationsView` → `:1770` `AgentRunRow`），
  按 `agentRuns.filter { $0.status.isRunning }` 列出在跑的 run；菜单栏弹窗显示运行中计数
  （`MenuBarPopoverView.swift:186`）。

### 这个面板是**临时**的 —— 三条对本计划有影响的 reduce 规则

`VoiceSurfaceState.reduce` 的文档化顺序里有三条会直接影响 T1/T5 的 UI 设计：

1. `.listening` **无条件优先**——用户开始新一次录音，面板立刻回到 pill，
   哪怕有一个 agent run 还在跑（那个 run 继续跑，状态保留，只是**看不见了**）；
2. **只看当前模式的面板状态**——切到 ask 模式，在跑的 agent run 的面板就不显示了；
3. **只显示最近一次 dispatch 的 run**——更早的 run 继续跑，但没有任何面板。

⇒ **只把取消入口放在这个面板上是不够的**：一个"你一开口说话就消失"的停止按钮不是停止按钮。
见 §5.7。

## 3. 已确认的问题

| # | 问题 | 证据 |
|---|---|---|
| **G1** | **全链路没有任何取消**。`sidecar/src/agent/` 和 `src/oneshot/` 里 `AbortSignal` 出现 **0 次**。Swift 侧取消只 SIGTERM 掉 curl 子进程，**sidecar 的循环照跑不误**——继续烧 token、继续在无沙箱下执行 bash | `grep -rn "AbortSignal\|AbortController" sidecar/src/agent sidecar/src/oneshot` → 空 |
| **G2** | 没有整轮 wall-clock 预算。只有 10 次迭代上限，10 × 60s ⇒ 单次 `/agent/run` 最长可阻塞 ~10 分钟 | `loop.ts:73`、`coreTools.ts:48` |
| **G3** | 超长工具结果是**丢弃**（两级：源头 25k、循环 20k），模型知道被截断但**无法取回剩余部分**——尽管 `opentype__read_file` / `opentype__grep` 就在手里 | `loop.ts:90` `clampToolResult`、`coreTools.ts:65` `clampAtSource` |
| **G4** | 没有循环退化检测。模型反复调同一个工具同一组参数时，10 步烧完返回"跑完步数还没有最终答案" | `loop.ts:205` |
| **G5** | agent 不知道现在几点。prompt 里没有任何时间锚点，而语音输入充满相对时间（"明天""刚才""这周"） | `oneshot/prompts.ts`、`agent/routes.ts:116` |
| **G6** | agent 不能反问，只能猜。语音天然模糊（同音字、指代、省略） | 无 `ask_user` 类工具 |
| **G7** | 审批词汇是二值的，分不清"用户拒绝"和"没有应答通道"；无审计记录 | `approval.ts:20` |
| **G8** | 步骤日志有两份平行表示（响应里的 `steps` + `progressRegistry`），且都不持久 | `routes.ts:145`、`progressRegistry.ts` |

## 4. 非目标（明确不抄）

- Cordis 插件内核、profile / bundle / preset 组合层
- 完整的 session 事件溯源 + surface/surfaceOp 投影
- Compaction（摘要式上下文压缩）
- Code Mode、子代理、workflow
- 沙箱（项目已明确 YOLO 决策）
- 45 包拆分、100% 覆盖率门禁、Typert RPC 网关

理由：这些是"多人长期维护一个平台"的成本。OpenType 的 sidecar 一共 ~6000 行，agent 子系统 1600 行。

### UI 范围（同样是非目标）

**本计划不重做任何 UI。** 主窗口五个 tab、菜单栏弹窗、Review 面板、transcribe 路径
一律不动。Swift 侧的全部改动限于三处，且都是往**既有**控件上加东西：

| 处 | 改什么 | 属于 |
|---|---|---|
| 语音面板（`OverlayController`）——即实时字幕输入提示栏 morph 出的临时会话卡片 | 加「停止」动作；加 question card 形态 | T1 / T5 |
| Agent tab 「进行中」条带的 `AgentRunRow` | 加「停止」按钮 | T1 |
| `Models.swift` 的纯状态类型 | `VoiceSurfaceState` 加判定与形态、`AgentRunRecord.Status` 加取消态 | T1 / T5 |

T2 / T3 / T4 / T6 / T7 / T8 / T9 **完全不碰 Swift**。

---

## 5. T1 —— 全链路取消 + 整轮预算（对应 G1/G2）· P0

### 要做什么

把一个 `AbortSignal` 从 HTTP 入口穿到每个工具的系统调用。

**5.1 `ToolSet` 契约扩展**（`toolSets.ts`）

```ts
export interface ToolSet {
  openAiTools: unknown[]
  callTool: (name: string, args: unknown, signal?: AbortSignal) => Promise<{ content: string }>
}
```

`mergeToolSets` / `filterToolSet` / `withApproval` 三个组合器都必须**原样转发** signal。
借鉴 dsh 的一条硬约束：**包装器可以替换 signal，但绝不能移除它**——
`withApproval` 在拒绝时不需要 signal，但透传路径必须带上。

**5.2 各工具集实现**

- `coreTools.ts`：`runProcess` 已有 SIGTERM → 2s → SIGKILL 的升级杀，signal abort 时走**同一条**路径；
  `web_search` / `web_fetch` 的 `fetch()` 直接接受 signal。
- `mcpClient.ts`：MCP SDK 的 `callTool` 支持 `RequestOptions.signal`，转发即可。
- `builtInTools.ts`：本地 SQLite 操作是同步的，接受 signal 但可以不用（在调用前检查一次 `aborted`）。

**5.3 循环**（`loop.ts`）

- `RunAgentLoopDeps` 加 `signal?: AbortSignal`；
- 每次迭代顶部检查 `signal.aborted`；每个工具调用返回后再检查一次；
- 已中止时抛出一个可判别的 `AgentCancelledError`（不是普通 Error），**不再发起下一次模型调用**；
- 模型调用本身（`AgentChatFn`）也应接受 signal —— 扩展 `options` 为 `{ tools?, signal? }`。

**5.4 整轮预算**

新常量 `AGENT_RUN_BUDGET_MS`（建议默认 `5 * 60_000`），与调用方 signal **融合成一个** signal
（`AbortSignal.any([caller, AbortSignal.timeout(budget)])`）。
借鉴 dsh 的做法：超时的判定依据是**哪个 signal 烧的**，而不是结果形状——
所以要能区分"用户取消"和"预算耗尽"，两者返回不同的原因。

**5.5 取消注册表 + 端点**

新文件 `sidecar/src/agent/cancellation.ts`：一个 `runId → AbortController` 的进程内注册表
（`register(runId) => AbortController`、`cancel(runId): boolean`、`release(runId)`）。

> 刻意**不**塞进 `progressRegistry.ts`：那个文件的文档明确说自己是"DISPLAY feed only"，
> 混入控制职责会破坏它已声明的边界。

新端点 `POST /agent/cancel/:runId`：
- 未知 id **不是错误**（沿用 `GET /agent/progress/:runId` 已确立的先例），返回 200 `{ cancelled: false }`；
- 成功取消返回 200 `{ cancelled: true }`。

**5.6 被取消的 run 如何收场**

- `progressRegistry` 的 `finish(runId, status)` 增加 `"cancelled"` 状态（现有的 `AgentProgressRunStatus`
  是 `"running" | "done" | "failed"`，Swift 侧的解析要同步）；
- `/agent/run` 的响应必须让 Swift 能**区分取消和失败**：取消返回 HTTP 499 + 现有错误信封，
  `code` 字段为 `"agent_cancelled"`；
- **不写** `recordEpisodicEvent`（被取消的 run 不是一次完成的任务）；
- 会话里已 append 的 user 消息保留（它确实发生过），不 append assistant 消息。

**5.7 Swift 侧入口**

两个**不要**：

- ⚠️ **不要**用"再按一次热键"——热键是开始/停止录音，agent 运行期间按它会开始新一次录音。
- ⚠️ **不要**改 `VoiceSurfaceState.dismissalEffect` 对 agent 的语义。
  "dismiss 一个 agent run 从不取消它"是有注释的、刻意的决定（关闭面板 ≠ 停止任务）。
  **取消必须是一个独立的、显式的动作。**

因为语音面板是**临时**的（§2 那三条 reduce 规则：一开口就被 `.listening` 顶掉、
切模式就不显示、只显示最近一次 dispatch），**需要两个入口**：

**主入口 —— 语音面板（run 可见时）**

在 `.working(kind: .agent)` 和 `.failed` 状态下，于现有「复制 / 打开主窗口 / 关闭」旁
增加一个**「停止」**动作。实现方式：给 `VoiceSurfaceState` 增加一个纯派生的
"当前是否有可停止的 run"判定（连同它的 runId），**不要**挂进 `dismissalEffect`。

**兜底入口 —— Agent tab 的「进行中」条带**

`AgentRunRow`（`Views.swift:1770`）在 `status == .running` 时增加一个「停止」按钮。
这是覆盖"面板已经不在了但 run 还在跑"的唯一途径，也是同时停掉多个并发 run 的地方。
这是对**既有** UI 的小增补，不是新界面。

**共同部分**

1. 新增 `AppModel.cancelAgentRun(runId:)` → `POST /agent/cancel/:runId`；
2. `AgentRunRecord.Status` 增加 `case cancelled(String)`
   （现有是 `running | completed(String) | failed(String)`）；
   `isRunning` 对它返回 false，于是菜单栏计数和「进行中」条带自动收敛；
3. `AgentProgressPanelState.Phase` 也需要一个取消态，或复用 `.failed` 但文案区分——
   **实现时二选一并说明理由**（倾向新增 `.cancelled`，因为把用户主动取消显示成"失败"是错的）；
4. 「关闭」按钮的行为**保持不变**。

附带收益（可选，不属于本项验收）：`dismissAskPanel()` 目前 `askTask?.cancel()` 只杀掉 curl，
sidecar 的 `/oneshot/ask` 仍在跑。T1 把 signal 穿到 `AgentChatFn` 之后，ask 也能真正被叫停。

### 验收标准

1. `loop.ts` 在 signal 已 abort 时**不发起**下一次模型调用（用一个计数 mock `chat` 断言）。
2. 一个长跑的 `runProcess` 在 signal abort 后被杀掉，且 `callTool` 以错误结果收场而不是挂起。
3. `mergeToolSets` / `filterToolSet` / `withApproval` 三者都把 signal 转发到底层集合（各一个测试）。
4. `POST /agent/cancel/:runId` 对未知 id 返回 200 `{cancelled:false}`；对活跃 run 返回 200 `{cancelled:true}` 并使该 run 收场。
5. 预算耗尽和用户取消产生**不同的**原因标识。
6. 被取消的 run 不产生 `recordEpisodicEvent`。
7. `AgentRunRecord.Status.cancelled` 的 `isRunning` 为 false（一个纯单元测试），
   因而菜单栏计数和「进行中」条带在取消后自动收敛。
8. `VoiceSurfaceState` 新增的"可停止"判定：`.working(kind:.agent)` 为真、
   `.working(kind:.ask)` 与 `.listening` / `.processing` / `.hidden` 为假（纯 reducer 测试）。
9. **回归**：`dismissalEffect` 对 agent 仍然是 `.none`——现有测试不得被改动或削弱。

### 触及文件

sidecar：`src/agent/{toolSets,loop,coreTools,mcpClient,builtInTools,routes,progressRegistry}.ts`、
新增 `src/agent/cancellation.ts`、`src/provider/*`（chat 的 signal 透传）。

Swift：`AppModel.swift`（`cancelAgentRun(runId:)`）、`Models.swift`（`VoiceSurfaceState` 可停止判定、
`AgentProgressPanelState.Phase`）、`AgentRunTracking.swift`（`Status.cancelled`）、
`OverlayController.swift`（面板「停止」动作）、`Views.swift`（`AgentRunRow` 「停止」按钮）、
`SidecarClient.swift`（新端点）。

⚠️ 主窗口的其余部分、菜单栏弹窗、Review 面板、transcribe 路径**都不动**。

---

## 6. T4 —— 时间上下文（对应 G5）· P0

### 要做什么

新文件 `sidecar/src/context/timeContext.ts`：

```ts
/** @param now 注入以便测试；省略时用 new Date() */
export function buildTimeContext(now?: Date): string
```

输出（英文，与现有系统提示语言一致）：

```
Current time: 2026-08-13 23:20:15 +08:00 (Asia/Shanghai, Thursday)
```

**必须包含星期几** —— 中文语音里"下周三""这周末"没有星期锚点就无法解析。

时区解析顺序：`process.env.TZ` → `Intl.DateTimeFormat().resolvedOptions().timeZone` → `UTC`。

借鉴 dsh 的一个判断：**时区不明时告诉模型去问用户澄清，不要猜**。
落到我们这边——解析不出 IANA 时区时，文本追加一句
`Time zone could not be determined; ask the user to confirm before acting on a relative date.`

### 接线

- `agent/routes.ts`：接进 `runAgentLoop` 的 `knownTerms` 同一位置（`buildInitialMessages` 的 user 内容里），
  作为独立的一行/一段，**不要**塞进系统提示（系统提示要保持前缀稳定，见下）。
- `oneshot/routes.ts`（Ask 路径）：同样接进 user 消息。

> **为什么不放系统提示**：借鉴 dsh 的 KV cache 纪律——系统提示是每次请求的可复用前缀，
> 往里塞每次都变的时间戳会让整个前缀失效。放在 user 消息里是 append-only 的。

### 验收标准

1. `buildTimeContext(new Date('2026-08-13T15:20:15Z'))` 在 `TZ=Asia/Shanghai` 下产出确定的、包含
   `2026-08-13`、`+08:00`、`Asia/Shanghai`、`Thursday` 的字符串。
2. 时区解析失败时输出包含那句澄清指令。
3. `/agent/run` 和 `/oneshot/ask` 的模型入参里都包含该行（各一个测试）。
4. 该行**不在**系统提示里。

### 触及文件

新增 `sidecar/src/context/timeContext.ts` + `sidecar/test/context/timeContext.test.ts`、
`sidecar/src/agent/routes.ts`、`sidecar/src/oneshot/routes.ts`。

---

## 7. T2 —— spill 替换丢弃式截断（对应 G3）· P1

超限的文本结果不再丢弃，而是落盘 + 返回**预览 + 定位符 + 取回提示**。
我们几乎免费，因为取回路径已经存在：`opentype__read_file` / `opentype__grep`。

新文件 `sidecar/src/agent/spill.ts`：

```ts
saveSpill(text: string, src: { toolName: string; runId?: string }): Promise<string | null>
```

- 目录：sidecar 数据目录下的 `spill/<runId 或 session>/`，权限 `0700`；
- 文件：`open(path, 'wx', 0o600)` **独占创建**（防符号链接重定向），文件名从工具名**消毒后派生**，不等于它；
- 失败返回 `null` ⇒ **回落到现在的 `clampToolResult`**。best-effort：
  **绝不能把一次成功的工具调用变成错误结果**。

替换后的结果文本形如：

```
<head 预览>
…[<N> chars total, saved to <path>]…
<tail 预览>
Use opentype__read_file or opentype__grep on that path to read the rest.
```

`coreTools.ts` 的源头 25k 钳制同样改成走 spill。

**验收**：超限结果产生一个 0600 的文件且返回文本含路径与取回提示；保存失败时退回截断且结果仍是成功态；
`read_file` 能读到落盘内容。

---

## 8. T3 —— 重复调用护栏（对应 G4）· P1

新文件 `sidecar/src/agent/repeatGuard.ts`，~60 行。

链键 = `${name}:${JSON.stringify(深度key排序(args))}`。相同 ⇒ 计数 +1；不同的**被跟踪**调用 ⇒ 重置为 1。
计数命中阈值（默认 `[3, 5, 8]`）时，在该工具结果**之后**追加一条 `role: "user"` 的劝告消息。

**必须一起实现的 5 条判断**（每条都是一个坑的答案）：

1. **被排除的工具对链透明**——既不加也不重置。`grep X → remember_fact → grep X` 仍算连续两次
   （记账类工具不能把死循环洗白）。排除表：记忆类工具（`opentype__remember_fact` 等）。
2. **被审批拒绝的调用照样计数**——模型反复撞同一个拒绝正是最该打断的循环。
   我们的 `withApproval` 返回 `{content: "…was denied…"}`，天然会走到计数点。
3. **检测比较完整的规范化串**；参数预览的截断（默认 500 字符）**只影响提醒文本**，不影响链键。
4. **只劝告，不拦截**。决定权留给模型。
5. **纯内存**，不持久化。它是启发式劝告，不是不变量。

第一档给一句泛化轻推，之后各档给详细版（点名工具 / 连续次数 / 参数预览）。

**验收**：连续 3 次相同调用后消息数组里出现劝告；中间夹一个被排除工具**不**打断计数；
参数不同则重置；劝告是独立的 user 消息而**不是**对工具结果 content 的替换。

---

## 9. T8 —— "Model Experience" 文档规范 · P1（纯文档）

`dsh` 强制要求：任何会影响模型输入的模块，文档里必须写清

```
What the model sees   ← 逐字给出模型看到的文本
Token effect          ← 何时零成本、何时有成本、被哪个配置项约束
KV Cache effect       ← append-only（不破坏前缀复用）还是会让前缀失效
```

**为什么对症**：`CLAUDE.md` 里自己写着记忆层"在读取侧基本是惰性的"、
`entriesForPrompt` / `memoriesForPrompt` / `profileContextForPrompt` 和整个 `LocalMemoryRetriever`
**零生产调用方**，"~12 条近期任务注入 Agent 上下文"这个说法在代码里不存在。
这正是缺少这条规范的后果——**没有任何一处书面记录"到底什么进了 prompt"**。

动作：给现在**真正**在注入的四处各补一节（doc comment 或 `docs/` 下一页）：

1. `oneshot/memoryContext.ts` 的 `buildKnownTermsContext`（`Known terms: …`）
2. `buildOwnerFactsContext`（`What you know about the user: …`，注意它是 origin-gated 的）
3. `oneshot/prompts.ts` 的三套系统提示
4. `agent/routes.ts` 的 `formatPriorTurns`（`PREVIOUS CONVERSATION…`）

再加上本计划新增的 T4 时间上下文、T3 劝告消息、T2 spill 提示。

这一步会**自动暴露**还有哪些注入点是文档声称存在但代码里没有的。

---

## 10. T9 —— 生成式工具目录（· P1，脚本 + 文档）

现在没有任何一处能一眼看全"模型能看到哪些工具、它们的描述是什么"——
schema 散在 `coreTools.ts`（8 个）和 `builtInTools.ts`（记忆工具）里。

新增 `sidecar/scripts/gen-tool-catalog.ts`：

- 从 `buildCoreTools(...)` / `buildBuiltInTools(...)` 实际产出的 `openAiTools` 读取，
  **不要**手写一份平行的清单（手写的必然漂移，这正是要解决的问题）；
- 生成 `docs/tool-catalog.md`：每个工具的 name、description、参数 schema；
- 支持 `--check`：重新生成并与磁盘上的文件比对，不一致则非零退出。

**边界要写进文档里**：MCP 工具是用户配置、运行时动态接入的，**不在**这份目录里；
目录只覆盖内置工具（`opentype__*`）。不写清这一点，读者会以为它是全集。

### 验收标准

1. `bun run scripts/gen-tool-catalog.ts` 产出 `docs/tool-catalog.md`，包含全部 `opentype__*` 工具。
2. `--check` 在文件是最新时退出码 0；在手工改坏文件后非零退出且指出哪里不一致。
3. 生成物顶部有"由脚本生成、勿手改"的标记，以及 MCP 工具不在其中的说明。

---

## 11. T7 —— 步骤日志：一份真相，两个投影（对应 G8）· P2

### 现状与问题

`/agent/run` 响应里的 `steps` 和 `progressRegistry` 是**两份平行表示**，且都不持久：
sidecar 重启就全忘。对一个"无沙箱、无预执行确认"的 YOLO 模式产品来说，
事后可审计几乎是必需的补偿控制。

### 归属决定（重要）

**步骤日志归 sidecar 持久化，不是 Swift 的 `ImmutableAuditStore`。**

理由：`ImmutableAuditStore` 是**按请求**粒度的（`recognized`/`corrected`/`completed`/`cancelled`/`failed`），
而步骤发生在 sidecar 内部；为了持久化每一步而把它们全部搬过 Unix socket 是本末倒置。
Swift 侧的请求级审计**保持现状不动**。

### 要做什么

1. 新文件 `sidecar/src/agent/runLog.ts`：按 runId 追加写的 JSONL，
   落在 sidecar 数据目录下（与 SQLite 同级），权限 0600。每条记录带
   `{ runId, seq, time, type, detail }`，`type` 沿用现有的
   `thinking | tool_call | tool_result | done | error`，
   加上 T1 引入的取消态和 T6 引入的 `approval_asked` / `approval_decided`。
2. `progressRegistry` 变成这条流的**有界内存视图**——现有的三条边界
   （每事件 400 字符、每 run 200 条、保留 20 个已完成 run，丢最旧保最新）
   全部保留，但它们现在是**视图**的边界，不是存储的边界。
3. `/agent/run` 响应里的 `steps` 从同一条流投影。
4. 保留一个按 runId 读取完整日志的内部入口（供将来的 Agent tab 详情用），
   本项不要求接 UI。

**必须保持的性质**：写日志失败**绝不能**让一次 agent run 失败（best-effort，
与 T2 spill 同样的态度）。

### 验收标准

1. 一次 run 结束后，磁盘上存在该 runId 的 JSONL，条数 ≥ 响应里 `steps` 的条数。
2. `progressRegistry` 的三条边界行为不变（现有测试应当仍然通过，不要削弱它们）。
3. 响应里的 `steps` 与日志投影一致。
4. 日志写入抛错时，run 仍正常返回结果（注入一个失败的 writer 断言）。
5. 被取消的 run 在日志里留下可判别的终态记录。

---

## 12. T6 —— 审批词汇 fail-closed 化 + guard 单调性（对应 G7）· P2

seam 已经在（`approval.ts`），缺的是**词汇**和**审计**。

### 12.1 四值封闭结果

```ts
export type ApprovalOutcome = 'allowed-once' | 'rejected' | 'cancelled' | 'unavailable'
export type ApprovalPolicyMode = 'ask' | 'never'
```

- **只有 `allowed-once` 是授权**；`rejected`（用户拒绝）、`cancelled`（问题被撤回，
  例如 T1 的取消到了）、`unavailable`（没有应答通道 / 应答者抛异常 / 返回了词汇外的值）
  一律等于拒绝，**fail closed**；
- **`never` 策略在派发任何应答者之前就短路**，所以后注册的应答者绕不过去；
- 现有的 `yoloApprovalPolicy` 改为返回 `'allowed-once'`，行为不变。

### 12.2 请求不带工具参数

审批请求携带 `{ toolName, callId, reason? }`，**不带 args**。
理由：进度面板已经在显示 `Calling opentype__bash({...})` 了，
审批提示应该挂到**已经展示过的那次调用**上，而不是渲染第二份可能漂移的副本。

### 12.3 guard 单调性

新增一层注册式检查：

```ts
export type ToolGuard = (call: { name: string; args: unknown }) => string | undefined
```

**返回类型里故意没有 allow**：返回 `undefined` = 不表态，返回字符串 = 拒绝。
因此后注册的 guard **永远不可能**把前面的拒绝翻回同意，注册顺序不影响安全结论。
在 `withApproval` 之后、工具本体之前运行。

本项**不要求**注册任何具体 guard（YOLO 决策不变），只要求这个位置和类型存在且被测试覆盖。

### 12.4 审计对

每次询问发一个新的 `approvalRequestId`，产生 `approval_asked` / `approval_decided`
**一对**记录，共享该 id，写进 T7 的 run log。
借鉴 dsh 的一条约束：**不在一次 run 里就不能问**——没有活跃 runId 时的审批请求直接
`unavailable`，且不写任何记录。

### 验收标准

1. 四个结果值中只有 `allowed-once` 会让工具本体执行（四个测试）。
2. 应答者抛异常 ⇒ `unavailable` ⇒ 拒绝，而不是崩溃或放行。
3. `never` 策略下，即便注册了一个会返回 `allowed-once` 的应答者，结果仍是拒绝。
4. 两个 guard，前者拒绝、后者返回 `undefined` ⇒ 最终拒绝（顺序对调结论不变）。
5. 一次询问在 run log 里产生配对的 asked/decided 两条记录。
6. 拒绝仍以**普通工具错误结果**返回给模型（`{content: "..."}`），不是抛异常——
   现有 `approval.ts` 的这条性质不能被破坏。

---

## 13. T5 —— `ask_user` 反问工具（对应 G6）· P3

**产品价值最高、成本也最高的一项。放在最后做。**

语音天然模糊（同音字、指代、省略）。"把桌面那个 PDF 发给他"——桌面有三个 PDF，
现在只能赌。这一项把 agent 从"猜一次，错了重来"变成"不确定就问一句"。

### 13.1 工具契约

```ts
opentype__ask_user({
  questions: [{
    id: string                       // 稳定 id，答案按它路由
    question: string
    detail?: string                  // 随问题展示，但不进选项标签
    options?: { label: string; description?: string }[]
    multiSelect?: boolean            // 默认单选
  }]
})
```

**一次请求可带多个问题**（数组 + 稳定 id），UI 可以在一个流程里呈现相关提示。

答案：每个问题一项 `{ id, selected: string[], custom?: string }`。
单选时 `custom` 覆盖选择且 `selected` 为空；多选时 `custom` 补充 `selected`。

### 13.2 传输

- `GET /agent/question/:runId` —— 返回当前挂起的问题（无则空），
  **复用 Swift 已有的 ~0.7s 进度轮询节奏**，不引入新的轮询循环；
- `POST /agent/answer/:runId` —— 回填答案，工具 resolve。

### 13.3 三条不可违反的规则

1. **无 UI 通道时必须立刻返回错误结果，绝不能永久挂起。**
   判定：dispatch 时没有 runId ⇒ 立即 `unavailable` 错误结果。
   另设一个无人应答超时（建议 120s）作为兜底。
2. **T1 的取消必须能中断挂起的问题**——signal abort ⇒ 问题撤回，
   工具以错误结果收场，`/agent/question/:runId` 不再返回它。
3. **协议与呈现分离**：将来可以加一个 `intent` 标签让 UI 渲染专用界面，
   但**两种 UI 回来的答案编码必须完全一致**。本项可以先不实现 `intent`，
   但类型和文档要为它留位，且不能让答案编码依赖呈现方式。

### 13.4 Swift 侧

语音面板（`OverlayController` + `Models.swift:251` 的 `VoiceSurfaceState`）
需要一个新形态：listening pill → working → **question card** → result card。
即 `reduce(...)` 多一个输入源（挂起的问题）和一个输出态 `.asking(...)`。

三条与"临时面板"性质相关的约束：

1. **question card 不可被点击外部关闭**——
   `allowsClickOutsideDismiss` 对它返回 `false`（和 `.working` 一致）。
   一个能被误点消失的问题等于没问。
2. **关闭按钮不回答问题也不取消 run**——与 agent 现有的 dismiss 语义保持一致
   （`dismissalEffect` 仍是 `.none`）。问题继续挂起，直到被回答、被取消或超时。
3. **已知局限，要写进文档**：`.listening` 无条件优先（§2 规则 1），
   所以用户在问题挂起时又开口说话，问题会被面板顶掉并最终**超时**收场。
   这是可接受的——用户显然已经改主意了——但必须是**超时**这条明确路径，
   不能变成静默悬挂。

⚠️ 与 T1 的交互：question card 上也要有「停止」（取消整个 run，§13.3 规则 2）。

### 验收标准

1. 没有 runId 时 `ask_user` 立即返回错误结果（不阻塞）。
2. 挂起的问题被 signal 取消后，工具以错误结果收场且问题不再可见。
3. 无人应答超时后同上。
4. 一次请求带三个问题，答案按 id 正确路由回去（顺序无关）。
5. 单选 + `custom` 的覆盖语义、多选 + `custom` 的补充语义各一个测试。
6. Swift 侧 reducer 的三态转换有单元测试。

---

## 14. 执行顺序与方式

全部 9 项都在范围内。建议顺序（按依赖 + 由易到难）：

| 序 | 项 | 为什么排这里 |
|---|---|---|
| 1 | **T8** 文档规范（§9） | 纯文档、零风险，且会**先暴露**还有哪些注入点是文档声称存在但代码里没有的——这个结论会影响后面几项 |
| 2 | **T4** 时间上下文（§6） | 隔离、~2 小时，先拿一个完整的 TDD 闭环热身 |
| 3 | **T9** 工具目录（§10） | 隔离、脚本级，顺手把"模型能看到什么"落成文件 |
| 4 | **T2** spill（§7） | 隔离，只改结果处理路径 |
| 5 | **T3** 重复调用护栏（§8） | 隔离，只在循环里加一条消息 |
| 6 | **T1** 取消 + 预算（§5） | **横切**：改 `ToolSet.callTool` 签名，波及全部工具集和多个既有测试。放在隔离项之后，避免和它们互相搅 |
| 7 | **T7** 步骤日志（§11） | 需要先有 T1 的取消态才能记录完整的终态集合 |
| 8 | **T6** 审批 + guard（§12） | 审计对要写进 T7 的 run log；`cancelled` 结果要靠 T1 |
| 9 | **T5** `ask_user`（§13） | 依赖 T1（取消挂起的问题）和 Swift 面板改造，最大的一项，放最后 |

每一项**独立走一遍** `CLAUDE.md` 的 4 阶段 TDD 流水线，**分开提交**：
写测试 → 评审测试（确认红、且红得对）→ 实现 → 评审实现 → 通过即提交。
每阶段一次独立的 Agent 调用，不要一个 agent 从头做到尾。

命令：`cd sidecar && bun test`；仓库根 `swift build && swift test`。

**完成的定义**：9 项全部提交，`bun test` 与 `swift test` 全绿，
本文件的"状态"行更新为已完成并记录实际偏离（哪一项改了设计、为什么）。
