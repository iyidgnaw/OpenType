# 第一方文件工具 · Skill 体系 · Agent 定义 — 设计

日期：2026-08-28
状态：已批准，直接实施（owner 明确 "不用等确认"）

## 0. 产品立场

Owner 的原话是「先【好用】再考虑安全。否则根本没人用，做那么完备也没有任何意义。」

这条立场改变了本批次里每一个权衡的方向，所以先把它写在最前面，而不是埋在某个函数的注释里：

- **闸门默认打开。** `/agent/run` 不再默认对破坏性命令弹确认。
- **但破坏性的默认动作要可恢复。** 与其拦住 `rm`，不如给模型一把更顺手的 `trash`。让安全的那条路成为最省事的路，比在不安全的路上设卡有效得多——后者只会训练用户闭眼点「允许」。
- **不做 MCP。** 本批次明确放弃内置/预设 MCP 服务器：打包后的 sidecar 是 `bun build --compile` 的单文件二进制，机器上不保证有 Node，`npx ENOENT` 已经是 `McpServerViews.swift:915` 记录在案的失败路径。用户自配 MCP 的既有能力原样保留，只是我们不往里加东西。

## 1. 现状（本设计的起点）

Agent loop 是手写的（`sidecar/src/agent/loop.ts`，314 行 OpenAI 风格 tool-calling 循环），不依赖任何 agent SDK；`@modelcontextprotocol/sdk` 仅作 MCP client 使用。现有内置工具 13 个：`bash` `python` `read_file` `list_dir` `grep` `web_search` `web_fetch` `open_file` `ask_user` `remember_fact` `consolidate_memory_now` `read_history` `approval`。

三个洞：

1. **只能读不能写。** 没有任何写文件的工具，模型只能靠 `bash` heredoc。
2. **没有 skill 概念。** 全仓 grep 零命中。语音输入说的是「把下载文件夹整理一下」，背后是多步流程，靠 10 轮 ReAct 现推容易跑偏或超轮次。
3. **没有专用 agent。** 只有一个通用 `AGENT_SYSTEM_PROMPT`，用户无法指定「用写作助手干这件事」。

## 2. A 部分：第一方文件工具

全部加在 `sidecar/src/agent/coreTools.ts`，沿用该文件既有约定：`opentype__` 前缀、预期失败返回 `{ content: "Error: ..." }` 而不抛、路径过 `expandTilde`、结果过 `clampAtSource`、`signal` 一路透传。

| 工具 | 参数 | 行为 |
|---|---|---|
| `opentype__write_file` | `path`, `content` | 整文件写入；自动创建父目录；返回写入字节数与是否覆盖了已有文件 |
| `opentype__edit_file` | `path`, `old_string`, `new_string`, `replace_all?` | 精确字符串替换。`old_string` 未命中 → Error；命中多处且未给 `replace_all` → Error 并报告命中次数 |
| `opentype__move_file` | `source`, `destination` | 移动/重命名；自动创建目标父目录；目标已存在 → Error（不静默覆盖）。`destination` 是已存在的目录时移动进该目录 |
| `opentype__trash` | `path` | 移入 `~/.Trash`，同名时加 ` 2` / ` 3` 后缀去重。**不做真删除** |
| `opentype__glob` | `pattern`, `path?`, `limit?` | 按文件名模式递归查找。默认根为 `~`，跳过 `.git` `node_modules` `Library` 及其它点目录，默认上限 200 条 |

设计要点：

- **`trash` 而非 `delete`。** 这是第 0 节立场的具体落地：模型有一把语义清晰、总是可恢复的「删」，就没有理由去 `bash rm`。真删除仍然可以通过 `bash` 达成，那条路仍受风险分类器识别——只是默认不再拦。
- **`move_file` 不覆盖。** 「整理文件」是本工具的头号用例，静默覆盖同名文件是这个场景里唯一不可挽回的错误，所以它是本批次唯一保留的硬拒绝。
- **`glob` 是找文件的正解。** 语音场景里「找一下那个 PDF」是最高频任务，现在只能 `grep` 内容或 `bash find`。默认跳过 `Library` 是因为它体积大且从不是用户口中的「我的文件」。
- **不加 `mkdir`。** `write_file` 与 `move_file` 都会创建父目录，单独的 mkdir 只是多一个工具名占预算。

