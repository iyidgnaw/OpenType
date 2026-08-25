# 2026-08-25 记忆层归一 与 跨模式近期上下文

Status: approved（产品负责人 2026-08-25 逐节确认）。
基线：`main` @ `2578a2b`（Release 1.2.0）。开工前先确认 Swift 与 sidecar 两套测试全绿。

执行方式：每批走 CLAUDE.md 约定的 4 阶段 TDD 管线（写测试 → 审测试确认红 → 实现 → 审实现后即提交），
每阶段独立 Agent 分发，开发一律 Sonnet 子代理，主代理只做编排与评审。
本文件是每批的设计输入；实现中若偏离，回来改这份文档，不要让它烂掉。

---

## 一、为什么

产品主张是：**三个模式的输入全部进入上下文，让系统越用越懂这个用户。**
今天做不到，但原因不是没采集——采集完备到浪费。

一条用户输入现在同时落进**四个**存储，其中**三个没有任何消费者**：

| 存储 | 三模式写入 | 谁读 |
|---|:-:|---|
| `audit-events.v1.jsonl`（Swift） | ✅ | 只有 `UsageStats` 统计带 |
| `history.json`（Swift） | ✅ | 只有听写页 UI |
| `memory.sqlite3`（Swift） | ✅ | **零读者**（见下） |
| `episodic_events`（sidecar） | ✅ | 只有整理器，且查询层写死排除 `transcribe` |

`memory.sqlite3` 的状态值得单独记一笔：P1-7 删掉四个 prompt 读取方法与整个
`LocalMemoryRetriever.swift` 之后，`AgentMemoryStore` 的 8 个 `@Published` 属性
**没有任何订阅者**——不是「没进 prompt」，是连 UI 都不读（记忆面板 `MemoryViews.swift`
读的是 sidecar 的 HTTP 接口）。一个 660 行、带完整迁移机制的 SQLite 层，只剩写入和清空。

从「存下来」到「进入下一次 prompt」，全部通路只有三条，且都不解决跨模式问题：

1. `conversation_messages` → `priorMessages`：唯一保留原文的一条，但按 `conversationId` 取，
   而 Swift 侧 `askPanelState` 与 `agentPanelState` 是两个并存的独立变量，**听写根本不产生会话**。
2. `episodic_events` → 整理器 → `entity_terms`：四道闸串联（排除 transcribe、≥12h、
   每启动查一次、产出只有「词条」这一种形态）。一句「去深圳的拜访会议」最多沉淀出一个词，
   绝不会保留成一件事。
3. `owner_facts`：同上，再加一道 `origin === "owner"` 来源闸。

缺的那条从来没写过：`MemoryStore` 的方法列表里**没有任何一个按时间取事件的查询**。

---

## 二、目标与非目标

**目标**

- 一条输入落两份：`audit-events.v1.jsonl`（审计，不可抹除）+ `episodic_events`（记忆与历史的唯一真源）。
- ask 与 agent 的每次调用都能看到**最近 10 条跨模式输入**，含听写。
- agent 能顺着 id 下钻到完整记录；ask 不能（one-turn Q&A，不给复杂工具）。
- 顺手修掉三处已知的文档漂移。

**非目标**

- 不合并 `SessionKind` 路由。本设计不让三个模式共享一个 thread，
  而是让每个模式都能**看见**另一个模式最近发生了什么。这比合并 thread 轻，
  也不触碰产品负责人在 2026-08-14 明确否掉的 P1-5。
- 不写数据迁移。见 §3.3。
- 不为听写内容外发提供开关。三个模式全部注入是**明确的产品决定**，
  代价是推翻一条已发布的对外承诺——见 §六，那里列出全部要改的文案位置。

---

## 三、设计

### 3.1 存储归一

