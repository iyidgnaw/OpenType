# 记忆层归一 与 跨模式近期上下文 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把一条用户输入从落 4 份存储收敛到 2 份，并让 ask/agent 每次调用都能看到最近 10 条跨模式输入。

**Architecture:** `episodic_events`（sidecar SQLite）成为记忆与历史的唯一真源；Swift 在交付完成那一刻单点写入，因此 `mode`/`applicationName`/最终交付文本由构造保证正确；最近 10 条渲染成 JSONL 注入 ask/agent 的 user 消息，键名与 `opentype__read_history` 的参数名一字不差。

**Tech Stack:** Swift 5.9 / SwiftPM / XCTest；TypeScript / Bun / `bun:sqlite` / `bun test`。

**Spec:** `docs/superpowers/specs/2026-08-25-unified-memory-and-recent-context-design.md`

## Global Constraints

- **开发一律 Sonnet 子代理**（`model: "sonnet"`）；主代理只做编排与评审，不写实现代码。见 `CLAUDE.md`「Who runs which stage is not negotiable」。
- **每个 Task 走 4 阶段管线**：写测试 → 审测试确认红 → 实现 → 审实现，四阶段全过后立即提交（已预授权）。
- **不写数据迁移**。schema 变更一律走 Task 1 的清零策略。
- **`DS.*` 设计令牌**：任何 SwiftUI 改动用 `DesignTokens.swift` 的值，不用字面量。
- **注入内容一律进 user 消息，绝不进 system prompt**（KV cache 前缀稳定纪律，`docs/model-context-inventory.md` §5）。
- **`RECENT_ACTIVITY_EXCLUDED_MODES = []`**：三个模式全部注入，**不留开关**（产品负责人 2026-08-25 在完整了解代价后的决定，spec §六）。这条承诺的对外文案改写是 Task 12 的一等交付，不是收尾工作。
- **best-effort 姿态**：任何 episodic 写入/读取失败只影响记忆，绝不影响交付，绝不冒泡到用户。
- **并行任务会让全套测试变红，这是预期的**：多个 Task 共用一个工作区，某个 Task 处于「测试已写、实现未写」的红阶段时，`bun test` 全跑必然带着它的失败。审查时**按本 Task 涉及的文件范围跑测试**，并单独确认全套里剩下的失败是否都能归因到其它 Task 的红阶段——不要把它当成工作区损坏，也不要为了让全套变绿而去动别的 Task 的文件。提交时严格按本 Task 的文件清单 `git add`，绝不 `git add -A`。

---

## File Structure

**新建**

| 文件 | 职责 |
|---|---|
| `sidecar/src/memory/recentActivity.ts` | 纯函数：把 `EpisodicEventRow[]` 渲染成注入用的 JSONL 块 |
| `sidecar/test/memory/recentActivity.test.ts` | 上者的测试 |
| `sidecar/src/agent/readHistoryTool.ts` | `opentype__read_history` 的 handler 与 schema |
| `sidecar/test/agent/readHistoryTool.test.ts` | 上者的测试 |
| `Sources/OpenType/EpisodicEventRecorder.swift` | Swift 单写入点：把一次完成的会话变成 `POST /memory/events` 的 body（纯函数 + 一个 best-effort 发送方法） |
| `Tests/OpenTypeTests/EpisodicEventRecorderTests.swift` | 上者的测试 |

**修改**

| 文件 | 改什么 |
|---|---|
| `sidecar/src/memory/db.ts` | `schema_meta` 表、清零策略、`episodic_events.conversationId` 列与索引 |
| `sidecar/src/memory/MemoryStore.ts` | `recentEvents()`、`RecordEpisodicEventInput.conversationId`、§五 注释改写 |
| `sidecar/src/memory/routes.ts` | `POST/GET/DELETE /memory/events` |
| `sidecar/src/asr/routes.ts` | 删 `recordDictation`；响应加 `rawText` |
| `sidecar/src/oneshot/routes.ts` | 删 `recordAnsweredQuestion`；注入 `recentActivity` |
| `sidecar/src/agent/routes.ts` | 删 `recordEpisodicEvent` 调用；注入 `recentActivity` |
| `sidecar/src/agent/loop.ts` | `RunAgentLoopInput.recentActivity` |
| `sidecar/src/agent/coreTools.ts` | 注册 `opentype__read_history` |
| `sidecar/src/server.ts` | 接线新依赖 |
| `Sources/OpenType/AppModel.swift` | 单写入点接线、听写历史换源、删除 `agentMemory`/`history` 引用 |
| `Sources/OpenType/Models.swift` | `HistoryEntry.id: UUID → Int`、`result: String → String?` |
| `Sources/OpenType/DictationViews.swift` | 数据来源改 `model.historyEntries` |
| `Sources/OpenType/SettingsViews2.swift` | 删「重置 Agent 记忆」、条数改新来源 |
| `Sources/OpenType/AppConfiguration.swift` | 删 `agentMemoryEnabled` |

**删除**：`AgentMemoryStore.swift`、`MemoryInsightsAnalyzer.swift`、`OwnerProfileAutoUpdater.swift`、`HistoryStore.swift` 及各自测试。

---

## Task 1: Schema 清零策略与 `conversationId` 列

**Files:**
- Modify: `sidecar/src/memory/db.ts`
- Test: `sidecar/test/memory/db.test.ts`

**Interfaces:**
- Consumes: 无
- Produces: `openDatabase(path: string): Database`（签名不变）；`episodic_events` 新增 `conversationId INTEGER`（可空）；新表 `schema_meta(version INTEGER NOT NULL)`；常量 `export const SCHEMA_VERSION = 2`

- [ ] **Step 1: 写失败测试**

```ts
import { describe, expect, test } from "bun:test";
import { openDatabase, SCHEMA_VERSION } from "./db";

describe("openDatabase schema reset", () => {
  test("新库带 conversationId 列和当前版本号", () => {
    const db = openDatabase(":memory:");
    const cols = db.query("PRAGMA table_info(episodic_events)").all() as { name: string }[];
    expect(cols.map((c) => c.name)).toContain("conversationId");
    const row = db.query("SELECT version FROM schema_meta").get() as { version: number };
    expect(row.version).toBe(SCHEMA_VERSION);
  });

  test("旧版本库只重建 episodic_events，其余五张表原样保留", () => {
    const db = openDatabase(":memory:");
    // 模拟旧库：降版本 + 各表塞一行
    db.run("UPDATE schema_meta SET version = 1");
    db.run(
      `INSERT INTO episodic_events
        (createdAt, mode, rawTranscript, correctedTranscript, effectiveInput,
         selectedContext, result, applicationName, origin)
       VALUES (1, 'ask', 'r', 'c', null, null, null, 'App', 'owner')`
    );
    db.run(
      `INSERT INTO entity_terms
        (canonicalTerm, aliases, category, confidence, origin, sourceEventIds, createdAt, updatedAt)
       VALUES ('Diyi Wang', '[]', 'person', 0.9, 'owner', '[]', 1, 1)`
    );
    db.run("INSERT INTO owner_facts (content, createdAt, origin) VALUES ('x', 1, 'owner')");
    db.run("INSERT INTO conversations (kind, title, createdAt, updatedAt) VALUES ('ask', 't', 1, 1)");

    // 同一个 Database 句柄上重跑一次 schema 应用
    applySchema(db);

    expect((db.query("SELECT COUNT(*) c FROM episodic_events").get() as { c: number }).c).toBe(0);
    expect((db.query("SELECT COUNT(*) c FROM entity_terms").get() as { c: number }).c).toBe(1);
    expect((db.query("SELECT COUNT(*) c FROM owner_facts").get() as { c: number }).c).toBe(1);
    expect((db.query("SELECT COUNT(*) c FROM conversations").get() as { c: number }).c).toBe(1);
    expect((db.query("SELECT version FROM schema_meta").get() as { version: number }).version)
      .toBe(SCHEMA_VERSION);
  });
});
```

顶部再加一行 import：`import { applySchema } from "./db";`

- [ ] **Step 2: 跑测试确认红**

Run: `cd sidecar && bun test test/memory/db.test.ts`
Expected: FAIL —— `SCHEMA_VERSION` 与 `applySchema` 未导出；`conversationId` 列不存在。

- [ ] **Step 3: 实现**

在 `db.ts` 的 `SCHEMA_SQL` 里给 `episodic_events` 加列与索引：

