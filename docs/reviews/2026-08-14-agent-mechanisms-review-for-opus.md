# OpenType 代码评审报告（2026-08-14）

> **用途**：针对当前 `main`（91d04b7，即 dsh-borrowings 九项机制合并之后）的一次正确性评审，范围为 `Sources/OpenType` + `sidecar/src`。供下一轮修复（Opus 执行）直接使用。每条 finding 带 `文件:行号`、失败场景和修复建议，按优先级排序。
>
> **评审方法**：`/code-review high` —— 8 个独立查找角度（含跨文件链路追踪）并行扫描，汇总去重后逐条对照工作树做对抗验证。预算/499 混淆、ask_user 绕过审批、多问题坍缩、问答竞态这几条各自被 2–4 个独立角度重复发现。**10 条候选全部验证通过，无一被驳回。**
>
> **总体判断**：问题高度集中在刚合并的 dsh-borrowings 机制层（T1 取消/预算、T5 ask_user、T6 审批、repeat guard）与 Swift 侧的接线处。机制本身的设计是对的，但几乎每个机制都在「接缝」上漏了：取消信号在 coreTools 被吞、审批 seam 被 ask_user 绕过、预算超时和用户取消共用一个 499、问答通道四处竞态。这批问题修完，这九项机制才算真正落地。
>
> **执行须知**：按仓库 CLAUDE.md 约定，所有修复走 4 阶段 TDD 管线（写测试 → 审测试确认红 → 实现 → 审实现后即提交），每阶段独立 Agent 分发。每条目附带的「建议回归测试」即阶段 1 的输入。

---

## 0. 执行摘要

| # | 问题 | 位置 | 级别 |
|---|------|------|------|
| 1 | 停止后核心工具继续执行：coreTools 的兜底 catch 把取消异常转成普通错误内容，批次中后续（可能是破坏性的）命令照常跑 | sidecar/src/agent/coreTools.ts:606 | **P0** |
| 2 | repeat-guard 提醒消息插进同一 assistant 轮的 tool 消息之间，OpenAI 兼容 API 直接 400，救火机制杀死健康 run | sidecar/src/agent/loop.ts:286 | P1 |
| 3 | 轮询 tick 的第二个 await 后只复查 runId 不复查 phase，晚到的 tick 把已完成的面板状态写回 .running，结果卡片永远出不来 | Sources/OpenType/AppModel.swift:2345 | P1 |
| 4 | 预算超时和用户取消共用 499：无人值守超时的 run 被记成「已停止」，且完成通知被抑制 | sidecar/src/agent/routes.ts:195 | P1 |
| 5 | DEFAULT_RUN_BUDGET_MS（300s）恰好等于 curl --max-time（300s）：预算超时通常先撞传输超时，表现为随机的 .failed/.cancelled 二选一 | sidecar/src/agent/cancellation.ts:47 | P1 |
| 6 | opentype__ask_user 在 withApproval 包装之后才合入 toolset，完全绕过审批 seam、T6 单调守卫和审批审计对 | sidecar/src/agent/routes.ts:154 | P1 |
| 7 | ask_user 协议支持多问题，Swift 只渲染 questions.first，其余问题被以用户名义报告为「(skipped)」 | Sources/OpenType/AppModel.swift:2343 | P1 |
| 8 | broker.answer 只按 runId 路由、不校验 question id：迟到的答案会把 agent 的下一个问题整体结算成 skipped | sidecar/src/agent/askUser.ts:93 | P1 |
| 9 | parseQuestions 不校验模型给的 options（label 可缺失），Swift 解码必失败 → 问题永远不显示，run 白等 120s 超时 | sidecar/src/agent/askUser.ts:147 | P1 |
| 10 | /oneshot/ask 复用 runAgentLoop 却一项新机制都没接：无取消信号、无预算、无 repeat guard —— T1 要修的孤儿 run 问题在 Ask 模式原样存活 | sidecar/src/oneshot/routes.ts:112 | P1 |

另有一批已确认但低于本次报告阈值的清理项，见 §5。

---

## 1. 取消链与预算（#1、#4、#5、#10）

这四条是同一条链上的洞：T1 建立了「typed cause 的取消信号 + 运行预算」，但信号在工具层被吞（#1）、cause 在路由层被抹平（#4）、预算值和传输超时打架（#5）、Ask 模式整条链没接（#10）。

### 1.1 [P0] 停止后核心工具继续执行

**位置**：`sidecar/src/agent/coreTools.ts:606`（callTool 的兜底 catch）

**问题**：loop.ts 的设计是「工具调用抛出 AgentCancelledError 时中止批次剩余调用」，但 coreTools 的 `callTool` 用一个 blanket catch 把所有异常（包括取消信号的 rejection）转成 `{ content: 'Error...' }` 返回。于是对核心工具而言，loop 的「rethrow 以停止批次」永远不会触发。