```
之前 ── 一条输入落 4 份              之后 ── 一条输入落 2 份
  Swift   audit-events.jsonl          Swift   audit-events.jsonl   审计轨迹，不可抹除
  Swift   history.json                sidecar episodic_events      记忆＋历史，唯一真源
  Swift   memory.sqlite3                        ↳ 回流 ask/agent prompt
  sidecar episodic_events                       ↳ 供听写历史列表
```

`ImmutableAuditStore` **完全不动**：审计的职责与记忆无关，它继续由 Swift 直接追加写，
继续不被任何重置清空。

### 3.2 单写入点

今天有三个写入点，每个只知道一半事实：

| 写入点 | 知道 | 不知道 |
|---|---|---|
| `/asr/transcribe` (`asr/routes.ts:92`) | `rawTranscript` / `correctedTranscript` | 当前模式、前台 app、最终交付了什么 |
| `/oneshot/ask` (`oneshot/routes.ts:149`) | 结果 | 前台 app（写死 `"OpenType Ask"`） |
| `/agent/run` (`agent/routes.ts:239`) | 结果 | 前台 app（写死 `"OpenType Agent"`） |

改为 **Swift 在交付完成那一刻单点写入**，就写在它已经在写审计事件的那一行旁边：
`POST /memory/events`，body 携带 `mode` / `applicationName` / `conversationId` /
`rawTranscript` / `correctedTranscript` / `selectedContext` / `result` / `origin`。
三处 sidecar 侧的 `recordEpisodicEvent` 调用全部移除。

`origin` 沿用今天各路由已在用的取值，由 Swift 按模式给出：
`transcribe` → `"owner"`（端到端是用户自己的话，无模型介入）；
`ask` / `agent` → `"agent"`（`result` 半边是机器产出、可能引用抓取的网页，
把它记成用户自己的话正是 `EventOrigin` 要防的来源混淆）。
这直接决定整理器产出的 `owner_facts` 能否通过 §一 提到的 `origin === "owner"` 来源闸，
所以不是一个可以随手填的字段。

这一改同时解决四件事：

1. **模式标错**：`/asr/transcribe` 是三个模式共用的唯一 ASR 路径，却对每次转写都记一条
   `mode: "transcribe"`。所以今天**每次 ask 和 agent 都额外写一行伪装成听写的记录**。
   今天无害（transcribe 被整理器排除），但对「最近 10 条」是致命的——窗口里一半是另一半的重复。
2. **app 占位符**：听写历史列表按 `applicationName` 分组、过滤、搜索、导出，占位符撑不住。
3. **听写记的是 ASR 原文而非真正交付出去的文本**：`tidy` 跑在 Swift 里，Review 的编辑更在之后，
   sidecar 侧写入根本看不到。这一条是加参数的方案解决不了的。
4. 两份存储从此在**同一时刻、由同一份数据**写出，职责分工才讲得通。

代价两条，都可控：

- 每次会话多一次 socket 往返。沿用今天同样的 best-effort 姿态——
  写失败只丢一行 episodic，绝不影响交付，也绝不冒泡到用户。
- `rawTranscript` / `correctedTranscript` 那一对必须保住
  （`buildConsolidationPrompt` 靠它挖 ASR 听错），所以 `/asr/transcribe` 的响应
  从 `{text, replacements?}` 增加一个 `rawText` 字段。

### 3.3 Schema 与清零

`episodic_events` 加一列 `conversationId INTEGER`（可空——听写没有会话），
加一个 `createdAt DESC` 索引。

**不写迁移，只删这一张表**：

```
DROP   episodic_events              用户从来看不见它（只有整理器读），删掉零感知
保留   entity_terms                 用户在记忆面板手工编辑过的词典，是真实投入
保留   owner_facts                  同上
保留   conversations / _messages    用户在会话列表里看得见的资产
保留   memory_consolidation_runs
```

实现：新增 `schema_meta(version)` 表；`openDatabase()`（`memory/db.ts`）读版本，
不符就 `DROP TABLE IF EXISTS episodic_events` 再建，然后写入当前版本。
策略集中在一处，注释写明「本产品选择清零而非迁移」，以后再改 schema 就是改这个常量。

