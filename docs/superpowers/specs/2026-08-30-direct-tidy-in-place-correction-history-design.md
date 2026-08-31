# 2026-08-30 Direct/Tidy 就地纠错后的记忆回写

Status: approved（产品负责人确认，本批 Stage-1 测试即契约）。
基线：`fix/cwd-and-correction-history` @ `cd58850`（该分支上的 cwd 批次 `437bed3` 与本批无关，仅同分支共存）。

执行方式：按 CLAUDE.md 约定的 4 阶段 TDD 管线。本文件描述本批全部行为；实现偏离时回来改这份文档，不要让它烂掉。

---

## 一、为什么

Direct/Tidy 模式的 P0-3 纠错窗口：交付之后用户再补一句，把**目标应用里刚插入文本的选中部分**换成正确的说法。此时只把 replacement 粘回目标应用——但听写历史页与 ask/agent 的「近期活动」记忆注入读的是 `episodic_events` 表里的 `correctedTranscript`/`result`，这两列**从不更新**。于是：

- 听写历史页永远显示纠错前的整段文字；
- 后续 ask/agent 请求的记忆上下文里，这条输入也是错的版本——**用户明确纠正过的事实被持续学错**；
- `.corrected` 审计事件链（`supersedesEventId`）只记录纠错动作本身，不带回整段结果。

Swift 是唯一同时知道「交付的整段文本」和「这次纠错选了哪段、替换成什么」的一侧，所以回写必须从 Swift 发起，sidecar 只提供一个窄的 PATCH 口子。

## 二、目标与非目标

**目标**

- 一条就地纠错落地后，把对应 `episodic_events` 行的 `correctedTranscript` 与 `result` 更新为纠错后的整段文本，`rawTranscript`（ASR 原话）永不改动。
- 更新后，听写历史页与近期活动注入（`buildRecentActivityContext`）都显示新文本——后者不需要 Swift 额外做什么，sidecar 单表更新即天然生效。
- Swift 侧做纯文本判断：选中串在交付整段中恰出现一次才能安全回写；缺席或多次出现（无法确定指哪一处）则整次回写放弃，不动历史。

**非目标**

- 不做 UI 改动（历史页/记忆页数据源不变，只是内容更准了）。
- 不写数据迁移：只 UPDATE 现有行，不新增列。
- 不改审计链：`recordAuditEvent` 的 `.corrected` 事件照旧，本批只在旁边补一次 best-effort 的 episodic PATCH。
- 不覆盖 Review 面板模式（`POST /transcribe/correct` 那条路不动）——本批只管 Direct/Tidy 的**就地**纠错。

## 三、契约（三处 seam，均已有 Stage-1 测试）

### 3.1 sidecar：`PATCH /memory/events/:id`

- 请求体 `{ correctedTranscript: string, result: string }`——两字段**都必填**、都须非空白；缺失或空白 → 400，行不动。
- 成功 → 200，`{ event: <整行> }`；只更新两列，`rawTranscript` 及其余列原样。
- 数字 id 不存在 → 404；负 id → 404（与现有 DELETE 约定一致：没改成东西不算成功）；非数字 id → 400 `{ error: "invalid_id" }`（复用 `parseIdParam`）。
- PATCH 后 `GET /memory/events` 与 `recentActivity` 均读到新文本。

### 3.2 Swift：`DeliveredTextCorrection.reconstruct(deliveredText:selectedText:replacement:) -> String?`

纯同步、无 I/O、无 provider 调用（对齐 `TidyTranscript` 的定位）。`selectedText` 在 `deliveredText` 中恰出现一次 → 返回整段替换后的完整文本；缺席或多次出现 → `nil`（放弃回写，绝不猜）。

### 3.3 Swift：`AppModel.historyEventCorrectionRequest(id:deliveredText:selectedText:replacement:) -> HistoryEventCorrectionRequest?`

`nil` ⇔ `reconstruct` 为 `nil`；否则 `method = "PATCH"`、`path = "/memory/events/\(id)"`、body 两字段均为 reconstruct 的整段结果（JSON 键恰为 `correctedTranscript`、`result`，不得携带 `rawTranscript`）。

## 四、实现要点

- **event id 留存**：`AppModel.recordEpisodicEvent` 现在把 `POST /memory/events` 返回的 `eventId` 丢了。Direct/Tidy 交付（可被就地纠错的变体）须留存该 id，供纠错路径 PATCH 用。注意只有 Direct/Tidy 有「已交付文本可被就地纠错」这回事——`ask`/`agent` 的 id 不得顶掉它（按模式感知地留存）。
- **就地纠错路径**：`processInPlaceCorrection(audioURL:session:)` 完成替换交付后，用 [3.2] 从「交付整段 + 选中串 + replacement」重建全文；非 nil 且留存 id 在 → 按 [3.3] 构造请求，经 `sidecarClient.request` best-effort 发出（fire-and-forget，失败不影响交付，与 `recordEpisodicEvent` 同一容错级别）。审计事件照旧。
- sidecar 路由实现沿用 `sidecar/src/memory/routes.ts` 的既有惯例（`parseIdParam`、`ApiError`、路由注释说明「为什么」）。

## 五、验证

- sidecar：`bun test test/memory/routes.test.ts` —— 9 个 PATCH 用例 + 该文件全部既有用例通过。
- Swift：`swift build` + `swift test --filter DeliveredTextCorrectionTests` / `--filter HistoryEventCorrectionRequestTests` 通过（`reconstruct` 的 6 例含 emoji/UTF-16 文本，实现不得用 UTF-16 偏移做匹配）。
- stage-4 评审通过后即提交（走 CLAUDE.md 的即提交约定）。

## 六、文档联动

- CLAUDE.md 记忆小节补一句：就地纠错会回写 `episodic_events` 的 `correctedTranscript`/`result`（本批完成后，「听写历史永远是纠错后版本」）。