```sql
CREATE TABLE IF NOT EXISTS episodic_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  createdAt INTEGER NOT NULL,
  mode TEXT NOT NULL,
  rawTranscript TEXT NOT NULL,
  correctedTranscript TEXT NOT NULL,
  effectiveInput TEXT,
  selectedContext TEXT,
  result TEXT,
  applicationName TEXT NOT NULL,
  origin TEXT NOT NULL,
  conversationId INTEGER,
  consolidatedAt INTEGER
);

CREATE INDEX IF NOT EXISTS episodic_events_created_at
ON episodic_events(createdAt DESC);

CREATE TABLE IF NOT EXISTS schema_meta (
  id INTEGER PRIMARY KEY CHECK(id = 1),
  version INTEGER NOT NULL
);
```

新增导出：

```ts
/**
 * 本产品选择「清零」而非「迁移」：schema 版本不符时直接丢弃 `episodic_events`
 * 重建，其余五张表原样保留。
 *
 * 为什么只丢这一张：`entity_terms` 是用户在记忆面板手工编辑过的词典，
 * `owner_facts` 同理，`conversations`/`conversation_messages` 是用户在会话
 * 列表里看得见的资产 —— 这三样删掉用户会立刻发现。`episodic_events` 只有
 * 整理器读，用户从来看不见它，丢掉零感知。
 *
 * 已知代价：整理器尚未消化的事件全部丢失（`consolidatedAt` 标记也在这张表
 * 上，被删的行等于从未记录过）；已消化成词条与事实的不受影响。
 * 产品负责人 2026-08-25 确认接受。
 *
 * 改 schema 就改这个常量，不要在别处写第二套版本判断。
 */
export const SCHEMA_VERSION = 2;

export function applySchema(db: Database): void {
  db.exec(SCHEMA_SQL);
  const row = db.query("SELECT version FROM schema_meta WHERE id = 1").get() as
    | { version: number }
    | null;
  if (row?.version === SCHEMA_VERSION) {
    return;
  }
  db.run("DROP TABLE IF EXISTS episodic_events");
  db.exec(SCHEMA_SQL);
  db.run(
    "INSERT INTO schema_meta (id, version) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET version = ?",
    [SCHEMA_VERSION, SCHEMA_VERSION]
  );
}
```

`openDatabase` 里把 `db.exec(SCHEMA_SQL)` 换成 `applySchema(db)`。

- [ ] **Step 4: 跑测试确认绿**

Run: `cd sidecar && bun test test/memory/`
Expected: PASS，且 `MemoryStore.test.ts`/`consolidator.test.ts` 不回归。

- [ ] **Step 5: 提交**

```bash
git add sidecar/src/memory/db.ts sidecar/test/memory/db.test.ts
git commit -m "Reset episodic events instead of migrating them"
```

---

## Task 2: `recentEvents()` 读接口

**Files:**
- Modify: `sidecar/src/memory/MemoryStore.ts`
- Test: `sidecar/test/memory/MemoryStore.test.ts`

**Interfaces:**
- Consumes: Task 1 的 `conversationId` 列
- Produces:
  ```ts
  export interface EpisodicEventRow {
    id: number; createdAt: number; mode: string;
    rawTranscript: string; correctedTranscript: string;
    effectiveInput: string | null; selectedContext: string | null;
    result: string | null; applicationName: string;
    origin: EventOrigin; conversationId: number | null;
    consolidatedAt: number | null;
  }
  recentEvents(limit: number, opts?: { excludeModes?: readonly string[] }): EpisodicEventRow[]
  ```
  以及 `RecordEpisodicEventInput` 新增可选 `conversationId?: number | null`

- [ ] **Step 1: 写失败测试**

```ts
test("recentEvents 按旧→新返回，且默认不排除任何模式", () => {
  const store = new MemoryStore(openDatabase(":memory:"));
  store.recordEpisodicEvent(base({ mode: "transcribe", rawTranscript: "一" }));
  store.recordEpisodicEvent(base({ mode: "ask", rawTranscript: "二", conversationId: 17 }));
  store.recordEpisodicEvent(base({ mode: "agent", rawTranscript: "三" }));

  const rows = store.recentEvents(10);
  expect(rows.map((r) => r.rawTranscript)).toEqual(["一", "二", "三"]);
  expect(rows[1].conversationId).toBe(17);
});

test("recentEvents 只取最近 limit 条，且取的是最新的那些", () => {
  const store = new MemoryStore(openDatabase(":memory:"));
  for (const n of ["一", "二", "三", "四"]) {
    store.recordEpisodicEvent(base({ mode: "ask", rawTranscript: n }));
  }
  expect(store.recentEvents(2).map((r) => r.rawTranscript)).toEqual(["三", "四"]);
});

test("excludeModes 排除指定模式", () => {
  const store = new MemoryStore(openDatabase(":memory:"));
  store.recordEpisodicEvent(base({ mode: "transcribe", rawTranscript: "一" }));
  store.recordEpisodicEvent(base({ mode: "ask", rawTranscript: "二" }));
  const rows = store.recentEvents(10, { excludeModes: ["transcribe"] });
  expect(rows.map((r) => r.rawTranscript)).toEqual(["二"]);
});

test("recentEvents 不受 consolidatedAt 影响 —— 与整理器候选是两个独立查询", () => {
  const store = new MemoryStore(openDatabase(":memory:"));
  store.recordEpisodicEvent(base({ mode: "ask", rawTranscript: "已整理过的" }));
  store.db.run("UPDATE episodic_events SET consolidatedAt = 123");
  expect(store.recentEvents(10)).toHaveLength(1);
  expect(store.consolidationCandidates(10)).toHaveLength(0);
});
```

`base()` 是本文件已有的 helper 风格；若不存在则加：

```ts
function base(patch: Partial<RecordEpisodicEventInput>): RecordEpisodicEventInput {
  return {
    mode: "ask", rawTranscript: "r", correctedTranscript: "c",
    effectiveInput: null, selectedContext: null, result: null,
    applicationName: "App", ...patch,
  };
}
```

- [ ] **Step 2: 跑测试确认红**

Run: `cd sidecar && bun test test/memory/MemoryStore.test.ts`
Expected: FAIL —— `recentEvents is not a function`。

- [ ] **Step 3: 实现**

`RecordEpisodicEventInput` 加 `conversationId?: number | null`，`recordEpisodicEvent` 的 INSERT 补上该列（`input.conversationId ?? null`）。新增：

```ts
/**
 * 最近若干条事件，**旧→新**返回（模型对「最后一条最近」的理解最稳）。
 *
 * 与 `consolidationCandidates` 是两个刻意独立的查询，不要合并成一个带开关的：
 * 整理是一次真实的 LLM 调用、产出长期记忆，它继续排除
 * `CONSOLIDATION_EXCLUDED_MODES`；即时上下文注入是另一件事，边界不同。
 * 合并意味着一个下游改动可以悄悄放宽另一个的边界。
 *
 * `excludeModes` 是听写内容外发这笔欠账的**唯一收口点**（spec §六）。
 * 将来的方案 —— 时间窗、用户开关、或对听写行做摘要 —— 都在这个参数上落地，
 * 不需要回头翻整条注入链路。
 */
recentEvents(
  limit: number,
  opts?: { excludeModes?: readonly string[] }
): EpisodicEventRow[] {
  const excluded = opts?.excludeModes ?? [];
  const placeholders = excluded.map(() => "?").join(", ");
  const where = excluded.length > 0 ? `WHERE mode NOT IN (${placeholders})` : "";
  const rows = this.db
    .query(
      `SELECT * FROM episodic_events ${where}
       ORDER BY createdAt DESC, id DESC LIMIT ?`
    )
    .all(...excluded, limit) as EpisodicEventRow[];
  return rows.reverse();
}
```

- [ ] **Step 4: 跑测试确认绿**

