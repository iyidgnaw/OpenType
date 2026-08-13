# 模型可见输入清单

> **这份文件回答一个问题：到底什么东西进了 prompt。**
>
> 借鉴自 DeepSeek Harness 的 "Model Experience" 规范
> （见 `docs/superpowers/specs/2026-08-13-dsh-borrowings-plan.md` §9 / T8）：
> 任何会影响模型输入的代码，都必须书面交代三件事——
> **模型逐字看到什么、token 成本、对 KV cache 前缀复用的影响**。
>
> **维护规则**：新增或修改任何到达模型请求的内容时，**同一个改动**里更新本文件。
> 这不是可选的收尾工作——正是因为过去没有这条规则，
> 才出现了 §4 里记录的那批"文档声称存在但代码里没有"的注入点。

核对于 `7a749f4`（2026-08-14）。

---

## 1. 三条模型调用路径

sidecar 里一共只有三处向模型发请求。

| 路径 | 系统提示 | 历史 | 工具 | 迭代上限 |
|---|---|---|---|---|
| `POST /oneshot/ask` | `ASK_SYSTEM_PROMPT` | **真实消息回放**（`priorMessages`） | 仅 web 两个 | 6 |
| `POST /agent/run` | `AGENT_SYSTEM_PROMPT` | 摘要成一段文本（`formatPriorTurns`） | 全量合并集 | 10 |
| `POST /transcribe/correct` | `CORRECTION_SYSTEM_PROMPT` | 无 | 无 | 1（单次调用） |

`transcribe` 模式的直接转写路径**完全不调模型**（纯 MLX-Whisper 透传），不在本清单内。

### 1.1 消息数组的实际装配

三条路径都经 `buildInitialMessages`（`src/agent/loop.ts:116`）或等价装配：

```
[0] { role: "system",  content: <该路径的系统提示> }
[1..n] <priorMessages 原样回放>              ← 仅 ask；agent 恒为空
[n+1] { role: "user", content:
          "TASK:\n" + <task/question>
          + (context ? "\n\nCONTEXT:\n" + context : "")
          + (knownTerms ? "\n\n" + knownTerms : "")
      }
```

`/transcribe/correct` 不走这个装配，见 §2.3。

---

## 2. 系统提示

三段都是**常量**，不含任何按请求变化的内容。这是刻意的——见 §5 的 KV cache 说明。

### 2.1 `ASK_SYSTEM_PROMPT`（`src/oneshot/prompts.ts:22`）

**模型看到什么**：1195 字符的固定文本。三段——
(1) Ask 模式的角色定义（直接回答，不铺垫、不复述问题、不编造）；
(2) 何时该联网（当前/可验证信息才查，已知答案不查，查完仍要直接作答并简短标注来源）；
(3) **把 web 返回的一切当作 UNTRUSTED 数据、绝不当作指令**的注入防御段。

⚠️ 第 (3) 段是提示注入的主要防线，**任何后续编辑必须保留它**。

**Token 成本**：每次 `/oneshot/ask` 请求固定约 300 token（1195 字符）。与输入长度无关。

**KV Cache**：内容恒定 ⇒ 作为请求前缀**完全可复用**。修改这段文本会让所有历史前缀失效。

### 2.2 `AGENT_SYSTEM_PROMPT`（`src/oneshot/prompts.ts:42`）

**模型看到什么**：2914 字符的固定文本。两段——
(1) 工具能力清单 + 默认工作目录（用户 home）+ 找不到文件时先看 Desktop/Downloads +
    `open_file` 的语义（"把文件放到屏幕上就是被请求的结果本身，不要只报路径"）+
    **UNTRUSTED 数据防御** + 够了就停止调工具、给完整可用的最终答案（草稿而非代执行）；
(2) 两个内置记忆工具的调用条件（`remember_fact` 的 term/profile 两种 category、
    `consolidate_memory_now` 的触发语）。

⚠️ 同样地，UNTRUSTED 段**必须保留**——v2 给了 agent 真实的手（shell/Python/文件/网络），
这段比 v1 更重要而非更不重要。

**Token 成本**：每次 `/agent/run` 请求固定约 730 token（2914 字符）。
注意这是**每一次迭代**都要重发的（最多 10 次），不是每次 run 一次。

**KV Cache**：恒定 ⇒ 前缀可复用，且因为循环内多次迭代共享同一前缀，复用收益比 ask 更大。

