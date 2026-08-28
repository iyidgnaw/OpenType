# 2026-08-28 · Skill/Agent 管理界面 + 步骤日志持久化 + 小改批

来源：Claude Design 项目「OpenType 重设计」（id `83288c5b-eb34-4d46-abd1-ff263dedb1f0`，主文件 `OpenType 重设计.dc.html`）。
2026-08-28 逐屏核对结论：设计稿 01–07 区（会话/窄布局/听写记忆设置/悬浮层/菜单栏/统计/MCP）当前代码已基本实现；本批施工只剩四块，即本文档的 Pipeline A–D。分支 `feat/skill-agent-ui`，按 CLAUDE.md 的 4-stage TDD 流水线执行，每批绿了即 commit 并 merge 到 main。

## 0. 已拍板决策（owner 确认，2026-08-28）

| # | 决策 |
|---|------|
| B1 | **不做 mid-run agent 派发**。agent 定义的选择只发生在 run 开始（语音前缀 / `agentName` 字段），维持现状。 |
| B2 | **Agent 编辑器不做模型下拉**。`model` frontmatter 继续 parse-but-ignore；文件里已有的值在编辑器里只读展示；API 的 POST/PUT 不接受 `model` 字段。 |
| B3 | **进度条保持 indeterminate**。sidecar 不报步数总量，不做「第 N / ~M 步」估计。 |
| C3 | menubar popover 顶栏按钮**保持开主窗口**，不改成设置齿轮。 |
| C5 | 结果卡的内容感知建议 chip（如「再导一份 A4 的」）**后置不做**，保留现有固定对 + 文件动作。 |
| D0 | 步骤日志持久化**不写迁移**：引入 conversations 作用域的 schema 版本号，mismatch 时 drop 并重建 `conversations` + `conversation_messages` 两张表（且仅这两张），老会话数据删干净——owner 明确授权。 |
| E1 | Skill/Agent 编辑器里**名称在编辑态只读**，只有新建时可输入（避免 rename 语义）。 |
| E2 | 「复制到我的 Skill 再改」预填原名，保存时靠「与内置同名 409」拦截强制换名（内联错误提示）。 |
| E3 | 与 `~/.claude` 同名**不拦**（user root 在 claude root 之前，用户副本本来就生效）；只拦与内置同名。 |
| E4 | D2 文案删除无行为可测，**豁免 4-stage**，走 implement + review 两段。 |
| E5 | 所有 UI 遵守 owner 文案规则（见 §5）：不要描述性文案。 |

后续拍板追加在此表（owner 授权主 agent 直接拍板并记录）。

## 1. Pipeline A · sidecar：skills / agent-definitions 的 HTTP API 面

现状：skills 无任何 HTTP 端点（只有运行时 `opentype__load_skill` 工具）；agents 只有只读 `GET /agent/definitions`（刻意不返回 body/displayName/model）。发现层 `sidecar/src/resources/resourceStore.ts` 对后到同名项静默丢弃（:152），TTL 5s 缓存（server.ts:308/:333）。

### 1.1 resourceStore 扩展

- 新增 `listAll()`：返回**每个**发现项，含 `active: boolean`（first-root-wins 的胜者为 true）与 `shadowedBy`（被谁覆盖：胜者的 root 标识；active 项为 null/缺省）。与 `list()` 共用同一次扫描与 TTL 缓存。`list()` 语义不变（仅 active）。
- 新增写后失效：`invalidate()`（清缓存），所有写端点成功后调用，保证写完即读到新状态（不等 TTL）。

### 1.2 Skills 端点（新文件 `sidecar/src/skills/skillRoutes.ts`，wire 进 buildApp，依赖注入 store 便于测试）

- `GET /skills` → `{ skills: [{ name, description, root, path, editable, active, shadowedBy }] }`。含 shadowed 项。`editable` 仅 user root（`~/.opentype/skills`）为 true。root 标识沿用现有 roots 命名。
- `GET /skills/:name` → `{ name, description, body, path, root, editable }`。默认返回 active 那份；`?root=<id>` 定位具体一份（8A 里被覆盖的「我的」条目也要能点开看）。404 不存在。
- `POST /skills` body `{ name, description, body }` → 创建 `~/.opentype/skills/<name>/SKILL.md`。
- `PUT /skills/:name` body `{ description, body }` → 仅 user root；404 无此 user skill。名称不可改（E1）。
- `DELETE /skills/:name` → 仅 user root，删除整个 skill 目录；builtin/claude → 403。

### 1.3 Agent-definitions 端点（扩展现有 routes 或新文件，同样依赖注入）