**失败场景**：用户在模型发出批次 `[web_fetch, bash 'rm -rf ~/x', ...]` 期间点「停止」。in-flight 的 web_fetch 以 AgentCancelledError reject，但 catch 把它变成普通错误内容，loop 继续执行批次里剩下的 bash 调用。`runProcess` 在检查 `signal.aborted` 之前就已 spawn 子进程，快命令能在 SIGTERM 到达前跑完 —— 在无沙箱、无预执行确认的产品姿态下，**用户按了停止，副作用仍在继续**。

**修复建议**：catch 里对 AgentCancelledError 直接 rethrow（对齐 builtInTools 的 throwIfAborted 边界）；或者更彻底地，把 abort 检查上移到共享的 dispatch seam，让所有 toolset 天然拿到同一行为。

**建议回归测试**（sidecar）：构造一个批次 [慢工具, bash]，慢工具执行中 abort 运行信号；断言 bash 从未被 spawn，且 loop 以 AgentCancelledError 收尾。

### 1.2 [P1] 预算超时被谎报为「用户已停止」

**位置**：`sidecar/src/agent/routes.ts:195`

**问题**：`runBudgetSignal` 以 `AgentCancelledError('budget')` 中止，但 handleAgentRun 的 catch 只判 `instanceof AgentCancelledError`，对 user-cancel 和 budget 两种 cause 一律抛 `ApiError(_, 499)`。Swift 的 `isCancellationStatus` 只看 status==499，于是记录变成 `.cancelled`、文案「已停止/Stopped」、完成通知被 `postAgentCompletionNotification` 的 early return 抑制（注释写的理由是「用户停止时正看着界面」—— 对预算超时不成立）。

**失败场景**：一次无人值守的 agent run 超过 5 分钟预算，静默死在半路：没有任何通知，历史记录显示「用户已停止」。cancellation.ts 自己的文档注释明确说「把预算超时报告成 you-cancelled-this 是撒谎」，typed cause 正是为此而建 —— routes.ts 把它抹掉了。

**修复建议**：routes 层按 cause 分流（如 budget → 408/504 + 明确 message，user → 499）；Swift 侧对应加一个 budget-expired 展示态（记 `.failed` 或新增语义，且不抑制通知）。

**建议回归测试**：sidecar 侧 —— budget cause 的 run 结束后断言响应不是 499（或带可区分的错误体）；Swift 侧 —— 该响应映射为非 .cancelled 且会发通知。

### 1.3 [P1] 预算值与 curl 超时精确相等，499 路径基本不可达

**位置**：`sidecar/src/agent/cancellation.ts:47`（`DEFAULT_RUN_BUDGET_MS = 300_000`）vs `Sources/OpenType/SidecarClient.swift:97`（`sidecarRequestTimeoutSeconds = 300`）

**问题**：curl 的 300s 计时从发请求就开始，比 sidecar 的预算计时（body 解析后）先启动；预算到期时 sidecar 还要收尾 loop、结算 registry、序列化 499，所以 curl 几乎总是先以 exit 28 放弃。

**失败场景**：同一个超预算 run，Swift 侧收到 `SidecarClientError.requestFailed`（记 `.failed` + 原始 curl stderr + 「任务失败」通知），sidecar 侧 progressRegistry 记 `cancelled` —— 两边永久不一致，且结局取决于毫秒级竞速，非确定性。

**修复建议**：预算必须显著低于传输超时（例如 budget 240s / curl 300s），或者反过来把 /agent/run 的 curl 超时单独调大。与 1.2 一起修。

**建议回归测试**：断言 `DEFAULT_RUN_BUDGET_MS / 1000 < sidecarRequestTimeoutSeconds`（可以是一条跨仓约定的常量测试），防止将来再漂回相等。

### 1.4 [P1] /oneshot/ask 一项新机制都没接

**位置**：`sidecar/src/oneshot/routes.ts:112`

**问题**：Ask 复用 `runAgentLoop`，但调用处没传取消信号、没有 runBudgetSignal、没有 repeatGuard（grep 确认零命中）。Swift 的 `cancelAsk` 只杀掉自己的 curl 子进程 —— HTTP 请求成了孤儿，sidecar 的 ask loop 继续烧 token、继续发 web_search/web_fetch，没有任何东西能停下它，也没有预算上限。这正是 cancellation.ts 文档里描述的、T1 立项要修的 bug —— 只在 /agent/run 修了。

**失败场景**：用户问了个问题又马上取消；后台 loop 继续跑满 6 轮迭代的搜索抓取。或者模型退化重复同一个 web_search，6 轮全烧掉，没有断路器。

**修复建议**：把「fuse req.signal + budget + repeatGuard」做成 runAgentLoop 调用的默认行为（由共享入口负责），而不是 /agent/run 单独的 opt-in。

