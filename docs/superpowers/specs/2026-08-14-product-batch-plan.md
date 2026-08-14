# 2026-08-14 产品批次执行计划

Status: approved（产品负责人 2026-08-14 确认）。来源：`docs/reviews/2026-08-14-product-review.md` §3。

范围：该 review 的建议清单，**跳过第 9 条（边录边分段预转写）与第 11 条（DMG/公证 + Whisper 模型管理 UI）**
——两条另想办法，不在本批。

执行方式：每条走 CLAUDE.md 约定的 4 阶段 TDD 管线（写测试 → 审测试确认红 → 实现 → 审实现后即提交），
每阶段独立 Agent 分发。本文件是每条的设计输入；实现过程中若偏离，回来改这份文档，不要让它烂掉。

---

## 贯穿整批的一条主线

这批的重点不是 11 个独立功能，而是一条闭环：

```
用户说话 → 识别（被词典偏置）→ 交付 → 用户纠错 → 纠错入词典 → 下次识别更准
                ▲                                              │
                └──────────────────────────────────────────────┘
```

P0 的 4 条就是这个环的 4 段。它们必须一起做完才有意义——只做其中任何一条，用户都感觉不到差别。
P1/P2 是围绕这个环的收敛与体感。

---

## P0-1 词典回灌 ASR

**目标**：`entity_terms` 里的词条真正影响识别结果，而不是躺在 SQLite 里。

两个互相独立的机制，都要做：

### (a) `initial_prompt` 偏置（仅本地 MLX-Whisper）

`mlx_whisper.transcribe()` 原生支持 `initial_prompt`，把它当作前文提示，能显著提升专有名词命中率。

- `sidecar/whisper/serve.py`：`/transcribe` 接受 **query 参数** `initial_prompt`（URL-encoded）。选 query 而不是
  header 是因为 header 必须 latin-1 安全，中文词条要额外编码；`_path_only()` 已经用 `urlparse` 取 path，加
  query 不会破坏现有路由匹配。传给 `mlx_whisper.transcribe(..., initial_prompt=...)`。缺省不传时行为完全不变。
- `sidecar/src/asr/whisperClient.ts`：`transcribe(audio, initialPrompt?)` → `postAudio(socketPath, audio, initialPrompt?)`。
- 新纯模块 `sidecar/src/asr/dictionaryBias.ts`：
  - `buildInitialPrompt(terms, opts?) -> string`
    - 只取 **canonical term**，不取 aliases——目的是把模型往「正确写法」上带，别名进 prompt 反而会诱导它输出错的那个。
    - 排序：confidence 降序 → `updatedAt` 降序（近期用过的优先）。
    - 阈值：`confidence >= 0.6`。
    - 上限：最多 24 个词条 / 总长 200 字符（Whisper 的 prompt 上限是 224 token 的量级，超了会被截断且挤掉音频上下文）。
    - 输出形如 `"可能出现的专有名词：PayPal、Anthropic、OpenType。"`——给一个自然语句而不是裸列表，Whisper 的
      prompt 是当作「前一段转写文本」用的。
    - 空词典 → 返回空串，调用方不传参数。

  **信任边界**：`remember_fact` 写入的词条 origin 是 `"untrusted"`（P1-12 的刻意决定），但那条注释同时写明
  「stays usable for correction」。ASR 偏置属于 correction 类用途，不是 LLM prompt injection，因此**不按 origin
  过滤**，只按 confidence 过滤。风险边界写在 `dictionaryBias.ts` 的文档注释里：Whisper 有把 prompt 文本泄漏进
  输出的已知倾向，所以长度上限和「只放 canonical」这两条限制是安全措施而不是性能优化。

### (b) 转写后 alias → canonical 确定性替换（本地/远程都生效）

纯函数，同一个模块：`applyAliasCorrections(text, terms) -> { text, replacements }`