Run: `cd sidecar && bun test test/memory/`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add sidecar/src/memory/MemoryStore.ts sidecar/test/memory/MemoryStore.test.ts
git commit -m "Read recent events by time, the query that never existed"
```

---

## Task 3: `POST /memory/events` 与移除三处 sidecar 写入

**Files:**
- Modify: `sidecar/src/memory/routes.ts`, `sidecar/src/asr/routes.ts`, `sidecar/src/oneshot/routes.ts`, `sidecar/src/agent/routes.ts`, `sidecar/src/server.ts`
- Test: `sidecar/test/memory/routes.test.ts`, 以及三个路由各自已有的测试文件
- **注意** `sidecar/test/memory/episodicWiring.test.ts` 就是钉住「三个路由都写 episodic 事件」的那个文件（P1-7 的成果）。移除写入后它必然全红——**不要删掉它**，把它改写成钉住新契约：三个路由都**不再**写，写入只发生在 `POST /memory/events`。它从「证明三处都接上了」变成「证明三处都摘干净了」，是同一个不变量的另一面。
- **还有三个文件钉着同一个旧契约**（本计划初稿遗漏，2026-08-25 补）：`test/asr/episodicEvent.test.ts`（10 个测试，钉 `AsrRouteDeps.recordEpisodicEvent` 的字段映射）、`test/oneshot/episodicEvent.test.ts`（7 个）、`test/agent/routes.test.ts` 第 56–91 行的两个内联测试。删掉写入点会让这 17 个测试全部失效。**删之前先读，找出其中仍然成立的规则并搬到 `POST /memory/events` 的测试里**——重构正是这类规则蒸发的地方。
- **一条必须承接的规则**：`recordDictation` 开头的 `if (rawTranscript.trim() === "") return;`。空录音（误触快捷键）不记录，注释写明代价：五次误触就会顶开 `shouldConsolidate` 的门槛，白烧一次真实 LLM 调用。写入收敛后**这条守卫要放在端点里，不是放在调用方**——放在端点，任何未来的第二个调用方都绕不过；放在 Swift，就得靠下一个人重新想起来。
- **`mode` 加 enum 守卫**（2026-08-25 决定）：只接受 `transcribe` / `ask` / `agent`，否则 400，形状照抄同文件里 `ENTITY_CATEGORIES` 的 `invalid_category`。理由不是「校验总是好的」，而是「只有一个可信调用方所以不用校验」正是让旧三写入点的 mode 标错与 app 占位符长期隐形的那个假设——没有任何东西逼它浮现，直到有人专门去找。守卫写反的后果比不写更糟：**误拒一个合法模式会让整整一种模式的历史静默地不再记录**，下游不会报错，查不到记录的人只会以为自己没说过那句话。所以测试要同时钉「非法模式被拒」和「三个合法模式都通过」。

**Interfaces:**
- Consumes: Task 2 的 `recordEpisodicEvent(input)`
- Produces: `POST /memory/events` 接受 `RecordEpisodicEventInput` 的 JSON 形态，返回 `{ eventId: number }`

- [ ] **Step 1: 写失败测试**

```ts
test("POST /memory/events 写入一行并回 eventId", async () => {
  const store = new MemoryStore(openDatabase(":memory:"));
  const app = buildApp({ store /* 其余依赖按本文件既有 helper */ });
  const res = await app.fetch(
    new Request("http://x/memory/events", {
      method: "POST",
      body: JSON.stringify({
        mode: "transcribe", rawTranscript: "原文", correctedTranscript: "改写后",
        effectiveInput: null, selectedContext: null, result: "交付出去的文本",
        applicationName: "WeChat", origin: "owner",
      }),
    })
  );
  expect(res.status).toBe(200);
  expect((await res.json()).eventId).toBeGreaterThan(0);
  const rows = store.recentEvents(10);
  expect(rows[0].applicationName).toBe("WeChat");
  expect(rows[0].result).toBe("交付出去的文本");
});

test("mode 缺失返回 400", async () => {
  const app = buildApp({ store: new MemoryStore(openDatabase(":memory:")) });
  const res = await app.fetch(
    new Request("http://x/memory/events", { method: "POST", body: JSON.stringify({}) })
  );
  expect(res.status).toBe(400);
});
```

三个路由各自的测试里加一条「不再写入」的断言，例如 `asr/routes.test.ts`：

```ts
test("/asr/transcribe 不再写 episodic 事件 —— 写入已移交 Swift 单写入点", async () => {
  const store = new MemoryStore(openDatabase(":memory:"));
  await postTranscribe(store, validAudioBase64);
  expect(store.recentEvents(10)).toHaveLength(0);
});
```

`oneshot/routes.test.ts` 与 `agent/routes.test.ts` 同形，断言各自跑完一轮后 `recentEvents` 为空。

- [ ] **Step 2: 跑测试确认红**

Run: `cd sidecar && bun test test/memory/routes.test.ts test/asr test/oneshot test/agent`
Expected: FAIL —— 路由 404；三处旧写入仍在，`recentEvents` 非空。

- [ ] **Step 3: 实现**

`memory/routes.ts` 加路由：

```ts
{
  method: "POST",
  path: "/memory/events",
  handler: async (req) => {
    const body = (await req.json()) as Partial<RecordEpisodicEventInput>;
    if (!body.mode || typeof body.mode !== "string") {
      throw new ApiError("mode is required", 400);
    }
    if (typeof body.rawTranscript !== "string") {
      throw new ApiError("rawTranscript is required", 400);
    }
    const eventId = store.recordEpisodicEvent({
      mode: body.mode,
      rawTranscript: body.rawTranscript,
      correctedTranscript: body.correctedTranscript ?? body.rawTranscript,
      effectiveInput: body.effectiveInput ?? null,
      selectedContext: body.selectedContext ?? null,
      result: body.result ?? null,
      applicationName: body.applicationName ?? "Unknown",
      origin: body.origin ?? "owner",
      conversationId: body.conversationId ?? null,
    });
    return Response.json({ eventId });
  },
},
```

删除：`asr/routes.ts` 的 `recordDictation` 函数及其调用与 `AsrRouteDeps.recordEpisodicEvent`；`oneshot/routes.ts` 的 `recordAnsweredQuestion` 函数及其调用；`agent/routes.ts` 里 `store.recordEpisodicEvent({...})` 那一段。`server.ts` 里 `recordEpisodicEvent: (input) => store.recordEpisodicEvent(input)` 这一行依赖注入删掉。

- [ ] **Step 4: 跑测试确认绿**

Run: `cd sidecar && bun test`
Expected: PASS（全套）。

- [ ] **Step 5: 提交**

```bash
git add sidecar/src
git commit -m "Move episodic writes behind one endpoint"
```

---

## Task 4: `/asr/transcribe` 响应补 `rawText`

**Files:**
- Modify: `sidecar/src/asr/routes.ts`
- Test: `sidecar/test/asr/routes.test.ts`

**Interfaces:**
- Produces: `/asr/transcribe` 响应形如 `{ text: string, rawText: string, replacements?: ... }`

- [ ] **Step 1: 写失败测试**

```ts
test("响应带 rawText —— 词典改写前的原始识别结果", async () => {
  // 词典里有 别名「拍拍」→ 规范「PayPal」
  const store = seedDictionary([{ canonical: "PayPal", aliases: ["拍拍"] }]);
  const res = await postTranscribe(store, audioSaying("用拍拍付款"));
  const body = await res.json();
  expect(body.text).toBe("用PayPal付款");
  expect(body.rawText).toBe("用拍拍付款");
});

test("没有任何改写时 rawText 与 text 相同", async () => {
  const res = await postTranscribe(emptyStore(), audioSaying("今天天气不错"));
  const body = await res.json();
  expect(body.rawText).toBe(body.text);
});
```

- [ ] **Step 2: 跑测试确认红**

Run: `cd sidecar && bun test test/asr/routes.test.ts`
Expected: FAIL —— `body.rawText` 是 `undefined`。

- [ ] **Step 3: 实现**

`asr/routes.ts` 里两处 `Response.json` 各补一个字段。原始识别结果是词典改写**之前**那个变量（`applyDictionaryRewrite` 的输入），不是 `corrected.text`：

```ts
if (replacements.length === 0) {
  return Response.json({ text: corrected.text, rawText: recognizedText });
}
return Response.json({ text: corrected.text, rawText: recognizedText, replacements });
```

`recognizedText` 用该函数里已有的、传给改写的那个变量名。

- [ ] **Step 4: 跑测试确认绿**

Run: `cd sidecar && bun test test/asr/`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add sidecar/src/asr
git commit -m "Return what Whisper heard, not only what the dictionary rewrote"
```

---

## Task 5: Swift 单写入点

**Files:**
- Create: `Sources/OpenType/EpisodicEventRecorder.swift`, `Tests/OpenTypeTests/EpisodicEventRecorderTests.swift`
- Modify: `Sources/OpenType/AppModel.swift`

**Interfaces:**
- Consumes: Task 3 的 `POST /memory/events`，Task 4 的 `rawText`
- Produces:
  ```swift
  struct EpisodicEventBody: Encodable, Equatable {
      let mode: String
      let rawTranscript: String
      let correctedTranscript: String
      let effectiveInput: String?
      let selectedContext: String?
      let result: String?
      let applicationName: String
      let origin: String
      let conversationId: Int?
  }
  enum EpisodicEventRecorder {
      static func body(mode: InputMode, rawTranscript: String, deliveredText: String?,
                       selectedContext: String?, applicationName: String,
                       conversationId: Int?) -> EpisodicEventBody
  }
  ```

- [ ] **Step 1: 写失败测试**