**建议回归测试**：对 /oneshot/ask 发起请求后 abort req.signal，断言 loop 内的下一次工具调用/模型调用不再发生。

---

## 2. ask_user 问答通道（#7、#8、#9，关联 #3）

T5 的问答通道两端（sidecar broker ↔ Swift 轮询渲染）各自都有洞，且互相放大。

### 2.1 [P1] 多问题请求被坍缩成第一个，其余以用户名义「跳过」

**位置**：`Sources/OpenType/AppModel.swift:2343`（`updated.question = prompt.questions.first`）

**问题**：工具 schema 明确鼓励一次带多个问题（"The questions to ask, presented together"），broker 和 renderAnswer 也按多问题设计（稳定 id、逐条映射）。但 Swift 只渲染 `questions.first`，`onAnswerAgentQuestion` 只回传一个 answer；`broker.answer` 结算整个 PendingAsk，renderAnswer 给其余问题全部产出「(skipped)」。

**失败场景**：模型问 [q1: 哪个文件, q2: 什么格式, q3: 是否覆盖]；用户只看到 q1。模型被告知用户「主动跳过」了 q2/q3，于是自行猜测格式并决定覆盖 —— 恰好是 T5 立项要消灭的那种掷硬币。

**修复建议**：二选一 —— (a) Swift 渲染全部问题、聚合回答；(b) 把工具 schema 约束为 `maxItems: 1`，让契约与实现一致。(b) 改动小，先做 (b) 也可接受。

**建议回归测试**：模型侧构造 3 问请求，断言要么三问全部呈现并逐一作答，要么 schema 拒绝多问。

### 2.2 [P1] broker.answer 不校验 question id，迟到答案会误结算下一个问题

**位置**：`sidecar/src/agent/askUser.ts:93`

**问题**：`answer(runId, ...)` 找到该 runId 当前 pending 的条目就 resolve，从不比对答案携带的 question id 与 pending 条目的 id。配合 0.7s 轮询会复活已答/已超时问题的竞态（见 §3），旧问题的答案可以落在新问题头上。

**失败场景**：问题 A 超时（或刚被回答），agent 随即在同一 runId 下问后续问题 B；界面因轮询竞态仍显示 A，用户点了 A 的选项。`handleAgentAnswer → broker.answer(runId, ...)` 找到的是 B 的 waiter，用 A 的答案 resolve 它；renderAnswer 按 id 匹配不上，B 全部报「(skipped)」——run 当作用户拒答 B 继续走。而路由无条件返回 `{ delivered: true }`，两端都检测不到误投。

**修复建议**：`answer()` 校验来答的 question ids 与 pending 条目一致，不一致返回可区分的错误（Swift 侧收到后丢弃旧卡片、拉取当前问题）。

**建议回归测试**：pending B 时提交携带 A 的 id 的答案，断言 B 的 waiter 不被结算、路由返回非 delivered。

### 2.3 [P1] 模型给出畸形 option 时，问题永远不显示，run 白等 120 秒

**位置**：`sidecar/src/agent/askUser.ts:147`（`item.options as AskUserOption[]` 未校验强转）

**问题**：parseQuestions 对模型提供的 options 只做类型断言不做校验，而 Swift 的 `AgentQuestionOption` 解码器要求 `label: String` 非可选（Models.swift:176-179）。一个缺 label 的 option 让 `GET /agent/question/:runId` 的响应在 Swift 侧每个 0.7s tick 都解码失败（`try? await` 吞掉错误），按「解码失败保留旧值」的设计，问题永远不上屏。

**失败场景**：模型调用 ask_user 时 options 写成 `[{"description": "桌面上那个 PDF"}]`（漏 label）。用户什么都看不到，run 阻塞满 ASK_USER_TIMEOUT_MS（120s），然后 agent 被告知「No answer came back in time」—— 为一个从未展示过的问题。

**修复建议**：parseQuestions 落地时校验/规范化（label 缺失时回退用 description 或拒绝该工具调用并把校验错误返给模型，让它重试）。

**建议回归测试**：ask_user 传缺 label 的 option，断言要么服务端拒绝并给模型可读错误，要么 GET 端点输出的每个 option 都带非空 label。

---

## 3. Swift 轮询竞态（#3）

### 3.1 [P1] 晚到的 poll tick 把终态面板写回 .running，结果卡片永远不出现

**位置**：`Sources/OpenType/AppModel.swift:2345`

**问题**：poll tick 先过 `shouldContinuePolling`（phase == .running），拷贝 `updated`，然后 await `sidecarClient.agentQuestion`（完整一次 curl 往返）。第一个 await 之后有 `shouldContinuePolling` 复查（line 2334），**第二个 await 之后的 guard 只查 `runId` 不查 phase**。若阻塞的 /agent/run 响应恰在这个 await 期间结算了面板（.succeeded + result），晚到的 `self.agentPanelState = updated` 会用完成前的拷贝（.running、result nil)覆盖回去。此后的 poll 只更新 steps/question、从不更新 phase，终态再也无法恢复。