规则（每条都要有测试）：
- 长别名优先（先按长度降序排，避免短别名把长别名吃掉）。
- 别名长度 < 2 的直接跳过（噪声太大）。
- 别名与 canonical 忽略大小写相等时跳过（无意义替换）。
- ASCII 别名要求词边界（`\bpaypal\b` 不能命中 `paypalx`）；CJK 别名无词边界概念，直接子串匹配。
- ASCII 匹配忽略大小写，替换成 canonical 的原始大小写。
- 替换结果不再参与后续匹配（一遍扫描，不迭代，避免互相触发的死循环）。
- 返回 `replacements` 便于测试和将来在 UI 里显示「自动修正了 N 处」。
- **同名别名的胜者要确定**（实现阶段补的一条）：两个词条声明同一个别名是可达的——P0-2 自动写入，
  用户先把「呸泡」改成 PayPal、后来又改成「贝宝」，两条就都挂着「呸泡」。原设计只按长度排序，
  长度相同时靠数组到达顺序决定，而 `allTerms()` 是不带 `ORDER BY` 的 `SELECT *`：等于把这个选择交给
  SQLite 的行序，同一句话在一次无关写入之后就可能转写成另一个词，界面上还没有任何东西能解释。
  排序键改为 别名长度 → confidence → updatedAt → canonical 字典序，与 `buildInitialPrompt` 的偏好一致，
  最后一个键保证是全序而不是「通常能定下来」。

### 已核实：prompt 回显是真的（2026-08-14 实测）

`dictionaryBias.ts` 的文档注释原本把「Whisper 会把 prompt 泄进输出」写成传闻式的风险提示，并说
「真出现了就去看 `condition_on_previous_text`」。实测把两句都修正了：

- 泄漏是真的：2 秒**数字静音**，不带 prompt 转写出 `""`，带 prompt 转写出把 prompt 里的词拼回来的一段乱码。
- 但需要真正的全零采样才会触发。用真实麦克风噪声底（约 -55 dBFS）测，prompt 不回显，Whisper 原有的
  近静音幻觉（`Thank you.`）带不带 prompt 都一样出现——也就是说这条不是正常录音会遇到的失败模式，
  而是麦克风被静音/设备无输入时才会露头。
- `condition_on_previous_text=False` **不管用**（实测过）。回显发生在第一个解码窗口内，而 prompt 永远
  条件化第一个窗口。真要压住得按 `no_speech_prob`/`avg_logprob` 丢段，那要动的阈值同时管着「轻声说话」，
  是产品决定不是局部改动，本批没做。长度上限和「只放 canonical」是目前唯一在限制损害面的东西。

### 接线

`buildAsrRoutes` 从 `(transcribe)` 变成 `(transcribe, deps?)`，`deps` 提供 `listTerms(): EntityTerm[]`。路由内：
取词条 → 建 prompt → `transcribe(audio, { initialPrompt })` → 对结果做 alias 替换 → 返回 `{ text }`。
这样两个机制都在**一个可测的地方**，且远程 Whisper 也自动享受替换（它拿不到 initial_prompt，但拿得到替换）。

`server.ts` 的 `resolveTranscribe` 签名加上 `options: { initialPrompt?: string }`，远程分支忽略它。

**不做**：`language` 参数透传（「转写语言」名不副实那条）不在本批，单独处理。

### 已核实的 mlx_whisper 签名（2026-08-14，本机 `sidecar/whisper-env`）

不要靠猜。实测 `inspect.signature(mlx_whisper.transcribe)`：

```
['audio', 'path_or_hf_repo', 'verbose', 'temperature', 'compression_ratio_threshold',
 'logprob_threshold', 'no_speech_threshold', 'condition_on_previous_text',
 'initial_prompt', 'word_timestamps', 'prepend_punctuations', 'append_punctuations',
 'clip_timestamps', 'hallucination_silence_threshold', 'decode_options']
```

- `initial_prompt` 是**真实的具名参数**，本条设计成立。
- `language` **不是**顶层参数，它走 `**decode_options`。将来做「转写语言」那条时按 `language=...` 传进
  decode_options，别去加顶层参数。
- 同时注意 `condition_on_previous_text` 存在——它和 initial_prompt 是相关旋钮，如果将来发现 prompt 文本
  被回显进结果，这是第一个该看的开关。

---

## P0-2 纠错自动入词典

`POST /transcribe/correct` 成功返回 `replacement` 之后，把「被替换的原文 → 替换文本」当作
`alias → canonical` 写进 `entity_terms`，复用 `upsertEntityTerm`（和 `remember_fact` 同一条合并路径，不新开写法）。