**已知的数据损失**：整理器尚未消化的历史事件全部丢失（`consolidatedAt` 标记也在这张表上，
被删的行等于从未记录过）；已消化成词条与事实的不受影响。产品负责人已确认接受。

### 3.4 读接口：`recentEvents`

```ts
recentEvents(
  limit: number,
  opts?: { excludeModes?: readonly string[] }
): EpisodicEventRow[]
```

按 `createdAt DESC` 取，返回给调用方前反转成**旧→新**（模型对「最后一条最近」的理解最稳）。

`excludeModes` 默认 `[]`，即三个模式全带，**没有开关**（§六）。
这个参数留着不是为了当隐私开关——它是将来若要做「按 app 排除」「按时间窗收窄」时的现成接缝。
它的 doc comment 必须写明这一点：**不要把它描述成一个当前处于关闭状态的隐私控制**，
那不是现状，注释写错比不写更糟。

注意这与 `consolidationCandidates()` 是**两个独立查询**，各有各的过滤规则：
整理器那条继续排除 `transcribe`（那是 LLM 调用，与本设计的注入是两回事）。
不要把两者合并成一个带开关的查询——那正是「一个下游改动悄悄放宽另一个的边界」的形状。

### 3.5 注入：JSONL

渲染成 JSONL，一行一个对象，**缺的键直接不写**（`null` 既费 token 又暗示模型可以传 null）：

```
Recent activity, oldest first. Expand any entry with opentype__read_history.
{"eventId":42,"mode":"transcribe","app":"WeChat","input":"明天上午帮我安排一个去深圳的拜访会议吧"}
{"eventId":43,"mode":"ask","conversationId":17,"input":"明天那边天气怎么样","result":"深圳明天多云转晴，24–31℃…"}
{"eventId":44,"mode":"agent","conversationId":23,"input":"把纪要整理成待办","result":"已生成 5 条待办并复制到剪贴板"}
```

选 JSON 而非紧凑写法的决定性理由：**键名与工具参数名一字不差**。
`{"eventId":43}` 对应的调用就是 `opentype__read_history({eventId: 43})`，零翻译。
紧凑写法要求模型解析一套自造语法，再把 `conv 17` 心算成 `conversationId: 17`，
而「`#` 到底指哪个 id」只能靠表头那一行说明——表头是最容易被忽略的一行。
代价是约 15–20% 的 token（10 条 ~1200 → ~1400），换的是不会认错 id
而去读了另一段不相干的历史再据此回答。

`app` 入选是因为它在「更懂这个用户」上信噪比高——在微信里说的和在终端里说的是两回事——
且 transcribe 行没有 `result`，预算正好匀得出来。

**两种渲染，一处实现**：`includeIds: boolean` 控制 `eventId`/`conversationId` 是否出现。
agent 传 `true`，ask 传 `false`。ask 那一侧一个数字都不出现——
它够不着的东西不该出现在它眼前。

**注入位置**：与 `knownTerms` 并列，进 **user 消息，不进 system prompt**。
`docs/model-context-inventory.md` §5 那条前缀稳定纪律：每次都变的内容进 system prompt
会让整个 KV cache 前缀失效。`runAgentLoop` 增加 `recentActivity?: string` 参数。

**一个必须钉住的顺序**：ask 与 agent 都是**答完之后**才写自己那条事件，
所以取最近 10 条时当前这一轮还没入库，模型天然不会看见自己正在回答的问题。
这是运气不是设计。B2 建立单写入点之后这条不变量转移到 Swift 侧
（Swift 必须在拿到答案之后才 `POST /memory/events`），两批各有一个测试钉住它——
否则哪天有人把写入提前到入口，上下文里就会出现当前问题的回声。

### 3.6 `opentype__read_history`（仅 agent）