```swift
final class EpisodicEventRecorderTests: XCTestCase {
    func testTranscribeRecordsDeliveredTextAsResultAndOwnerOrigin() {
        let body = EpisodicEventRecorder.body(
            mode: .transcribe, rawTranscript: "呃这个明天开会",
            deliveredText: "明天开会", selectedContext: nil,
            applicationName: "WeChat", conversationId: nil
        )
        // 交付出去的是轻整理之后的文本，不是 ASR 原文
        XCTAssertEqual(body.result, "明天开会")
        XCTAssertEqual(body.rawTranscript, "呃这个明天开会")
        // 端到端是用户自己的话，无模型介入
        XCTAssertEqual(body.origin, "owner")
        XCTAssertNil(body.conversationId)
    }

    func testAskAndAgentAreAgentOrigin() {
        for mode in [InputMode.ask, .agent] {
            let body = EpisodicEventRecorder.body(
                mode: mode, rawTranscript: "问题", deliveredText: "答案",
                selectedContext: nil, applicationName: "Xcode", conversationId: 17
            )
            // result 半边是机器产出、可能引用抓取的网页 —— 记成用户自己的话
            // 正是 EventOrigin 要防的来源混淆
            XCTAssertEqual(body.origin, "agent")
            XCTAssertEqual(body.conversationId, 17)
        }
    }

    func testApplicationNameIsCarriedNotPlaceholdered() {
        let body = EpisodicEventRecorder.body(
            mode: .transcribe, rawTranscript: "x", deliveredText: "x",
            selectedContext: nil, applicationName: "Terminal", conversationId: nil
        )
        XCTAssertEqual(body.applicationName, "Terminal")
    }
}
```

- [ ] **Step 2: 跑测试确认红**

Run: `swift test --filter EpisodicEventRecorderTests`
Expected: FAIL —— `EpisodicEventRecorder` 不存在。

- [ ] **Step 3: 实现**

新建 `EpisodicEventRecorder.swift`，纯函数部分如上。`AppModel` 侧在**每个 `recordAuditEvent(... status: .completed ...)` 旁边**加一次 best-effort 发送——三处：`finishRecording` 的 transcribe 分支、`dispatchAskRun` 的成功分支、`runAgentDispatch` 的成功分支。发送方法：

```swift
/// best-effort：写失败只丢一行 episodic，绝不影响交付，绝不冒泡到用户。
/// 与审计事件写在同一时刻、由同一份数据构造 —— 两份存储的职责分工
/// （不可抹除的审计 / 可清空的记忆）靠这个同时性才讲得通。
private func recordEpisodicEvent(_ body: EpisodicEventBody) {
    let client = sidecarClient
    Task.detached(priority: .utility) {
        struct Ack: Decodable { let eventId: Int }
        _ = try? await client.request(
            method: "POST", path: "/memory/events", body: body
        ) as Ack
    }
}
```

**顺序要求**：ask/agent 两处必须在拿到答案之后调用（放在 `recordAuditEvent(.completed)` 之后），绝不能提到分发入口——否则模型会在下一轮的注入块里读到它当时正在回答的那个问题。

**取消的运行不得写入**（2026-08-25 补）：`sidecar/test/agent/cancelRoute.test.ts` 原本用一对正负对照钉住这条规则——取消 → 0 行、正常 → 1 行，注释写明理由：「从用户放弃的工作里学习会污染记忆层，那是没人接受过的结果」。路由不再写入之后，这对断言双双失去意义（负例会变成永远不可能失败的空转），已在 Task 3 移除。**规则本身没有消失，它转移到了 Swift**：`/memory/events` 只在交付完成那一刻发，取消走的是另一条路。

本 Task 必须有一个测试钉住它：**一次被取消的 agent 运行不发 `POST /memory/events`**。目前这条规则在任何地方都没有覆盖——它正是这种批次里最容易蒸发的那类规则：没有测试证明它「还在」，只有原地的一句注释解释它为什么在，而那段代码正在被删除。

- [ ] **Step 4: 跑测试确认绿**

Run: `swift test --filter EpisodicEventRecorderTests && swift build`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/OpenType/EpisodicEventRecorder.swift Tests/OpenTypeTests/EpisodicEventRecorderTests.swift Sources/OpenType/AppModel.swift
git commit -m "Record the episode where the truth is, at delivery"
```

---

## Task 6: `GET` / `DELETE /memory/events`

**Files:**
- Modify: `sidecar/src/memory/routes.ts`
- Test: `sidecar/test/memory/routes.test.ts`

**Interfaces:**
- Produces:
  - `GET /memory/events?limit=&mode=` → `{ events: EpisodicEventRow[] }`（新→旧，UI 用）
  - `DELETE /memory/events/:id` → `{ deleted: boolean }`，不存在时 404
  - `DELETE /memory/events` → `{ deleted: number }`

- [ ] **Step 1: 写失败测试**

```ts
test("GET 按新→旧返回，limit 生效", async () => {
  const store = seedEvents(["一", "二", "三"]);
  const body = await getJson(store, "/memory/events?limit=2");
  expect(body.events.map((e: any) => e.rawTranscript)).toEqual(["三", "二"]);
});

test("GET 的 mode 过滤", async () => {
  const store = new MemoryStore(openDatabase(":memory:"));
  store.recordEpisodicEvent(base({ mode: "transcribe", rawTranscript: "听" }));
  store.recordEpisodicEvent(base({ mode: "ask", rawTranscript: "问" }));
  const body = await getJson(store, "/memory/events?mode=transcribe");
  expect(body.events.map((e: any) => e.rawTranscript)).toEqual(["听"]);
});

test("DELETE 单条，不存在时 404", async () => {
  const store = seedEvents(["一"]);
  const id = store.recentEvents(1)[0].id;
  expect((await del(store, `/memory/events/${id}`)).status).toBe(200);
  expect(store.recentEvents(10)).toHaveLength(0);
  expect((await del(store, `/memory/events/${id}`)).status).toBe(404);
});

test("DELETE 全部只清 episodic，不动词典与会话", async () => {
  const store = seedEvents(["一", "二"]);
  store.recordOwnerFact("记得我叫 Diyi");
  const res = await del(store, "/memory/events");
  expect((await res.json()).deleted).toBe(2);
  expect(store.recentEvents(10)).toHaveLength(0);
  expect(store.allOwnerFacts()).toHaveLength(1);
});
```

- [ ] **Step 2: 跑测试确认红**

Run: `cd sidecar && bun test test/memory/routes.test.ts`
Expected: FAIL —— 三个路由 404。

- [ ] **Step 3: 实现**

`memory/routes.ts` 加三个路由。`GET` 直接查（不复用 `recentEvents`，因为 UI 要新→旧且要 mode 过滤，语义与注入用的那条不同）：

```ts
{
  method: "GET",
  path: "/memory/events",
  handler: (req) => {
    const url = new URL(req.url);
    const limit = Number(url.searchParams.get("limit") ?? 200);
    const mode = url.searchParams.get("mode");
    const where = mode ? "WHERE mode = ?" : "";
    const args: (string | number)[] = mode ? [mode, limit] : [limit];
    const events = store.db
      .query(`SELECT * FROM episodic_events ${where} ORDER BY createdAt DESC, id DESC LIMIT ?`)
      .all(...args);
    return Response.json({ events });
  },
},
{
  method: "DELETE",
  path: "/memory/events/:id",
  handler: (_req, params) => {
    const result = store.db.run("DELETE FROM episodic_events WHERE id = ?", [Number(params.id)]);
    if (result.changes === 0) throw new ApiError("no such event", 404);
    return Response.json({ deleted: true });
  },
},
{
  method: "DELETE",
  path: "/memory/events",
  handler: () => {
    const result = store.db.run("DELETE FROM episodic_events");
    return Response.json({ deleted: result.changes });
  },
},
```

`:id` 参数的取法照抄本文件里 `DELETE /memory/terms/:id` 的既有写法。

- [ ] **Step 4: 跑测试确认绿**

Run: `cd sidecar && bun test test/memory/`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add sidecar/src/memory
git commit -m "Serve the history the dictation page will read"
```

---

## Task 7: 听写历史换源

**Files:**
- Modify: `Sources/OpenType/Models.swift`, `Sources/OpenType/AppModel.swift`, `Sources/OpenType/DictationViews.swift`, `Sources/OpenType/SettingsViews2.swift`
- Test: `Tests/OpenTypeTests/HistorySearchTests.swift`（既有，改 fixture）、新增 `Tests/OpenTypeTests/HistoryEntryMappingTests.swift`

**Interfaces:**
- Consumes: Task 6 的 `GET/DELETE /memory/events`
- Produces:
  - `HistoryEntry.id: Int`（= `eventId`）、`HistoryEntry.result: String?`
  - `HistoryEntry.init(from: EpisodicEventDTO)`
  - `AppModel.historyEntries: [HistoryEntry]`（`@Published`）、`AppModel.refreshHistory() async`