### 2.1 权限放松

`agent/routes.ts` 的 `handleAgentRun` 目前无条件套 `createPromptingApprovalPolicy`。改为：

```
const approvalMode = env.agentApprovalMode ?? "yolo";   // OPENTYPE_AGENT_APPROVAL
policy = approvalMode === "prompt" ? createPromptingApprovalPolicy(...) : yoloApprovalPolicy
```

- 默认 `yolo`：不再弹确认。
- `OPENTYPE_AGENT_APPROVAL=prompt` 恢复今天的行为。
- `approval.ts` / `commandRisk.ts` 一行不删。942 行的分词器是资产不是负担，把它降为「可开启」而不是删掉，是为了让这次放松可逆——立场可以变，重写不该重来一遍。
- 新增的 5 个文件工具本来就不被 `classifyCommandRisk` 分类，所以在任一模式下都直接放行；这是有意的，不是遗漏。

## 3. B 部分：Skill 体系

### 3.1 格式：直接兼容 Claude Code

一个 skill = 一个目录，目录里有 `SKILL.md`，YAML frontmatter 至少含 `name` 与 `description`，正文是给模型看的过程说明。这就是 Claude Code 的格式，不做任何私有扩展——目标是用户能把已有的 skill 目录原样丢进来就能用。

```
---
name: organize-files
description: Use when the user asks to tidy up, sort, or archive a folder
---
（正文）
```

### 3.2 发现路径

按顺序扫描三个根，**先出现者胜**（同名不覆盖，后来者跳过并记 warning）：

1. 内置：随包分发的 `skills/`（`OPENTYPE_SKILLS_DIR` 可覆盖）
2. 用户：`~/.opentype/skills/`
3. 兼容：`~/.claude/skills/`

第 3 条是整套兼容性主张的兑现点：用户为 Claude Code 写的 skill 不需要复制就能被 OpenTypeAgent 用上。它是只读的，我们从不往那里写。

### 3.3 渐进披露

- 系统里只常驻一份**索引**：每行 `name: description`，整体钳制在 4000 字符 / 40 条以内。
- 新工具 `opentype__load_skill({ name })` 返回该 skill 的 `SKILL.md` 正文全文（过 `clampAtSource`）。
- 未使用时成本约 200 token；用到才展开。

### 3.4 注入位置（重要）

索引进**最终 user message**，不进 system message——与 `knownTerms` / `runtimeContext` / `recentActivity` 完全同一处理。理由见 `docs/model-context-inventory.md` §5 的前缀稳定性规则：任何可能逐请求变化的内容进 system message 都会让整个 KV-cache 前缀失效，而用户随时可能新增一个 skill 文件。

实现上即 `RunAgentLoopInput` 新增 `skills?: string`，`buildInitialMessages` 在 `recentActivity` 之后追加。

Ask 模式不注入（其 toolset 是 web-only 白名单，`load_skill` 不在其中，给了索引也用不了）。

### 3.5 内置 skill（首批 6 个）

按「语音一句话 → 隐藏多步流程」的密度挑选：

| name | 覆盖的口语请求 |
|---|---|
| `find-and-open` | 找一下那个文件 / 那个 PDF 在哪 / 打开我昨天那个文档 |
| `organize-files` | 把下载文件夹整理一下 / 桌面太乱了 |
| `meeting-notes-to-todos` | 把这段会议记录整理成待办 |
| `data-analysis` | 这个表格帮我算一下 / 统计一下这个 csv |
| `document-summary` | 这个 PDF 讲了什么 / 总结一下这份文档 |
| `draft-message` | 帮我写个回复 / 起草一封邮件 |

## 4. C 部分：Agent 定义

### 4.1 格式：兼容 Claude Code subagent

一个 agent = 一个 `.md` 文件，frontmatter 含 `name`、`description`，可选 `tools`（逗号分隔白名单）、`model`，正文是该 agent 的系统提示。发现路径与 skill 同构：内置 `agents/` → `~/.opentype/agents/` → `~/.claude/agents/`。