- `GET /agent/definitions`（现有）→ 每行扩展 `displayName`、`model`、`path`、`active`、`shadowedBy`；列表**继续不含 body**。
- `GET /agent/definitions/:name` → 完整记录含 `body`、`editable`（`?root=` 同上）。
- `POST /agent/definitions` body `{ name, displayName?, description, tools?, body }` → 写 `~/.opentype/agents/<name>.md`（tools 为数组或省略；省略=不写 tools 行=继承全部）。**不接受 `model`**（B2）。
- `PUT /agent/definitions/:name` → 仅 user root。**必须保留未管理的 frontmatter 键**（例如文件里已有 `model:` 行，round-trip 后原样保留）。
- `DELETE /agent/definitions/:name` → 仅 user root。

### 1.4 校验（POST/PUT 共用；校验失败用仓库统一 error envelope，400/403/404/409 语义准确）

- 名称字符集：`^[A-Za-z0-9][A-Za-z0-9-]*$`（字母、数字、`-`；不以 `-` 开头；天然排除路径穿越）。长度上限 64。
- 与**内置**同名 → 409（skills 和 agents 都要有该机制；内置 agents 目前为空但机制要在）。
- 与 user root 已有同名 → POST 409（更新走 PUT）。
- agents 文件名 `readme`（大小写不敏感）→ 400（发现层会跳过它，起名时就拦）。
- description 折叠为单行（frontmatter 是扁平 key: value；写出格式与 `sidecar/src/resources/frontmatter.ts` 的解析器互相兼容，写完必须能被自己的发现层读回）。
- 写路径 resolve 后必须落在对应 user root 内（防御性断言）。

### 1.5 验收

- bun test：listAll shadowed 上报；全部端点 CRUD + 校验矩阵（charset/内置同名/user 同名/readme/非 user root 写 403/404）；写后立即可读（invalidate）；PUT 保留 model 行；POST 写出的文件能被发现层解析回同样的 name/description/tools。
- 测试用 temp 目录做三根，不碰真实 `~/.opentype`。

## 2. Pipeline B · 步骤日志持久化（设计 01「永远可回溯」）

现状：`conversation_messages` 只有 `id, conversationId, role, content, createdAt`（db.ts:113-119），steps 不落库，历史线程无日志（SessionsViews.swift:500-506 明确注释）。

- **Schema**：`conversation_messages` 加 `steps TEXT NULL`（JSON 数组，形状与 `/agent/run` 响应里的 steps 完全一致，Swift 侧可复用现有解码模型）。按 D0：conversations 作用域版本号，mismatch 时 drop 重建 `conversations` + `conversation_messages`，仅此两张。
- **写入**：agent run 落 assistant message 时带上该 run 的 steps；ask run 若产生 steps（web 工具）同样存。user message 的 steps 为 null。
- **读出**：`GET /conversations/:id` 的 messages 带 `steps`（无则缺省/null）。
- **Swift**：ConversationMessage 解码 steps；`SessionsViews` 的 StepLog 渲染历史线程的持久化 steps（活跃 run 仍以内存态优先，二者衔接不重复渲染）。SessionsViews.swift:500-506 的「不持久化」注释一并更正。
- 验收：bun test 覆盖 schema 重建（旧库文件存在 → 打开后两张表重建、其他表数据保留）、steps round-trip；swift test 覆盖解码与 anchor 选择逻辑；历史会话（重启后）线程能显示折叠步骤块。

## 3. Pipeline C · Swift「Skill 与 Agent」设置二级页（设计 08 区）

新 `SettingsRoute` case（标题「Skill 与 Agent」，入口放设置·引擎组，Agent 工具行下方）。新文件 `SkillAgentViews.swift`；`SidecarClient` + `AppModel` 加对应端点方法。全部用 `DS.*` token。**页面上不放任何描述性文案（§5）**。