- [ ] **Step 1: 写失败测试**

```swift
final class HistoryEntryMappingTests: XCTestCase {
    func testTranscribeRowMapsDeliveredTextToResult() {
        let dto = EpisodicEventDTO(
            id: 42, createdAt: 1_700_000_000_000, mode: "transcribe",
            rawTranscript: "呃明天开会", correctedTranscript: "呃明天开会",
            effectiveInput: nil, selectedContext: nil, result: "明天开会",
            applicationName: "WeChat", origin: "owner", conversationId: nil
        )
        let entry = HistoryEntry(from: dto)
        XCTAssertEqual(entry.id, 42)
        XCTAssertEqual(entry.applicationName, "WeChat")
        XCTAssertEqual(entry.result, "明天开会")
        XCTAssertEqual(entry.mode, .transcribe)
    }

    func testRowWithoutResultKeepsNilRatherThanEchoingTranscript() {
        let dto = EpisodicEventDTO(
            id: 43, createdAt: 1, mode: "transcribe",
            rawTranscript: "x", correctedTranscript: "x",
            effectiveInput: nil, selectedContext: nil, result: nil,
            applicationName: "App", origin: "owner", conversationId: nil
        )
        // 把 transcript 复制进 result 会让列表把「没交付成功」显示成
        // 「交付了原文」—— 两种情况在界面上必须能分开
        XCTAssertNil(HistoryEntry(from: dto).result)
    }
}
```

`HistorySearchTests` 里既有的 `HistoryEntry(...)` 构造改成 `id: Int` 与 `result: String?`，断言不变——搜索行为必须一字不改。

- [ ] **Step 2: 跑测试确认红**

Run: `swift test --filter HistoryEntryMappingTests`
Expected: FAIL —— `EpisodicEventDTO` 不存在，`HistoryEntry.id` 仍是 `UUID`。

- [ ] **Step 3: 实现**

`Models.swift`：`HistoryEntry.id: Int`、`result: String?`，新增 `EpisodicEventDTO: Decodable` 与 `HistoryEntry.init(from:)`。

`AppModel.swift`：删 `history` 属性，新增

```swift
@Published private(set) var historyEntries: [HistoryEntry] = []

func refreshHistory() async {
    struct Body: Decodable { let events: [EpisodicEventDTO] }
    guard let body: Body = try? await sidecarClient.request(
        method: "GET", path: "/memory/events?limit=200"
    ) else { return }
    historyEntries = body.events.map(HistoryEntry.init(from:))
}

func deleteHistoryEntry(id: Int) async {
    _ = try? await sidecarClient.request(method: "DELETE", path: "/memory/events/\(id)") as EmptyBody
    await refreshHistory()
}
```

`resetHistory()` 改成打 `DELETE /memory/events`（保留既有的 `DELETE /memory/context-log`），成功后 `await refreshHistory()`。

`DictationViews.swift`：把 `history.entries` 全部换成 `model.historyEntries`；`model.history.delete(id:)` 换成 `await model.deleteHistoryEntry(id:)`；视图顶层加 `.task { await model.refreshHistory() }`。`sources`/`filtered`/按天分组/`HistorySearch`/`HistoryExport` **一行不动**。

`SettingsViews2.swift`：条数显示改 `model.historyEntries.count`。

**刷新时机**：Task 5 的 `recordEpisodicEvent` 发送成功后触发一次 `refreshHistory()`。

- [ ] **Step 4: 跑测试确认绿**

Run: `swift test && swift build`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/OpenType Tests/OpenTypeTests
git commit -m "Read dictation history from the one place it now lives"
```

---

## Task 8: 删除 Swift 侧记忆层

**Files:**
- Delete: `Sources/OpenType/AgentMemoryStore.swift`, `MemoryInsightsAnalyzer.swift`, `OwnerProfileAutoUpdater.swift`, `HistoryStore.swift` 及 `Tests/OpenTypeTests/` 下对应测试
- Modify: `Sources/OpenType/AppModel.swift`, `AppConfiguration.swift`, `SettingsViews2.swift`

**Interfaces:**
- Consumes: Task 7 已经把最后一个 `history` 消费者搬走
- Produces: 无新接口。删除即交付。

- [ ] **Step 1: 写失败测试**

本 Task 的测试是「删完之后整套仍然全绿」，不新增测试文件。先跑一次基线并记下数字：

Run: `swift test 2>&1 | tail -5`
记录当前通过数，作为 Step 4 的比对基准（应当只减少被删文件自带的那些用例）。

- [ ] **Step 2: 确认没有残留引用**

Run: `grep -rn "agentMemory\|AgentMemoryStore\|HistoryStore\|MemoryInsights\|OwnerProfileAutoUpdater\|agentMemoryEnabled" Sources/ Tests/`
Expected: 只剩下要删的那些文件自身。若 `Sources/` 里还有别处引用，先补 Task 7 的遗漏。

- [ ] **Step 3: 删除**

```bash
git rm Sources/OpenType/AgentMemoryStore.swift \
       Sources/OpenType/MemoryInsightsAnalyzer.swift \
       Sources/OpenType/OwnerProfileAutoUpdater.swift \
       Sources/OpenType/HistoryStore.swift
git rm Tests/OpenTypeTests/AgentMemoryStoreTests.swift \
       Tests/OpenTypeTests/MemoryInsightsAnalyzerTests.swift \
       Tests/OpenTypeTests/OwnerProfileAutoUpdaterTests.swift \
       Tests/OpenTypeTests/HistoryStoreTests.swift
```

（实际文件名以 `ls Tests/OpenTypeTests/ | grep -iE "agentmemory|historystore|memoryinsights|ownerprofile"` 为准。）

`AppModel.swift` 删掉 `agentMemory` 属性、`importHistoryIfNeeded`/`refreshOwnerProfileIfNeeded`/`agentMemory.record` 全部调用、`resetAgentMemory()`。
`AppConfiguration.swift` 删 `agentMemoryEnabled` 及其 `Keys` 条目与默认值。
`SettingsViews2.swift` 删「重置 Agent 记忆」按钮及其确认弹窗。

- [ ] **Step 4: 跑测试确认绿**

Run: `swift build && swift test 2>&1 | tail -5`
Expected: PASS，通过数只比 Step 1 少掉被删测试文件的用例数，没有其他失败。

- [ ] **Step 5: 提交**

```bash
git commit -am "Delete the memory layer nothing read"
```

---

## Task 9: `buildRecentActivityContext` 渲染

**Files:**
- Create: `sidecar/src/memory/recentActivity.ts`, `sidecar/test/memory/recentActivity.test.ts`

**Interfaces:**
- Consumes: Task 2 的 `EpisodicEventRow`
- Produces:
  ```ts
  export const RECENT_ACTIVITY_LIMIT = 10;
  export const RECENT_ACTIVITY_FIELD_MAX = 120;
  export const RECENT_ACTIVITY_EXCLUDED_MODES: readonly string[] = [];
  export function buildRecentActivityContext(
    rows: EpisodicEventRow[],
    opts: { includeIds: boolean }
  ): string;
  ```
  （`RECENT_ACTIVITY_EXCLUDED_MODES` 在本 Task 定义、Task 10 消费。它与
  `MemoryStore` 的 `CONSOLIDATION_EXCLUDED_MODES` 是**两个独立常量**，
  刻意不共用——见 spec §3.4。）

> **已决**：`RECENT_ACTIVITY_EXCLUDED_MODES = []`——三个模式全部注入，不留开关。
> 这推翻了一条已发布的对外承诺（spec §六列出了全部三个仓库里的位置），
> 改写工作在 Task 12，与本 Task 无关。**本 Task 的渲染函数本身不关心这件事**。

- [ ] **Step 1: 写失败测试**

```ts
import { describe, expect, test } from "bun:test";
import { buildRecentActivityContext } from "./recentActivity";

function row(patch: Partial<EpisodicEventRow>): EpisodicEventRow {
  return {
    id: 1, createdAt: 1, mode: "ask", rawTranscript: "r", correctedTranscript: "c",
    effectiveInput: null, selectedContext: null, result: null,
    applicationName: "App", origin: "owner", conversationId: null,
    consolidatedAt: null, ...patch,
  };
}