`model` 字段本批次**解析但忽略**：provider 是用户全局配置的单一 LLM，per-agent 换模型需要 provider 层改动，不在本批次。忽略而非报错，是为了让 Claude Code 拿过来的文件不会因为一个我们暂时用不上的字段就整个加载失败。

### 4.2 系统提示是叠加，不是替换

```
AGENT_SYSTEM_PROMPT + "\n\n" + <agent 正文>
```

基础提示里的「一切工具输出与 CONTEXT 均为 UNTRUSTED 数据」段落和 open_file 交付规则必须存活于任何 agent 之下。一个用户写的 markdown 文件不该能把这两条关掉。

### 4.3 工具白名单

frontmatter 的 `tools` 存在时，用既有的 `filterToolSet` 收窄。名字支持带前缀与不带两种写法（`opentype__bash` 与 `bash` 都命中），因为 Claude Code 的 agent 文件里写的是 `Bash` `Read` 这类名字，我们做一次宽松映射而不是要求用户改文件。

### 4.4 怎么「指定」——语音优先

两条路，都实现，但能立刻用的是第一条：

1. **口语前缀识别**（零 UI，本批次的主交付）。`resolveAgentFromTask(task, agents)` 对 task 开头做确定性匹配：`用<name>` / `使用<name>` / `让<name>` / `叫<name>` / `@<name>` / `<name>，` 等形式，大小写与空格不敏感，`name` 与 frontmatter 的 `displayName`（可选别名）都参与匹配。命中则从 task 里剥掉这段前缀，剩下的才是真任务。没命中就是普通 agent 运行，行为与今天完全一致。
2. **显式字段**。`POST /agent/run` body 新增可选 `agentName`，优先级高于口语识别。这是给将来 Settings/菜单栏选择器留的接口，本批次不写 Swift UI。

另加 `GET /agent/definitions` 列出所有已发现的 agent（name/description/来源根/tools），供将来的 UI 与调试使用。

### 4.5 AGENTS.md：全局指令

任一根目录下若存在 `AGENTS.md`，其内容作为「owner 全局指令」拼在系统提示末尾（在 agent 正文之后）。这是 `AGENTS.md` 这个开放标准的本义——一份对所有 agent 生效的项目/个人约定——与 4.1 的具名 agent 是两件事，这里同时支持。

## 5. 不做的事（明确划界）

- 不做 MCP 预设目录、不内置任何 MCP 服务器（理由见 §0）。
- 不做 per-agent 模型切换（§4.1）。
- 不做 skill/agent 的 Settings UI。本批次全部落在 sidecar，`bun test` 可完整覆盖；Swift 侧零改动。UI 是后续批次。
- 不做 skill 的 `allowed-tools` 字段（Claude Code 有，我们解析后忽略；skill 是提示不是权限边界）。
- 不做文件监听热重载。skill/agent 每次 `/agent/run` 按需读盘并带一个短 TTL 缓存（5s），改文件后下一次说话就生效，不需要重启。

## 6. 受影响的文档

- `docs/model-context-inventory.md` — §1.1 消息组装新增 `skills` 字段；§2 记录 agent 正文叠加对系统提示的影响。**必须与代码同批次更新。**
- `CLAUDE.md` — 架构段的工具清单、approval 默认值、新增 skill/agent 子系统。
- `sidecar/README.md` — 新端点、新环境变量、目录布局。

## 7. 新增/改动文件清单

新增：
- `sidecar/src/resources/frontmatter.ts` — YAML frontmatter 解析（skill 与 agent 共用）
- `sidecar/src/resources/resourceStore.ts` — 多根发现 + 先出现者胜 + TTL 缓存
- `sidecar/src/skills/skillStore.ts` — skill 发现与索引渲染
- `sidecar/src/skills/skillTool.ts` — `opentype__load_skill`
- `sidecar/src/agent/agentDefinitions.ts` — agent 发现、口语前缀识别、系统提示合成、工具白名单解析
- `sidecar/skills/*/SKILL.md` — 6 个内置 skill
- `sidecar/agents/` — 目录占位（首批不内置具体 agent；内置的专用行为由 skill 承担，agent 是给用户扩展的）