- **8A 总览**：宽布局左右两栏。左 SKILL：头行「SKILL · N」+「新建 Skill」；卡内分组 header 内置 · N / 我的 · N / Claude Code · N（Claude Code 组 header 右侧「只读」小字），行 = mono 名 + 描述单行截断 + chevron（user）/lock（claude/builtin 查看）；被覆盖的「我的」行：名字灰化 + 橙色徽标「被内置同名覆盖」；列表下方「在访达中打开」动作（NSWorkspace 打开 `~/.opentype/skills`，目录不存在先建）。右 AGENT 同构（行 meta 一行 mono：`工具 …` + 文件有 model 时 `模型 <值>`；「新建 Agent」）。窄布局纵向堆叠。
- **8B Skill 编辑器**（sheet ~620pt）：名称（新建可编辑/编辑只读，E1）、描述（多行输入）、正文（编写/预览切换，预览用现有 Markdown 渲染视图）、底部 mono 路径 + 取消/保存。保存调 POST/PUT；409/400 内联错误展示（这是状态反馈，允许出现）。
- **8C 只读查看**（builtin 与 claude root 共用，~560pt）：mono 名 + 来源徽标、描述、渲染后的正文（可滚动）、底部「复制到我的 Skill 再改」（仅 builtin；预填进 8B 新建，E2）。
- **8D Agent 编辑器**（~560pt）：名称/显示名（可选）/描述、工具 chips 多选（清单 = D1 补全后的完整内置工具目录；空选 = 继承全部；有副作用工具带现有橙色标记）、系统提示（编写/预览）、无模型下拉（B2；文件已有 model 值时只读 mono 展示）、底部路径 + 保存。
- 生效即时（sidecar TTL 5s + 写后 invalidate），页面不放解释文案。
- 验收：swift test 覆盖可测纯逻辑（route case、列表分组/徽标推导、编辑器表单状态、名称校验镜像）；`swift build` 通过；视图接线人工走查由 stage 4 审查员对照本节逐项确认。

## 4. Pipeline D · 小改批

- **D1 内置工具目录补全**（`McpServerViews.swift` 的 `McpBuiltInCatalog`）：本机 = bash, python, open_file, read_file, list_dir, grep, write_file, edit_file, move_file, trash, glob（11）；网络与记忆 = web_search, web_fetch, remember_fact, consolidate_memory_now, read_history（5）。副作用标记在现有 4 个之上加 write_file / edit_file / move_file / trash。计数标签由 catalog 数量派生（16），不硬编码。摘要文案与 `sidecar/src/agent/coreTools.ts`、`docs/tool-catalog.md` 对齐。测试：catalog 名单与期望集合一致。
- **D2 描述性文案删除**（E4：implement+review 两段）：按 §5 标准删除 Swift 侧同类文案，中英双语一起删。已知清单：DictationViews 统计免责声明（:593-603 一带）与解释性副标签（**保留数据性 note**，如分模式时延数值）；SettingsViews2 各行解释性副说明（启动方式提示、「结果始终会复制到剪贴板」、提示音解释尾巴、实时字幕权限解释、本地长期记忆解释、「三档都不经过 AI 模型…」）；McpServerViews 的 riskCard、「始终可用,不可关闭」、名称前缀提示、遮盖值提示、「连接在…建立」类说明。删后 `swift build` + 全量 `swift test` 通过。
- **D3 窄轨底部按钮**：图标换 mic（`SidebarModeButton`），菜单行为不变。

## 5. Owner 文案规则（适用于设计稿与代码，2026-08-28 起）

**删**：画面内、与状态无关的机制说明文（教用户系统怎么工作的：文件格式、存储路径、发现顺序、索引机制、行为原理）。
**留**：状态反馈（计数、当前值、错误、「被内置同名覆盖」徽标）、快捷键提示（「松开结束」「Tab 切换」）、破坏性/风险动作在弹窗里的后果说明（「仍要保存会以停用状态存下」）、表单校验错误。
设计稿已于 2026-08-28 按此规则清理并写回 Claude Design 项目。

## 6. 完成定义

四条流水线全绿、逐批 commit 并 merge 到 main；CLAUDE.md 增补新端点与新设置页的描述、SessionsViews 过期注释更正；本文档决策表补全。

## 7. 决策日志（施工中追加）