describe("buildRecentActivityContext", () => {
  test("每行一个 JSON 对象，键名与工具参数名一致", () => {
    const out = buildRecentActivityContext(
      [row({ id: 43, mode: "ask", correctedTranscript: "天气怎么样",
             result: "多云转晴", conversationId: 17, applicationName: "Safari" })],
      { includeIds: true }
    );
    const lines = out.trim().split("\n");
    expect(lines[0]).toContain("opentype__read_history");
    expect(JSON.parse(lines[1])).toEqual({
      eventId: 43, mode: "ask", app: "Safari",
      conversationId: 17, input: "天气怎么样", result: "多云转晴",
    });
  });

  test("缺的键不出现，而不是写成 null", () => {
    const out = buildRecentActivityContext(
      [row({ id: 42, mode: "transcribe", correctedTranscript: "明天开会",
             result: null, conversationId: null, applicationName: "WeChat" })],
      { includeIds: true }
    );
    const obj = JSON.parse(out.trim().split("\n")[1]);
    expect(obj).toEqual({ eventId: 42, mode: "transcribe", app: "WeChat", input: "明天开会" });
    expect("result" in obj).toBe(false);
    expect("conversationId" in obj).toBe(false);
  });

  test("includeIds 为假时输出里没有任何 id", () => {
    const out = buildRecentActivityContext(
      [row({ id: 43, mode: "ask", correctedTranscript: "问", result: "答", conversationId: 17 })],
      { includeIds: false }
    );
    const obj = JSON.parse(out.trim().split("\n")[1]);
    expect(obj).toEqual({ mode: "ask", app: "App", input: "问", result: "答" });
    // 表头那句取回提示也不该出现 —— ask 没有那个工具
    expect(out).not.toContain("opentype__read_history");
  });

  test("超长字段截断到 120 字并加省略号", () => {
    const long = "字".repeat(200);
    const out = buildRecentActivityContext(
      [row({ correctedTranscript: long, result: long })], { includeIds: true }
    );
    const obj = JSON.parse(out.trim().split("\n")[1]);
    expect(obj.input).toHaveLength(121); // 120 + "…"
    expect(obj.input.endsWith("…")).toBe(true);
  });

  test("空列表返回空字符串 —— 不产生一个只有表头的块", () => {
    expect(buildRecentActivityContext([], { includeIds: true })).toBe("");
  });

  test("保持传入顺序（调用方已保证旧→新）", () => {
    const out = buildRecentActivityContext(
      [row({ id: 1, correctedTranscript: "一" }), row({ id: 2, correctedTranscript: "二" })],
      { includeIds: true }
    );
    const inputs = out.trim().split("\n").slice(1).map((l) => JSON.parse(l).input);
    expect(inputs).toEqual(["一", "二"]);
  });
});
```

- [ ] **Step 2: 跑测试确认红**

Run: `cd sidecar && bun test test/memory/recentActivity.test.ts`
Expected: FAIL —— 模块不存在。

- [ ] **Step 3: 实现**

```ts
import type { EpisodicEventRow } from "./MemoryStore";

/**
 * MODEL EXPERIENCE: 本模块的输出逐字注入 ask/agent 的 user 消息。
 * 渲染规则与 token 量级见 `docs/model-context-inventory.md` §3.9 ——
 * 改这里的同一个改动里更新那一节。
 */

export const RECENT_ACTIVITY_LIMIT = 10;
export const RECENT_ACTIVITY_FIELD_MAX = 120;

const HEADER_WITH_TOOL =
  "Recent activity, oldest first. Expand any entry with opentype__read_history.";
const HEADER_PLAIN = "Recent activity, oldest first.";

function clip(text: string): string {
  const normalized = text.replace(/\s+/gu, " ").trim();
  return normalized.length > RECENT_ACTIVITY_FIELD_MAX
    ? `${normalized.slice(0, RECENT_ACTIVITY_FIELD_MAX)}…`
    : normalized;
}

/**
 * 选 JSON 而非紧凑写法（`[#43 ask · conv 17]`）的决定性理由：**键名与工具参数
 * 名一字不差**。`{"eventId":43}` 对应的调用就是
 * `opentype__read_history({eventId: 43})`，零翻译；紧凑写法要求模型先解析一套
 * 自造语法，再把 `conv 17` 心算成 `conversationId: 17`，而「`#` 指哪个 id」
 * 只能靠表头说明 —— 表头是最容易被忽略的一行。代价约 15–20% token，
 * 换的是不会认错 id 去读了另一段不相干的历史再据此回答。
 *
 * 缺的键直接不写：`null` 既费 token 又在暗示模型可以把 null 传回工具。
 *
 * `includeIds` 为假时连表头的取回提示一起去掉 —— ask 没有那个工具，
 * 够不着的东西不该出现在它眼前。
 */
export function buildRecentActivityContext(
  rows: EpisodicEventRow[],
  opts: { includeIds: boolean }
): string {
  if (rows.length === 0) {
    return "";
  }
  const lines = rows.map((r) => {
    const entry: Record<string, unknown> = {};
    if (opts.includeIds) entry.eventId = r.id;
    entry.mode = r.mode;
    entry.app = r.applicationName;
    if (opts.includeIds && r.conversationId != null) entry.conversationId = r.conversationId;
    entry.input = clip(r.correctedTranscript);
    if (r.result != null && r.result.trim() !== "") entry.result = clip(r.result);
    return JSON.stringify(entry);
  });
  const header = opts.includeIds ? HEADER_WITH_TOOL : HEADER_PLAIN;
  return [header, ...lines].join("\n");
}
```

注意键序：`eventId` → `mode` → `app` → `conversationId` → `input` → `result`，与测试的 `toEqual` 无关但与人读日志有关，保持稳定。

- [ ] **Step 4: 跑测试确认绿**

Run: `cd sidecar && bun test test/memory/recentActivity.test.ts`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add sidecar/src/memory/recentActivity.ts sidecar/test/memory/recentActivity.test.ts
git commit -m "Render recent turns as JSON the tool can take back"
```

---

## Task 10: 注入 ask 与 agent

**Files:**
- Modify: `sidecar/src/agent/loop.ts`, `sidecar/src/oneshot/routes.ts`, `sidecar/src/agent/routes.ts`
- Test: `sidecar/test/agent/loop.test.ts`, `sidecar/test/oneshot/routes.test.ts`, `sidecar/test/agent/routes.test.ts`

**Interfaces:**
- Consumes: Task 2 的 `recentEvents`，Task 9 的 `buildRecentActivityContext`
- Produces: `RunAgentLoopInput.recentActivity?: string`

- [ ] **Step 1: 写失败测试**

```ts
// loop.test.ts
test("recentActivity 进 user 消息，不进 system 消息", async () => {
  const seen: AgentChatMessage[][] = [];
  await runAgentLoop(
    { task: "做事", recentActivity: "Recent activity, oldest first.\n{\"mode\":\"ask\"}" },
    { chat: recordingChat(seen), tools: emptyToolSet() }
  );
  const messages = seen[0];
  expect(messages[0].role).toBe("system");
  expect(messages[0].content).not.toContain("Recent activity");
  expect(messages[messages.length - 1].content).toContain("Recent activity");
});
```

```ts
// oneshot/routes.test.ts
test("ask 注入最近活动，且不含 id", async () => {
  const store = new MemoryStore(openDatabase(":memory:"));
  store.recordEpisodicEvent(base({ mode: "transcribe", correctedTranscript: "明天去深圳" }));
  const seen = captureChat();
  await postAsk(store, seen, { question: "那边天气怎么样" });
  const sent = seen.lastUserMessage();
  expect(sent).toContain("明天去深圳");
  expect(sent).not.toContain("eventId");
});

test("注入块不含当前这一轮的问题 —— 事件在答完之后才写", async () => {
  const store = new MemoryStore(openDatabase(":memory:"));
  const seen = captureChat();
  await postAsk(store, seen, { question: "这是当前这一轮" });
  expect(seen.lastUserMessage()).not.toContain("Recent activity");
});
```

```ts
// agent/routes.test.ts
test("agent 注入最近活动，且带 eventId", async () => {
  const store = new MemoryStore(openDatabase(":memory:"));
  store.recordEpisodicEvent(base({ mode: "transcribe", correctedTranscript: "明天去深圳" }));
  const seen = captureChat();
  await postAgentRun(store, seen, { task: "帮我订票" });
  const sent = seen.lastUserMessage();
  expect(sent).toContain("明天去深圳");
  expect(sent).toContain("eventId");
});
```

- [ ] **Step 2: 跑测试确认红**

Run: `cd sidecar && bun test test/agent/loop.test.ts src/oneshot src/agent/routes.test.ts`
Expected: FAIL —— `recentActivity` 不是 `RunAgentLoopInput` 的字段，注入块不出现。

- [ ] **Step 3: 实现**

`loop.ts` 的 `RunAgentLoopInput` 加：

```ts
/**
 * 最近若干条跨模式输入，`memory/recentActivity.ts` 渲染。
 *
 * 与 `knownTerms`/`runtimeContext` 并列拼进**最后一条 user 消息**，
 * 绝不进 system 提示：它每次请求都变，放进 system 会让整个 KV cache 前缀
 * 失效（`docs/model-context-inventory.md` §5）。
 */
recentActivity?: string;
```