入典门槛（纯函数 `shouldLearnCorrection(selectedText, replacement)`，单独可测）：
- 两边都非空，且去空白后不相等（忽略大小写）。
- 被替换的原文长度 ≤ 24 字符——整段重写不是「术语纠错」，不入典。
- 替换文本长度 ≤ 24 字符，且**不含换行**。
- 替换文本不包含被替换原文（避免把「PayPal」学成「PayPal 转账」的别名）。
- 两边都不是纯标点/纯空白。

写入参数：`category: "term"`、`confidence: 0.8`、`origin: "owner"`——这是用户**亲手改的**，比
`remember_fact` 经过 agent context 的路径可信，所以给 owner 而不是 untrusted。confidence 给 0.8 而不是 1.0，
留出「用户显式说记住」（1.0）的优先级空间。

`/transcribe/correct` 目前**刻意不依赖 `MemoryStore`**（文档里写明是 dependency-light 的纯逻辑端点）。这条改动
要打破那个设计，所以：把 store 作为**可选**依赖注入（`buildTranscribeRoutes(chat, deps?)`），不传时行为与今天
完全一致，纠错端点本身仍然可以脱离记忆库单测。学习失败绝不能让纠错请求失败——包在 try/catch 里，best-effort。

响应加一个 `learned?: { canonicalTerm, alias }` 字段，供 UI 后续显示「已记住」提示（本批先只回传，不做 UI）。

---

## P0-3 交付后 N 秒纠错窗口（就地纠错）

**产品意图**：把 Review 从「全局开关」变成「事后可选」。直接模式照常立刻交付，不增加任何延迟；但刚交付之后的
**8 秒**内，热键的含义会变——如果这时目标应用里**有选中的文字**，按热键 = 「语音纠正这段选中」，而不是开始新录音。

### 为什么是「就地纠错」而不是「把文本塞回浮窗」

第一版方案是：窗口期内按热键 → 打开 Review 面板、预填刚交付的文本。**这个方案是错的**，因为文本已经被粘进
目标应用了；面板提交时再 `insert` 一次会得到两份。要修就得靠 Cmd+Z 撤销自己刚才那次粘贴，而用户在这 8 秒内
只要碰过键盘，撤销的就是别的东西——这是个不能接受的失败模式。

就地纠错没有这个问题，而且更短：用户在目标应用里选中说错的那个词（双击即可），按热键，说「PayPal」。
`ContextBridge.capture()` 已经能读选区，`ContextBridge.insert()` 是 Cmd+V，天然就是「替换选中」。
两个原语都已存在，不需要撤销、不需要浮窗、不需要新的写回路径，而且它对**不是 OpenType 产生的文字**同样有效。

### 判定

- 常量 `correctionWindowSeconds = 8`。理由：够看一眼刚粘进去的文字并反应过来，又短到不会让「想接着说下一句」
  的人被抢走热键。本批唯一一个凭直觉定的数，标注为待调。
- 纯逻辑座 `CorrectionWindow`（可单测）：给定「上次交付时间、现在时间、是否有选中、前台 app 是否还是交付时那个」
  返回 `HotKeyIntent.correctSelection / startNewRecording`。
- `AppModel.hotKeyPressed()` 判定顺序：Review 面板开着 → 面板纠错（不变）；否则窗口热**且有选中**且前台 app 未变
  → 就地纠错；否则 → 新录音（不变）。
- **窗口热但没有选中 → 照常开始新录音。** 不抢热键。想纠错的人会先选中；只想接着说的人不该被打断。

### 就地纠错这一轮做什么

录音只录「修改指令」（ASR only，不过 `VoiceModeRouter`）→ `POST /transcribe/correct`，`fullText` = 选中文字本身、
选区 = 全域（0..len）、`instruction` = 说的话 → 拿到 `replacement` → `ContextBridge.insert(replacement)` 覆盖选区
（同时按既有不变式复制到剪贴板）。审计上追加一条 `.corrected`，`supersedesEventId` 指向本次交付的 `.completed`
事件，复用 Review 已有的链式结构。

### 可见性