```
{ conversationId?: number, eventId?: number, limit?: number }
```

- 给 `eventId`：返回该轮完整记录——未截断全文、`selectedContext`、完整结果、`applicationName`。
  听写行没有 `result`（设计如此），但全文与来源 app 恰是它最有价值的两样。
- 给 `conversationId`：返回该会话的完整消息序列。
- 都不给：返回最近 `limit` 条**未截断**事件。

只读，不进 `classifyCommandRisk` 的审批路径。注册在 `agent/coreTools.ts`，
因此 ask 的 `filterToolSet(ASK_TOOL_NAMES)` 天然拿不到它——不需要额外排除逻辑。

`3.5` 的表头里那句取回提示是必需的，遵循 `agent/spill.ts` 已立的规矩：
**定位符旁边必须附带说明它能干什么**，不能让模型自己猜一个数字有什么用。

### 3.7 听写历史换源

三个端点：`GET /memory/events?limit=&mode=`、`DELETE /memory/events/:id`、
`DELETE /memory/events`（后者接到「重置输入历史」，与现有的
`DELETE /memory/context-log` 并列）。

Swift 侧的关键是**保住 `HistoryEntry` 这个视图模型**，只把来源从本地文件换成 sidecar。
这样 `HistorySearch.swift`、`HistoryExport.swift`、按天分组、来源过滤、右键删除、导出
**一行都不用改**。唯一的机械改动是 `HistoryEntry.id` 从 `UUID` 变 `Int`——
它现在就是 `eventId`，删除也就直接映射到 `DELETE /memory/events/:id`。

刷新时机两处：每次交付完成后，以及打开听写页时的 `.task`。

---

## 四、删除清单

| 删除 | 理由 |
|---|---|
| `Sources/OpenType/AgentMemoryStore.swift`（660 行） | 零读者 |
| `Sources/OpenType/MemoryInsightsAnalyzer.swift` | 只被上者调用 |
| `Sources/OpenType/OwnerProfileAutoUpdater.swift` | 只被上者调用 |
| `Sources/OpenType/HistoryStore.swift`（90 行） | 被 sidecar 取代 |
| `AppConfiguration.agentMemoryEnabled` 及其 Settings 开关 | 开关控制的东西没了 |
| Settings「重置 Agent 记忆」按钮 / `AppModel.resetAgentMemory()` | 同上 |
| `asr/routes.ts` 的 `recordDictation` | 移交 Swift 单写入点 |
| `oneshot/routes.ts` 的 `recordAnsweredQuestion` | 同上 |
| `agent/routes.ts` 的 `store.recordEpisodicEvent` 调用 | 同上 |

连同这些文件的测试一并删除。删除即验证：删完两套测试必须仍然全绿。

---

## 五、要改掉的一条承诺

`MemoryStore.ts` 的 `CONSOLIDATION_EXCLUDED_MODES` 注释里写着
「plain dictation never reaches an LLM」「delayed transmission is still transmission」。
本设计的注入路径**绕过这道闸**，直接把听写内容送进 ask/agent 的 prompt。

所以那段注释必须改写成新的口径，不能留着自相矛盾：**整理（一次真实 LLM 调用，
产出长期记忆）继续排除听写；即时上下文注入不排除。** 两者是不同的事，
边界也不同，`recentEvents` 与 `consolidationCandidates` 是两个独立查询正是这个原因。

`CLAUDE.md` 里对应的那句同批修改。

---

## 六、听写内容外发：一次知情的承诺变更

**决定（产品负责人 2026-08-25，在完整了解代价后）：三个模式全部注入，不留开关，
直接开启。** `RECENT_ACTIVITY_EXCLUDED_MODES = []`。

这不是一处注释的改写。「听写完全不经过任何 AI 模型」是**已发布的对外承诺**，
出现在至少三个地方：

逐行盘点结果（2026-08-25，见计划 Task 12/13 的完整清单）：