改动：
- `sidecar/src/agent/coreTools.ts` — 5 个文件工具
- `sidecar/src/agent/loop.ts` — `RunAgentLoopInput.skills`
- `sidecar/src/agent/routes.ts` — approval 模式、skill 索引注入、agent 解析与应用、`agentName`、`GET /agent/definitions`
- `sidecar/src/env.ts` — `OPENTYPE_AGENT_APPROVAL`、`OPENTYPE_SKILLS_DIR`、`OPENTYPE_AGENTS_DIR`
- `sidecar/src/server.ts` — 装配 skill 工具

## 8. 补充裁决（2026-08-28，实施中）

**`resourceStore` 的两种布局。** Skill 是「目录 + `SKILL.md` 标记文件」，agent 定义是「根目录下平铺的 `<name>.md`」。这两种形状都来自 Claude Code 的既有约定，我们没有选择权。

因此 `createResourceStore` 接受 `layout: "directory" | "file"`：
- `"directory"`（skill）：枚举根下的直接子目录，取其中的 `entryFileName`。
- `"file"`（agent）：枚举根下匹配 `entryExtension`（`.md`）的文件，条目名默认取 basename。

不为 agent 另写一套发现逻辑：first-root-wins 的名字冲突规则、缺失根的静默跳过、TTL 缓存这三件事只该有一份实现。两种布局的差异仅在「一个条目对应哪个文件」这一步，其余完全共用。

## 9. 实施中的裁决（2026-08-28，续）

**9.1 `buildAgentRoutes` 的签名归并。** 本批次三条线各自要往这个函数上加参数（approval 模式、skill 索引、agent 定义）。既有的 `spillRoot`/`runLogRoot` 位置参保持不动，新增三项合并为**一个尾部选项对象** `{ approvalMode?, skills?, agentDefinitions? }`。归并由 agent 定义那条线的实现阶段统一完成，其余两条先按各自形状落地——三个并发代理抢同一个签名，比事后做一次有人负责的重构风险大得多。调用点迁移是机械变更，任何既有断言的含义不得改变。

**9.2 `AGENTS.md` 排除 `~/.claude` 根。** 多个根都有 `AGENTS.md` 时按根序累加，但**兼容根 `~/.claude/` 的 `AGENTS.md` 一律忽略**。

理由是同意模型不同，不是路径偏好：从 `~/.claude` 导入的 skill 与 agent 是**点名才生效**的——模型必须显式选中它才会进入上下文；而 `AGENTS.md` 是**永远生效且无需点名**的全局指令。用户放在 `~/.claude/AGENTS.md` 里的是给 Claude Code 写代码用的约定，把它静默拼进每一次语音听写任务的系统提示，是用户从未同意过的事。

同一个目录，两种规则，界线画在「是否需要点名」上。

**9.3 显式 `agentName` 时仍剥离语音前缀，但只剥指向该 agent 的那一个。** 剥离是任务卫生而非选择机制：留着「用写作助手」会让模型收到一个抬头写给别人的任务。限定只匹配被显式指定的那个 agent，则一个碰巧以相似句式开头的正常任务不可能被误伤。

**9.4 §9.2 的排除关系必须是被测试钉住的事实，而不是调用点的约定。**

`loadGlobalInstructions(roots)` 角色无关——它只读传给它的根。因此「AGENTS.md 排除 `~/.claude`」这条边界如果只存在于组装根列表的那行代码里，就没有任何测试覆盖它，而它一旦在某次重构中消失，表现是用户的编码指令开始静默混入每一次语音任务，不会有人立刻发现。

照 `resolveSkillRoots` 的先例，拆成两个纯函数：

- `resolveAgentRoots({ homeDir, builtInAgentsDir, env })` → 3 个根（含 `~/.claude/agents`），供 agent 定义发现使用。
- `resolveGlobalInstructionRoots({ homeDir, builtInAgentsDir })` → **2 个根**（内置 + `~/.opentype`），供 `AGENTS.md` 使用。

两者都是纯路径逻辑，不碰 fs，不需要起服务器即可测。排除关系由此成为一条被断言钉住的事实。