**失败场景**：每 0.7s 一个 tick、每 tick 一次 curl 往返，run 完成时刻几乎必然落在某个 tick 的 await 窗口内 —— 语音面板永远显示工作中的 pill，结果卡片不出现，用户以为 run 挂了。同时这也是 §2.2 竞态（已答问题复活约 0.7s）的 Swift 侧成因。

**修复建议**：第二个 await 后把 guard 补全为 `runId 一致 && shouldContinuePolling(...)`（与第一个 await 后的防护对齐）。

**建议回归测试**：模拟 tick 挂起期间面板被置为 .succeeded，恢复 tick 后断言 phase 仍为 .succeeded 且 result 不丢。

---

## 4. 审批 seam 与消息序列（#6、#2）

### 4.1 [P1] ask_user 完全绕过 ApprovalPolicy seam

**位置**：`sidecar/src/agent/routes.ts:154`（对照 `sidecar/src/server.ts:140` 的包装顺序）

**问题**：server.ts 只对 `mergeToolSets(builtInTools, coreTools, mcpTools)` 做了 `withApproval` 包装；handleAgentRun 随后 `mergeToolSets(wrappedTools, createAskUserTool(...))`，而 mergeToolSets 按归属集合路由调用 —— ask_user 的调用从不经过 `policy.approve`、T6 单调守卫和 `approval_asked`/`approval_decided` 审计对。这违反仓库 CLAUDE.md 的不变量「every tool call flows through the ApprovalPolicy seam」：现在策略是 always-allow 所以无感，哪天真的接上 approve/deny 弹窗或守卫，ask_user 是静默不设防、不留审计的后门。

**修复建议**：把 withApproval 包装下移到 handleAgentRun 内、对含 ask_user 的最终 toolset 做 per-run 包装 —— 顺带让审计 sink 能闭包到 runId（现在做不到）。

**建议回归测试**：注入一个 deny-all 的 ApprovalPolicy，断言 ask_user 调用同样被拒并产生 approval_asked/decided 审计对。

### 4.2 [P1] repeat-guard 提醒消息插错位置，OpenAI 兼容 API 直接拒收

**位置**：`sidecar/src/agent/loop.ts:286`（提醒 push 在 per-tool-call 循环体内）

**问题**：repeat-guard 命中阈值时立刻 `messages.push({ role: 'user', ... })`。若命中发生在一个多调用批次中间，这条 user 消息会插在同一 assistant `tool_calls` 轮的两条 tool 消息之间。下一次 chat() 请求里就出现「role:'tool' 消息不紧跟 assistant tool_calls 块」的序列 —— DeepSeek/OpenAI Chat Completions 对此直接 HTTP 400，整个 run 失败。为退化 run 准备的救火机制，杀死的恰是还健康的 run。

**失败场景**：模型一轮发出 `tool_calls [A, A, A, B]`，相同的 A 第三次命中阈值，提醒被插在 A#3 的 tool 消息之后、B 的 tool 消息之前 → 下一轮请求 400。

**修复建议**：命中时只置标记/缓存提醒文本，等本批次最后一条 tool 消息 append 完再统一 push。

**建议回归测试**：构造 [A, A, A, B] 批次触发 guard，断言最终 messages 序列中所有 tool 消息紧跟其 assistant 轮、提醒 user 消息位于批次末尾之后。

---

## 5. 已确认但低于阈值的清理项

对抗验证同样确认了以下几条，属于重复/陈旧问题而非正确性缺陷，可作为顺手清理（不必单独立项）：

- `safeSegment` 逻辑在多处重复实现；runId 编码逻辑存在拷贝粘贴副本 —— 应收敛到单一 util。
- Agent 问题轮询端点存在重复定义（doubled poll endpoint）。
- 若干文档段落已落后于本批机制合并后的实际行为（与 CLAUDE.md「文档与代码同等重要」的约定不符），修复 §1–§4 时应顺带把 `docs/superpowers/specs/` 对应段落一起更新。

---

## 6. 修复顺序建议

1. **#1（P0）先修** —— 停止后副作用继续，是无沙箱姿态下唯一真正危险的一条。
2. **§1 其余三条一起修**（#4、#5、#10）—— 同一条取消/预算链，一个 TDD 批次内完成最省事，避免三次触碰同一批文件。
3. **§2 + §3 一起修**（#7、#8、#9、#3）—— 问答通道两端 + 轮询竞态互为因果，分开修会互相踩。
4. **§4 两条独立可并行**（#6、#2）。
5. 清理项（§5）搭任意批次的便车。