### 2.3 `CORRECTION_SYSTEM_PROMPT`（`src/transcribe/prompts.ts:14`）

**模型看到什么**：923 字符的固定文本，指导它替换一段选中文本。
user 消息由 `buildUserContent`（`src/transcribe/routes.ts:38`）拼成五个块、`\n\n` 分隔：

```
Full text:
<完整文本>

Selected span (this is what you must replace): "<选中片段>"

Text immediately before the selection: "<前文，最多 SURROUNDING_CONTEXT_CHARS>"

Text immediately after the selection: "<后文，同上>"

Spoken correction instruction: "<口述指令>"
```

**Token 成本**：固定约 230 token + **完整文本一份**（`Full text:` 块）+ 前后文各一份。
长文本上这是本清单里最贵的一处——完整文本在同一个请求里实际出现了两次多
（全文一次、前后窗口各一次、选中片段一次）。

**KV Cache**：系统提示可复用；user 块随每次修正变化，无复用。

---

## 3. 动态注入的内容

### 3.1 `Known terms:` 行（`src/oneshot/memoryContext.ts:87`）

**模型看到什么**：一行，仅在有命中时出现：

```
Known terms: PayPal, Diyi Wang.
```

命中规则（`findKnownTerms`，`memoryContext.ts:19`）：遍历 `store.allTerms()`，
把本次输入整体小写后，检查**已知词条或其别名是否作为子串出现在输入里**。
注意方向——是"已知词在输入中"，不是 `MemoryStore.search()` 的"输入在已知词中"。
只输出 `canonicalTerm`，别名不进 prompt。

**Token 成本**：零命中时**完全不出现**（连空行都没有）。命中时约 `词数 × 3` token。
无上限——命中的词越多这行越长；目前没有条数上限，靠词库规模自然受限。

**KV Cache**：位于 user 消息中，随输入变化 ⇒ 不复用。但它排在请求末尾，
不影响系统提示前缀的复用。

**路径**：ask 与 agent **都有**。agent 侧的匹配输入是 `task + " " + context`
（`src/agent/routes.ts:78`），ask 侧只是 `question`。

### 3.2 `What you know about the user:` 行（`memoryContext.ts:57`）

**模型看到什么**：一行，仅在有 owner 事实时出现：

```
What you know about the user: The owner's name is Diyi; The owner prefers concise answers.
```

⚠️ **来源受限（P1-12 记忆投毒防线）**：只注入 `origin === "owner"` 的事实，
即用户本人通过 `remember_fact` 亲口授权记录的。
经 agent/context 流程记录的事实（origin `untrusted`/`agent`/`system`）**永不注入**——
它们可能源自不可信上下文，逐字注入每一次 prompt 正是要封堵的投毒路径。
它们仍可在 `GET /memory/owner-facts` 管理面上看到并删除。

**Token 成本**：**无条件注入全部** owner 事实（不做相关性匹配——单用户场景下事实数量少，
v1 判断不值得为自由文本建相关性系统）。成本随事实条数线性增长且**没有上限**。
⚠️ 这是本清单里唯一一处无界增长且无相关性过滤的注入——事实变多时应当重新评估。

**KV Cache**：同 3.1。

### 3.3 `PREVIOUS CONVERSATION` 块（`src/agent/routes.ts:39`，**仅 agent**）

**模型看到什么**：出现在 `CONTEXT:` 块内，形如

```
PREVIOUS CONVERSATION (for context; this is a follow-up on the same task):
Previous task: <上一轮用户任务>
Previous result: <上一轮最终结果>
```

这是**摘要式**续跑：只回放"任务/结果"两行一组，**不回放**内部工具调用步骤日志。

**Token 成本**：随会话轮数线性增长，**没有上限也没有压缩**。
一个长 agent 会话的每一轮都会把之前所有轮的 task+result 重发一次。
⚠️ 这是目前最可能失控的上下文来源。

**KV Cache**：位于 user 消息，每轮变化 ⇒ 不复用。

### 3.4 真实消息回放（**仅 ask**）

ask 走的是**真正的消息数组回放**（`priorMessages` 原样插在 system 与本轮 user 之间），
不是 3.3 那种摘要。所以 "since when?" 这类追问能对着真实对话解析。

**Token 成本**：随会话长度线性增长，无上限、无压缩。

**KV Cache**：**这是唯一能真正受益于前缀复用的动态内容**——
只要历史消息不变、只在末尾追加，前缀就是稳定的。