- **A-1**（2026-08-29）：agent-definitions 五个端点放**新文件** `sidecar/src/agent/agentDefinitionRoutes.ts`，不在 `routes.ts` 原地改（避免动 `AgentDefinitionsSource` 破坏既有测试的 fake）。server.ts 路由表把新文件注册在 `buildAgentRoutes` **之前**（router 首个匹配生效），旧的 `GET /agent/definitions` handler 保留但被遮蔽，server.ts 加注释说明是刻意遮蔽、后续可清理。
- **A-2**：API 的 `root` 字段沿用现状 = **字面文件系统根路径**（`ResourceEntry.root`），不发明符号 id。Swift 侧分组规则：路径前缀 `~/.opentype` → 「我的」，`~/.claude` → 「Claude Code」，其余 → 「内置」。
- **A-3**：B2 只测承载性不变量（POST 的 model 永不落入文件），不锁具体状态码。
- **A-4**：名称在任何根都不存在时 DELETE/PUT 返回 **404**；仅存在于 builtin/claude 时返回 403。
- **A-5**：创建成功返回 **200**（本仓库 route 惯例，不用 201）。
- **D-1**（2026-08-28）：D2 文案删除与 D3 窄轨图标并入 D1 的流水线一次实现、一次审查（E4 豁免测试部分）。
- **B-1**（2026-08-29）：steps 的持久化类型放 **memory 层自己的宽结构类型**（`{type: string; detail: string}`），不 import agent/loop 的 `AgentProgressEvent`——存储层不该向上依赖 agent 模块（分层 + 潜在环），联合类型约束属于生产方；窄类型天然可赋值给宽类型，测试文件的 TS2345 摩擦随之消失。
- **B-4**（2026-08-29）：Bw4 复审四项处置——(1) anchorIndex 逐消息重算改为渲染路径一次预计算，经「已测 4 参函数委托新的 5 参重载」实现，钉死的测试不动；(2) 历史步骤块 `initiallyExpanded: false`，仅当前活跃 run 的锚点展开（对应 spec「历史线程显示**折叠**步骤块」）；(3) `stepLogAnchor` 接回渲染路径作为唯一命名接缝；(4) 历史日志**不显示耗时**——duration 未持久化，补列超出本批范围（未来可作为 steps 之外的附加列，暂不做）。
- **C-1**（2026-08-29）：C4 两缺陷成立并修复——(1) 编辑器 footer 删除必须走 confirmationDialog（对齐 McpServerSheet；sidecar 端是 rm -rf 非废纸篓）；(2) `AgentEditorFormState.savePayload` 在 **edit 态**必须把 displayName/tools 以「present-but-empty」发送（PUT 省略键=保留旧值，清空动作否则静默丢失），create 态保持省略=继承全部。附带：弹窗宽度按设计意图改 620/560（高度不变）；三处外观小修（按钮阴影、L10n 包裹、分段控件 2pt）。
- **B-3**（2026-08-29）：agentRunStepsPersistence.test.ts 残留 3 个 TS2769（测试自己把响应 cast 成 `unknown[]`/缺 detail 的 fixture 与 toEqual 泛型绑定冲突）**容忍不修**：bun 才是本仓库的门槛（1348/0），tsc 非门控且带 68 个既有基线错误，该文件错误数已从基线 8 降到 3。收尾批可顺手做纯类型标注清理，不单独开轮次。
- **B-2**（2026-08-29）：`test/memory/db.test.ts` 钉死 conversation_messages 旧列清单的断言因 owner 批准的 D0 schema 变更而陈旧，授权实现方做**最小更新**（期望列表加 `"steps"`）——与 D2 的「删除文案导致的既有断言更新」同一先例，属更正非削弱。
- **A-7**（2026-08-29）：A4 审查发现并以 PoC 证实 frontmatter 键注入——`displayName`/`tools` 只 trim 未折叠单行，嵌入 `\n` 可在写出的 .md 里伪造任意键（含 `model:`，违反 B2；tools 省略时还可经 displayName 私设工具白名单）。修复：两字段与 `description` 走同一单行折叠后才进 `renderFrontmatter`；补 stage-1 回归测试；DELETE 两处补 `assertWithinRoot`（防御性一致，当前按构造安全）。
- **A-6**（2026-08-29）：A3 实现期发现 stage-1 测试笔误（agentDefinitionRoutes.test.ts B2 PUT 测试：请求 `body: "new"` 但断言 `toContain("new body")`，任何正确实现都无法通过）。主 agent 裁决按测试自述意图修请求为 `body: "new body"`（增强而非削弱：保持「PUT 确实写入了 body」的非空洞断言）。实现方未动测试，符合规则。
- **D-3**（2026-08-29）：D4 审查通过后随批记录——DictationViews 的「纠错一次就会记住」空态提示**保留**（仅词典为空时出现=状态门控）；McpBuiltInCatalog 注释漏提 builtInTools.ts 来源、`docs/tool-catalog.md` 仍写 10 个工具，两处并入收尾文档批修正。
- **D-2**（2026-08-29）边界文案裁决：**删** 语音模型 titleHint（「更大的模型更准…」）与 界面语言 titleHint（系统对话框跟随系统语言）——与 8B 表单提示同类的静态机制说明；**留** 麦克风/辅助功能的 deniedNote（仅拒绝状态出现=状态反馈）、更新按钮的幂等提示（动作后果）、「Agent 工具」行副标题「内置工具与 MCP 服务器」（内容标签）、tooltip 类（按需出现，不算画面内常驻文案）。