在 `if (input.knownTerms)` 那一段之后照同样形状加：

```ts
if (input.recentActivity) {
  userContentParts.push("", input.recentActivity);
}
```

`oneshot/routes.ts` 的 `handleAsk` 里，取 `knownTerms` 之后：

```ts
// RECENT_ACTIVITY_EXCLUDED_MODES 为空：三个模式全部注入，包括听写。
// 这是一次知情的对外承诺变更（spec §六），不是疏漏 —— 参数保留是为了
// 将来若要做「按 app 排除」「按时间窗排除」时有现成接缝。
const recentActivity = buildRecentActivityContext(
  store.recentEvents(RECENT_ACTIVITY_LIMIT, { excludeModes: RECENT_ACTIVITY_EXCLUDED_MODES }),
  { includeIds: false }
);
```

`agent/routes.ts` 同样，`includeIds: true`。两处共用一个导出常量：

```ts
// sidecar/src/memory/recentActivity.ts
export const RECENT_ACTIVITY_EXCLUDED_MODES: readonly string[] = ["transcribe"];
```

- [ ] **Step 4: 跑测试确认绿**

Run: `cd sidecar && bun test`
Expected: PASS（全套）。

- [ ] **Step 5: 提交**

```bash
git add sidecar/src
git commit -m "Let both modes see what just happened"
```

---

## Task 11: `opentype__read_history` 工具

**Files:**
- Create: `sidecar/src/agent/readHistoryTool.ts`, `sidecar/test/agent/readHistoryTool.test.ts`
- Modify: `sidecar/src/agent/coreTools.ts`

**Interfaces:**
- Consumes: Task 2 的 `recentEvents`、`ConversationStore.getConversation`
- Produces: 工具名常量 `READ_HISTORY_TOOL_NAME = "opentype__read_history"`，handler `handleReadHistory(args, deps): Promise<string>`

- [ ] **Step 1: 写失败测试**

```ts
test("eventId 取回未截断全文与来源 app", async () => {
  const store = new MemoryStore(openDatabase(":memory:"));
  const long = "字".repeat(500);
  const id = store.recordEpisodicEvent(base({
    mode: "transcribe", correctedTranscript: long, applicationName: "WeChat",
  }));
  const out = await handleReadHistory({ eventId: id }, { store, conversations });
  expect(out).toContain(long);          // 未截断
  expect(out).toContain("WeChat");
});

test("conversationId 取回完整消息序列", async () => {
  const convId = conversations.createConversation("ask", "天气");
  conversations.appendMessage(convId, "user", "明天那边天气怎么样");
  conversations.appendMessage(convId, "assistant", "多云转晴");
  const out = await handleReadHistory({ conversationId: convId }, { store, conversations });
  expect(out).toContain("明天那边天气怎么样");
  expect(out).toContain("多云转晴");
});

test("两个 id 都不给时返回最近 limit 条未截断事件", async () => {
  const store = new MemoryStore(openDatabase(":memory:"));
  const long = "字".repeat(500);
  store.recordEpisodicEvent(base({ correctedTranscript: long }));
  const out = await handleReadHistory({ limit: 5 }, { store, conversations });
  expect(out).toContain(long);
});

test("不存在的 id 返回可读的说明而不是抛错", async () => {
  const out = await handleReadHistory({ eventId: 99999 }, { store, conversations });
  expect(out).toContain("99999");
  expect(out.toLowerCase()).toContain("no");
});

test("ask 的工具集里没有它", () => {
  const filtered = filterToolSet(coreToolSet(), ["opentype__web_search", "opentype__web_fetch"]);
  const names = (filtered.openAiTools as any[]).map((t) => t.function.name);
  expect(names).not.toContain("opentype__read_history");
});
```

- [ ] **Step 2: 跑测试确认红**

Run: `cd sidecar && bun test test/agent/readHistoryTool.test.ts`
Expected: FAIL —— 模块不存在。

- [ ] **Step 3: 实现**

`readHistoryTool.ts` 导出名称常量、`handleReadHistory`，以及供 `coreTools.ts` 拼进 `openAiTools` 的 schema：

```ts
export const READ_HISTORY_TOOL_NAME = "opentype__read_history";

export const READ_HISTORY_TOOL_SCHEMA = {
  type: "function",
  function: {
    name: READ_HISTORY_TOOL_NAME,
    description:
      "Read the user's own past turns in full. Pass eventId (from the Recent activity block) " +
      "for one turn's complete, untruncated record including which app it happened in; pass " +
      "conversationId for a whole ask/agent thread; pass neither to list the most recent turns " +
      "in full. Read-only.",
    parameters: {
      type: "object",
      properties: {
        eventId: { type: "number", description: "One turn's id, as shown in Recent activity." },
        conversationId: { type: "number", description: "A thread's id, as shown in Recent activity." },
        limit: { type: "number", description: "How many recent turns to list when no id is given; defaults to 10." },
      },
    },
  },
};
```

handler 返回纯文本（未截断），三条分支照测试。找不到时返回
`` `No history entry with eventId ${id}.` `` 这类可读说明，不抛错——
让模型能自己改主意，而不是把一次探查变成一次工具错误。

`coreTools.ts`：把 `READ_HISTORY_TOOL_NAME → handleReadHistory` 加进 handler Map，
`READ_HISTORY_TOOL_SCHEMA` 加进 `openAiTools` 数组。**不需要**在 ask 那边加排除逻辑——
`ASK_TOOL_NAMES` 是白名单，天然拿不到。

`coreTools` 的构造需要 `ConversationStore`，从 `server.ts` 传入（`store.db` 已经共用同一个
`Database`，所以 `new ConversationStore(store.db)` 即可，不新开连接）。

- [ ] **Step 4: 跑测试确认绿**

Run: `cd sidecar && bun test`
Expected: PASS（全套）。

- [ ] **Step 5: 提交**

```bash
git add sidecar/src/agent
git commit -m "Give the agent a way to open what it was shown"
```

---

## Task 12: 文档同步

**Files:**
- Modify: `CLAUDE.md`, `docs/model-context-inventory.md`, `USER_GUIDE.md`, `sidecar/src/memory/MemoryStore.ts`（注释）

**Interfaces:** 无代码接口。

- [ ] **Step 0: 两处因 Task 3 而失效的代码注释**

- `sidecar/src/agent/routes.ts` 第 206–211 行 catch 块的注释说取消路径「**刻意**不写 episodic 事件」。
  这条注释描述的是一个该路由已经不再做的决定——它现在无论成功还是取消都不写。
  留着会让下一个读者以为这里有一处特殊处理。
- `sidecar/src/server.ts` 里 `buildAsrRoutes` 那段注释已由 Task 3 改写，核对一遍即可。

- [ ] **Step 1: 改 `MemoryStore.ts` 的 `CONSOLIDATION_EXCLUDED_MODES` 注释**

现注释说「plain dictation never reaches an LLM」并列举 README / USER_GUIDE §13 / CLAUDE.md。
改写成新的口径：**整理（一次真实 LLM 调用、产出长期记忆）继续排除听写；
即时上下文注入是另一件事，边界由 `recentActivity.ts` 的
`RECENT_ACTIVITY_EXCLUDED_MODES` 单独决定。** 并指明两者是两个独立查询、
为什么不合并。

- [ ] **Step 2: 改 `CLAUDE.md`**

- 删 `HistoryStore` 段落（文件已不存在），顺带记录它此前写的「100-entry cap」是错的，实际默认值是 1000。
- 删 `AgentMemoryStore` 段落。
- 修 `/agent/run` 请求体：写的是 `task + selectedText + conversationId`，实际是 `task + context + conversationId + runId`（字段名是 `context` 不是 `selectedText`）。
- 新增：Swift 单写入点、`recentActivity` 注入、`opentype__read_history`、两份存储的新分工。

- [ ] **Step 3: 改 `docs/model-context-inventory.md`**

- §3 新增 §3.9「`Recent activity` JSONL 块」：渲染规则、两种形态（含/不含 id）、token 量级、`RECENT_ACTIVITY_EXCLUDED_MODES` 当前值。
- §3.6 补 `opentype__read_history` 的结果回灌。
- §4 漂移表：`AgentMemoryStore` 相关各行从「已删除读取侧」更新为「整个存储已删除」。
- §5 新增一个正例：`recentActivity` 为什么必须进 user 消息。

- [ ] **Step 4: 改 `USER_GUIDE.md` —— 13 处，一处都不能漏**