交付成功的 toast 在窗口期内保持可见（不是 0.9s 消失），文案是「选中说错的词，再按一次快捷键即可纠正」，
配一个走完就消失的进度条。**用户看不见这个窗口，这个功能就等于不存在**——这是这条的成败点，不是装饰。

窗口立即失效的情形：开始新录音、按 Esc、前台应用改变、自然到期、以及这一轮就地纠错本身完成（改完就结束，
想再改就再选一次——但纠错成功后窗口**重新计时**，因为连改两处是很常见的）。

#### 实现注意：`OverlayHideBehavior` 新增 case 的两个消费点

给 `OverlayHideBehavior` 加 `.scheduleHideWithCorrectionHint(after:)` 时，`OverlayController.swift` 里有两处消费它，
**只有一处会被编译器拦住**：

1. `presentLegacy` 内的穷尽 `switch Self.hideBehavior(for: state)`（约 248 行）——不处理新 case 编译不过，安全。
2. `presentToast` 内的 `guard ... case .scheduleHide(let seconds) = ...`（约 276 行）——这是 `if case` 模式匹配，
   **不处理新 case 编译照样通过**，但行为会静默出错：新 case 不匹配 `.scheduleHide`，于是 guard 直接 return，
   被抢占的统一语音面板**永远不会被恢复**。

第二处今天大概率走不到（`presentToast` 目前只用于失败提示和模式切换提示，`.success`/`.copied` 不走它），
但「今天走不到」不是不处理的理由——这正是那种以后加一个调用点就变成幽灵 bug 的地方。两处都要处理。

只对 `transcribe` + Direct 生效。ask/助理 的卡片已经有「卡片还在就继续会话」的语义（`eaa03f3`），不能抢同一个热键。

**与 P0-2 的连接**：这条路的纠错走同一个 `/transcribe/correct`，因此同样入词典。这才是闭环真正闭上的那一下
——用户在自己的输入框里改一次，下次识别就对了。

---

## P0-4 词典管理 UI

- sidecar：`POST /memory/terms`（新增）、`PUT /memory/terms/:id`（改 canonical/aliases/confidence）、
  `DELETE /memory/terms/:id`。`MemoryStore` 补 `updateEntityTerm` / `deleteEntityTerm`。
- Swift：Settings 的记忆面板从只读列表变成可编辑表格——canonical、aliases（逗号分隔）、置信度、来源标记，
  行内增删改。owner facts 的删除也做进同一个面板（`DELETE /memory/owner-facts/:id` 已经有了，只差 UI）。
- 词条来源要显示（owner / untrusted / agent / system），因为 untrusted 的存在本身就是 P1-12 要让用户看得见的东西。

### origin 的单向提升（本批新增的规则）

`upsertEntityTerm` 今天不合并 origin：合并进一个已有词条时，保留旧的 origin 不动。这在本批之前无所谓，
但现在有两条**用户亲手确认**的写入路径（P0-4 的设置里手动新增、P0-2 的语音纠错），如果它们合并进一个
`remember_fact` 写下的 `untrusted` 词条，那个词条会永远挂着「不可信」标记——而用户刚刚亲自为它背了书。
provenance 标记的全部意义就是让用户去审；审过了还不摘掉，这个标记就变成噪声，用户会学会无视它。

规则：**incoming origin 是 `owner` 时，合并后的 origin 变成 `owner`；否则保持原样。** 即 owner 是单向提升，
永远不会被降级——一个 owner 词条被 `remember_fact` 的 untrusted 路径碰到时，仍然是 owner。
这条逻辑属于 `upsertEntityTerm`（唯一的合并写入路径），不是某个调用方的特例。

---

## P1-5 ask + agent 合并成「助理」

最具侵入性的一条，放在 P0 全部完成、并且真机验证过之后再做。

- `InputMode`：`transcribe` + `assist`，两个 case。
- 助理走**同一条** `runAgentLoop` 与完整工具集（不再有 `filterToolSet` 的 web-only 子集）。
- 交付形态：先内联在卡片里跑；超过 **20 秒**仍未结束则自动「脱手」——卡片提示已转后台，完成时发通知。
  用户不再需要预判这件事要多久。