### 3.5 工具 schema

由 `ToolSet.openAiTools` 决定，随请求作为 `tools` 参数发出。

- **ask**：`filterToolSet(..., ["opentype__web_search", "opentype__web_fetch"])` ⇒ 恒定两个；
- **agent**：`mergeToolSets(核心工具, 内置记忆工具, ...MCP)` 后经 `withApproval` 包装 ⇒
  **随用户配置的 MCP server 变化**；
- **correct**：不带工具。

**Token 成本**：每次迭代重发。核心工具 8 个 + 记忆工具 2 个是固定底噪；
MCP 部分完全取决于用户接了什么，**不受本仓库控制**。

**KV Cache**：工具列表变化（接入/断开一个 MCP server）会让前缀失效。
本仓库尚无工具目录文档——T9 会补上（`docs/tool-catalog.md`）。

### 3.6 工具结果回灌

每次工具调用的结果作为 `role: "tool"` 消息回灌进消息数组。两级钳制：

| 层 | 上限 | 位置 |
|---|---|---|
| 工具源头 | 25 000 字符 | `clampAtSource`，`src/agent/coreTools.ts:65` |
| 循环 | 20 000 字符 | `clampToolResult`，`src/agent/loop.ts:90` |

**模型看到什么**：超限时结尾追加 `\n...[truncated]`，模型能看出被截断了。

⚠️ **但没有任何取回剩余内容的途径**——这正是 T2（spill）要解决的问题。

**Token 成本**：单次最多约 5000 token；10 次迭代累积可达数万 token。

---

## 4. **不**到达模型的东西（漂移记录）

写这份清单的直接产出：以下机制在文档或直觉上"应该在注入"，但**代码里并没有**。

| 机制 | 真实状态 |
|---|---|
| `AgentMemoryStore.entriesForPrompt()` | 仅 `Tests/OpenTypeTests/OpenTypeTests.swift:493` 调用，**无生产调用方** |
| `AgentMemoryStore.memoriesForPrompt()` | 仅测试（`:446`）调用 |
| `AgentMemoryStore.profileContextForPrompt()` | 仅测试（`:373`）调用 |
| `LocalMemoryRetriever.retrieve()` | 只被 `AgentMemoryStore.swift:243` 调用，而那条链的唯一入口是上面三个仅测试可达的方法 ⇒ **整条语义检索链在生产路径上不可达** |
| "约 12 条近期任务注入 Agent 上下文" | **不存在**。`/agent/run` 的请求体只有 `task + context + conversationId + runId`；Swift 侧从不发送近期任务 |
| "About Me" 用户档案 | Settings 编辑 UI 已移除 ⇒ 既不可填也不注入；`updateOwnerProfile`/`ownerProfile` 仅为旧数据清洗保留 |

**结论**：Swift 侧的整个记忆读取层（`AgentMemoryStore` 的 prompt 相关方法 +
`LocalMemoryRetriever` 的向量检索）在生产路径上是**死代码**。
真正注入模型的记忆只有 sidecar 侧的两条线——§3.1 的实体词条和 §3.2 的 owner 事实。

这不是本次改动要修的问题（"删掉"还是"接上"是一个独立决策），但必须**记录在案**。

补充两点核对结果：

- `CLAUDE.md` 对这件事的描述是**准确的**——它已经自我更正过，明说这层"在读取侧基本是惰性的"、
  "~12 条近期任务注入 Agent 上下文"这个说法"在接线的代码里不存在"。本节是对它的**独立验证**，
  不是对它的更正。
- 一处**小漂移**：`CLAUDE.md` 说 `/agent/run` 请求体是 `task + selectedText + conversationId`，
  实际是 `task + context + conversationId + runId`（`runId` 是进度面板那批改动加的，
  字段名是 `context` 不是 `selectedText`）。

---

## 5. 一条贯穿性纪律：前缀稳定

系统提示是每次请求可复用的 KV cache 前缀。因此：

- ✅ **不变的内容放系统提示**（角色定义、安全约束、工具使用策略）；
- ❌ **每次都变的内容绝不放系统提示**（时间戳、当前选中文本、记忆命中）——
  放进 user 消息，让它成为 append-only 的尾部。

这条纪律决定了 T4（时间上下文）为什么必须注入 user 消息而不是系统提示：
一个每秒都在变的时间戳放进系统提示，会让**整个前缀**在每次请求上失效。