逐行盘点已完成。**两个 README 一处都不用改**（它们只说「听写不需要 API Key、
不需要联网」，2.0.0 之后依然为真——改它们会毁掉一句准确的话）。

| 行 | 判定 | 说明 |
|---|---|---|
| L7 | CHANGE | 全文档最顶部的承诺：「听写的内容永远不会被发给模型」 |
| L115 | CHANGE | 模式表格「是否经过 AI 模型」列，听写行 |
| L184 | NEEDS-CARE | 前半句「轻整理不经过任何模型」**为真，保留**；结尾「文字不出本机」为假，拆开重写 |
| L257 | NEEDS-CARE | 「原始的听写本身仍然不经过模型」——窄义为真，但紧邻已失效的全局主张，易被误读为重申 |
| L420–422 | NEEDS-CARE | 「不会成为整理原料」**为真**；「也就不会被发给模型」是错误推论，拆开 |
| **L444** | **REWRITE** | 它写了一个**论证**：「延迟发送也是发送」。2.0.0 做的正是那件事——留着等于产品自己写下对自己新行为的指控。必须处理掉这句修辞，不是只改周围事实 |
| **L446** | **REWRITE** | 「需要一个明确的开关……当前版本没有提供，也不会偷偷替你打开」。改成「1.2.0 及以前如此；2.0.0 起变了，且确实没有开关——这是有意的产品决定」。**不能删**，删掉等于让读过旧版的人无从知道口径变过 |
| L452 | CHANGE | 转写设置项：「没有一档会把听写内容发给 AI 模型」 |
| L566 | CHANGE | §14 的锚点主张，整段重写 |
| L567 | NEEDS-CARE | 整理排除为真；「上面那句……依然成立」不再成立 |
| L569 | **ADD** | 「问答/Agent 会发送什么」清单——**新增一项**：最近 10 条跨模式上下文（含听写） |
| L575 | CHANGE | 「听写的那份纯本地留存」不再准确 |
| L593 | CHANGE | §15 使用原则的四条要点之一，略读者最依赖 |

**明确保留、不要动**：

- **L586** —— 「送出去的只有问答和 Agent 的记录，听写被排除在外」。这句**仍然为真**：
  它说的是**记忆整理**，而整理与即时注入是两个独立查询、规则不同（spec §3.4）。
- **L148** —— 「不会调用任何 AI 模型」，作用域是 Direct 交付的那一瞬，字面仍为真。

**守住这条区别**：语音**识别**默认在本机跑、音频识别完即删——仍然为真，不要连它一起删。
变的是**识别出来的文字**会进入之后的请求，不是「音频上云」。

- [ ] **Step 5: 提交**

```bash
git add CLAUDE.md docs/model-context-inventory.md USER_GUIDE.md sidecar/src/memory/MemoryStore.ts
git commit -m "Say what the code now says"
```

---

## Task 13: 站点改写（独立仓库 `opentype-site`）

**Files（注意：不在本仓库）:**
- Modify: `/Users/diywang/hackathon/opentype-site/i18n.js`, `index.html`, `releases.html`

**Interfaces:** 无代码接口。部署目标 opentype-site.vercel.app。

- [ ] **Step 1: 改隐私文案 —— 6 处，中英对称**

| 位置 | 判定 |
|---|---|
| `i18n.js:38` `modes.transcribe.body`（中） | CHANGE：「纯转写，**完全不经过任何大模型**」 |
| `i18n.js:68` `privacy.line`（中） | CHANGE：「『听写』完全不经过大模型」 |
| `i18n.js:170` `modes.transcribe.body`（英） | CHANGE："no model in the loop at all" |
| `i18n.js:200` `privacy.line`（英） | CHANGE："Transcribe never touches a model" |
| `index.html:183` | CHANGE：`modes.transcribe.body` 的硬编码英文兜底 |
| `index.html:254` | CHANGE：`privacy.line` 的硬编码英文兜底 |

**`index.html` 的兜底必须与 `i18n.js` 对应条目逐字节一致。** 页面默认 `lang="en"`，
中文由 JS 从 `i18n.js` 换入；只改 `i18n.js` 会让页面在 JS 执行前、以及默认语言下
继续显示旧承诺。改完用 `diff <(...)` 之类的方式核对两边字符串完全相同。

**保持不动**：`i18n.js:57/189` `features.local.*`（识别在本机跑，仍为真）、
`i18n.js:72/204` `closing.body`（「纯听写不需要 API Key，也不需要联网」，仍为真）、
`index.html:8` meta description、`index.html:233`。
`index.html:18` 的 `og:description`「Speech stays on your Mac by default」说的是
**audio**、不是文字，判定为可留——但它是这批里最容易被过度解读的一句，
执行时留意一下措辞是否值得收紧。

- [ ] **Step 2: 加 2.0.0 发布说明，并把承诺变更放在头条**

站点目前**根本没有 2.0.0 条目**——`i18n.js` 与 `releases.html` 都只到 `releases.120.*`，
而且 `hero.updates`（`i18n.js` 中文 L33 / 英文约 L165，以及 `index.html` 里它的兜底）
仍在宣传「1.2.0 有什么变化」。这三处都要跟着升到 2.0.0，不能只加条目不改入口。

`releases.html` 与 `i18n.js` 的 releases 段加 2.0.0 条目。**必须显式点名这条变更**，
理由是站点上已经存在一条 1.0.0 的修复记录（`i18n.js:133` 中文 / `:267` 英文）：

> 听写内容会经由记忆整理悄悄传到云端，与「听写不经过模型」的承诺相悖

产品公开把这件事当 bug 修过一次。2.0.0 主动做同一件事，**发布说明里若找不到这条，
读过 1.0.0 说明的用户只会读成「那个 bug 又回来了」**。措辞要点明区别：
上次是「悄悄地」，这次是明说的产品决定，为的是让三个模式共享同一份上下文。

- [ ] **Step 3: 本地核对**

Run: `cd /Users/diywang/hackathon/opentype-site && python3 -m http.server 8765`
打开 `http://localhost:8765/` 与 `/releases.html`，中英两种语言各看一遍，
确认没有残留的「完全不经过大模型」，也确认「识别不出本机」还在。

- [ ] **Step 4: 提交（在该仓库内）**

```bash
cd /Users/diywang/hackathon/opentype-site
git add i18n.js index.html releases.html
git commit -m "Say that dictation now feeds the context"
```

**不要自行 push 或部署**——那是对外发布动作，交给产品负责人。

---

## Task 14: Release 2.0.0

**Files:** `Resources/Info.plist`，以及 `grep -rn "1\.2\.0"` 命中的每一处版本号。

- [ ] **Step 1: 找全版本号**

Run: `grep -rn "1\.2\.0" --include=* . | grep -v node_modules | grep -v "^./.git"`
把命中位置列出来，逐一判断哪些是当前版本号、哪些是历史记录（发布说明里的历史条目**不要**改）。

- [ ] **Step 2: 改版本号并构建**

Run: `./scripts/build-app.sh`
Expected: `dist/OpenType.app` 产出，ad-hoc 签名成功。

- [ ] **Step 3: 全套测试**

Run: `swift test && cd sidecar && bun test`
Expected: 两套全绿。**这是发版前的硬门槛，不是形式。**

- [ ] **Step 4: 冒烟**

`open dist/OpenType.app`，实测一遍本设计的主路径：
听写一句 → 切问答问一个依赖那句话的问题 → 切 Agent 交一个依赖前两句的任务。
确认第 2、3 步的回答确实用上了第 1 步的内容——**这是整个批次的验收标准本身**。

- [ ] **Step 5: 提交**

```bash
git commit -am "Release 2.0.0"
```

**不打 tag、不发布**——交给产品负责人。

---

## 依赖与并行

```
Task 1 ──┬─ Task 2 ──┬─ Task 3 ── Task 4 ── Task 5 ── Task 6 ── Task 7 ── Task 8
         │           │
         │           └─ Task 9 ── Task 10        （Task 10 需要 Task 5 已落地，
         │                                        否则每轮多一行伪装成听写的记录）
         └─────────────  Task 11                （只需要 Task 2 的行结构）

Task 12 最后。
```

Task 11 可与 3–8 并行。Task 9 可与 3–8 并行，但 **Task 10 必须等 Task 5**。

Task 12（本仓库文档）与 Task 13（站点）互不依赖，可并行，但两者都必须等 Task 10 落地——
在代码真的开始注入听写之前改掉承诺，文档就领先于事实，那是另一种谎。

**Task 14 最后**，且它的 Step 4 冒烟是整个批次的验收：
听写一句 → 问答问一个依赖那句话的问题 → Agent 交一个依赖前两句的任务。
这三步跑通，这个批次才算交付；跑不通，前面 13 个 Task 全绿也不算。