| 位置 | 需改处数 |
|---|---|
| `USER_GUIDE.md` | **13 处**：L7、L115、L184、L257、L420–422、L444、L446、L452、L566、L567、L569、L575、L593 |
| `README.md` / `README.zh-CN.md` | **0 处** |
| `opentype-site` `i18n.js`（中英各一套） | 4 处：L38、L68、L170、L200 |
| `opentype-site` `index.html`（硬编码英文兜底） | 2 处：L183、L254 |

**README 一处都不用改**，这是本次盘点纠正的一个错误认知：它们只声称「听写不需要 API Key、不需要联网」，
这在 2.0.0 之后**依然为真**——变的是识别出的文字之后被复用为上下文，不是听写本身需要联网了。
改它们会毁掉一句准确的话。

**`index.html` 的坑**：它带有硬编码的英文兜底文案，必须与 `i18n.js` 对应条目**逐字节一致**
（页面默认 `lang="en"`，中文由 JS 从 `i18n.js` 换入）。只改 `i18n.js` 会让页面在 JS 执行前、
以及默认语言下继续显示旧承诺。

**仍然为真、必须保留的**：`USER_GUIDE.md` L586 与 `i18n.js` 的 `features.local.*`——
它们说的是「记忆整理排除听写」和「识别在本机跑」，这两条在本设计下**都不变**
（整理与即时注入是两个独立查询，§3.4）。

其中三处需要格外小心：

- **`USER_GUIDE.md` §446** 写明「想让整理也从你的听写里学新词……这需要一个明确的开关
  来交换这份承诺，当前版本**没有**提供，**也不会偷偷替你打开**」。本次变更正是那件事，
  而且确实没有开关——所以这段必须重写成「1.2.0 之前如此；2.0.0 起，
  听写会作为近期上下文进入问答与 Agent 的请求」，不能只是删掉。
- **`USER_GUIDE.md` L444** 不只是陈述了一个已改变的事实，它还**讲了一个论证**：
  「这条产品承诺不因为『只是整理时才发』而打折扣：**延迟发送也是发送**」。
  2.0.0 做的正是那件事。留着它，文档就成了产品自己写下的、对自己新行为的指控——
  这比一句过时的事实严重得多，必须处理掉那句修辞，不能只改它周围的事实陈述。

- **`opentype-site` `i18n.js` §133/§267** 是一条**已发布的 1.0.0 修复记录**：
  「听写内容会经由记忆整理悄悄传到云端，与『听写不经过模型』的承诺相悖」。
  产品公开把这件事当 bug 修过一次。2.0.0 主动做同一件事，因此发布说明**必须把它
  当成头条讲明**——上次是「悄悄地」，这次是明说的决定。读过 1.0.0 说明的用户
  若在 2.0.0 说明里找不到这条，只会读成「那个 bug 又回来了」。

**仍然为真、不要一起删掉的**：语音**识别**默认在本机跑，音频识别完即删。
变的是**识别出来的文字**会作为上下文进入下一次问答/Agent 请求，
不是「音频上云」。手册与站点的改写必须守住这条区别，否则会把一个准确的隐私卖点
连同不准确的那句一起丢掉。

`recentEvents` 的 `excludeModes` 参数（§3.4）保留为参数，不再是欠账的收口点，
而是将来若要做「按 app 排除」「按时间窗排除」时的现成接缝。

---

## 七、分批与依赖

| 批次 | 内容 | 依赖 |
|---|---|---|
| B1 | `schema_meta` + 清零策略 + `conversationId` 列 + 索引 + `recentEvents()` | — |
| B2 | Swift 单写入点 + `/memory/events` 三端点 + 听写历史换源 + §四 全部删除 | B1 |
| B3 | JSONL 渲染 + `recentActivity` 注入 ask/agent | B2 |
| B4 | `opentype__read_history` | B1 |
| B5 | 文档同步（§九） | B1–B4 |