- 会话：sidecar 的 conversation `kind` 统一成 `assist`；旧的 `ask`/`agent` 数据做一次迁移（不丢历史）。
- UI：Q&A tab 与 Agent tab 合并成一个「助理」tab。
- `VoiceModeRouter`：「agent 模式」这类口令的目标模式随之收敛。

---

## P1-6 下发前确认 + 破坏性命令审批

两件事，一个主题：语音是准确率最低的输入通道，而 Agent 有真的手。

- **下发前确认**：助理任务在真正发出之前，把转写文本显示 ~1.5 秒，期间 Esc 撤销。不是模态确认框——
  默认继续，只给一个反悔的机会，否则高频使用会被拖垮。
- **破坏性命令审批**：接一个真的 `ApprovalPolicy` 实现（seam 已经在 `sidecar/src/agent/approval.ts`）。
  纯函数 `classifyCommandRisk(toolName, args) -> .safe | .destructive`：`rm`、`mv` 覆盖、`>` 重定向、
  `dd`、`mkfs`、`chmod -R`、`git push --force`、`sudo` 等。destructive → 通过已有的 ask_user 通道弹卡片确认。
  YOLO 仍是默认姿态，只有这一类走确认。

---

## P1-7 清理空转记忆层

- **删**：`AgentMemoryStore.entriesForPrompt` / `memoriesForPrompt` / `profileContextForPrompt`、
  整个 `LocalMemoryRetriever.swift`、以及它们的测试。理由：零生产调用，且 sidecar 侧记忆才是这个设计里真正
  被注入的那份；留着两套只会让下一个读代码的人再判断一次。`AgentMemoryStore` 本身保留（任务历史 + 已学到的
  偏好仍在用）。
- **补**：`transcribe` 与助理完成时也写 episodic 事件，consolidation 的原料不再只有 agent 任务。
- **接**：`shouldConsolidate` gate 真正接上——sidecar 启动后延迟一段时间检查一次，满足（≥12h 且 ≥5 条未整理）
  就跑一次。不做定时器轮询。

---

## P1-8 听写「轻整理」档

`TranscribeVariant` 从 `direct | review` 变成 `direct | tidy | review`（仍是交付方式这一根轴，不是新 InputMode）。

`tidy` = 确定性规则，**不调用 LLM**（这一点是产品承诺：轻整理不等于「送给模型改」）：
- 去口癖：中文「嗯、呃、那个、就是说」句首/独立出现时；英文 `um`/`uh`/`er`/`like` 作为独立词时。
- 去紧邻重复词（「我我我想」→「我想」）。
- 标点规整：中英标点混用归一、句末补句号、连续标点收敛。
- 首尾空白、多余空格。

纯模块 `TidyTranscript.swift`，逐规则可测。默认仍是 `direct`——不改现有用户的行为。

---

## P2-10 录音计时 + 最长时长 + 浮层跟随焦点屏

- 浮层显示已录时长；hands-free 连续录音超过 **2 分钟**给一次视觉提醒，**5 分钟**自动停止并正常交付
  （不是丢弃——丢掉用户 5 分钟的口述是不可接受的失败模式）。
- `OverlayController` 的 `visibleFrame()` 从 `NSScreen.main` 改为「鼠标所在屏 → 主屏」兜底。
  Review 面板同理。

## P2-12 本地统计面板

数据源是已有的 `audit-events.v1.jsonl`，不新增采集。指标：本周听写字数、平均端到端耗时、每百字纠错次数
（P0-2/P0-3 之后这个数才有意义，也正好用来验证闭环是不是真的在收敛）。全部本地，不上传。

## P2-13 MCP server 配置 UI

`OPENTYPE_MCP_SERVERS` 环境变量 → 持久化配置（复用 `ProviderConfigStore` 所在目录的同一套写法）+ Settings 管理
界面（增删改、测试连接、列出该 server 暴露的工具）。打包版用户目前根本改不到那个环境变量，Agent 的能力被锁死。

---

## 顺序与依赖

```
P0-1 ──┐
P0-2 ──┼─→ P0-3（依赖 P0-2 的入典逻辑）
P0-4 ──┘
        └─→ 真机验证闭环 ──→ P1-5 ──→ P1-6
                              P1-7、P1-8 可与 P1-5 并行（不冲突）
                              P2-10、P2-12、P2-13 收尾
```