**B2 必须先于 B3**，而且是正确性前提而非整洁度前提：在单写入点建立之前，
每次 ask/agent 都会额外写一行伪装成听写的记录（§3.2 第 1 条），
10 条窗口里一半是另一半的重复，此时上线注入是误导性的。

B4 只依赖 B1 的 id，可与 B2/B3 并行。B2 最大，且是唯一碰 UI 的一批。

## 八、每批要证明什么

- **B1**：旧库启动后 `episodic_events` 被重建且其他五张表原样保留；
  `recentEvents` 按旧→新返回且默认不排除任何模式；
  `recentEvents` 与 `consolidationCandidates` 的过滤规则互不影响。
- **B2**：一次听写会话在 `episodic_events` 里只产生**一行**（不是今天的两行）；
  听写行记的是最终交付文本而非 ASR 原文（用 tidy 变体证明）；
  `applicationName` 是真实 app 名；
  **Swift 在拿到 ask/agent 答案之后才 POST `/memory/events`**——
  这条「先取后记」的不变量在本批从 sidecar 侧转移到 Swift 侧，测试跟着搬；
  `/memory/events` 写失败不影响交付、不冒泡到用户；
  删除四个 Swift 文件后两套测试全绿。
- **B3**：三个模式的行都出现在注入块里；缺的键不出现（不是 `null`）；
  `includeIds: false` 时输出里没有任何数字 id；
  **注入块里不含当前这一轮的输入**（端到端复核 B2 建立的顺序）；
  注入进的是 user 消息不是 system prompt。
- **B4**：`eventId` 取回未截断全文；`conversationId` 取回完整消息序列；
  ask 的工具集里没有它。
- **B5**：见 §九。

## 九、文档同步清单

**`CLAUDE.md`**

- `HistoryStore` 段落整体删除（文件已不存在）。顺带记录：它此前写的「100-entry cap」
  是错的，实际默认值是 1000。
- `AgentMemoryStore` 段落整体删除。
- `/agent/run` 请求体：写的是 `task + selectedText + conversationId`，
  实际是 `task + context + conversationId + runId`（字段名是 `context` 不是 `selectedText`）。
- `CONSOLIDATION_EXCLUDED_MODES` 的口径改写（§五）。
- 新增：`recentActivity` 注入、`opentype__read_history`、两份存储的新分工。

**`docs/model-context-inventory.md`**

- §3 新增一节：`Recent activity` JSONL 块（渲染规则、两种形态、token 量级）。
- §3.6 补 `opentype__read_history` 的结果回灌。
- §4 漂移表：`AgentMemoryStore` 相关各行从「已删除读取侧」更新为「整个存储已删除」。
- §5 前缀稳定纪律新增一个正例：`recentActivity` 为什么必须进 user 消息。

**不新增** `docs/data-storage-inventory.md`：存储从九个降到必要的几个之后，
一份独立的落盘清单不再值得单独维护，并入 `CLAUDE.md` 即可。

---

## 十、本批发现、但不在本批修的

**截断不是字素安全的。** `recentActivity.ts` 的 `clip()` 用 `slice(0, 120)`，边界落在
代理对中间时会把一个 emoji 切成半个（输出里出现孤立的 `\ud83d` 转义）。
`JSON.stringify` 的良构转义保证它不会变成传输层的坏字节，也不会导致解析失败——
模型偶尔会在被截断的字段末尾看到一小段乱码，仅此而已。

不在本批修，因为它不是本批引入的：仓库里另外六处截断
（`contextDebugLog.ts`、`conversations.ts`、`progressRegistry.ts`、`coreTools.ts`、
`repeatGuard.ts`、`spill.ts`）用的是同一个写法，这是既有约定。
真正该做的是一个共用的字素安全 `clip` 助手替换全部七处，那是一次独立的改动，
不该塞进一个已经横跨三个仓库的批次里。
