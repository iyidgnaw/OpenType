# OpenType

**中文** · [English](README.en.md)

OpenType 是一个本地优先的 macOS AI 语音输入工具，把自然口语变成可以直接使用的文字。按住一个快捷键说话，松开后直接转成文字、回答你的问题，或者把一个任务交给 Agent 去做。

> 曾经有 iOS 与 Android 两端，原计划三端共享同一套模式/Prompt 安全规则/Provider 语义/审计协议。macOS 端经历了一次从零重写后，两端已被整体移除（产品决定，不是遗漏）——本仓库现在只有 macOS 一个平台。

完整使用情景、操作方式和功能边界见 [OpenType 使用说明书](USER_GUIDE.md)。

## 安装

从 [Releases](https://github.com/iyidgnaw/OpenType/releases/latest) 下载 `OpenType-<版本>-macos-arm64.zip`（约 24 MB），解压后在该目录里运行：

```bash
./install.sh
```

它会把 app 装进 `/Applications`、用 Homebrew 装好 `python@3.12` 和 `ffmpeg`、在 app 内部搭建本地语音识别环境，然后重新签名。可以反复运行，重跑时会保留已经建好的语音环境而不是重建。加 `--skip-whisper` 可以跳过本地识别（改在应用内配置远程识别服务）。

**不想自己盯着这套流程**，可以把 [`docs/onboarding/coding-agent-setup-prompt.md`](docs/onboarding/coding-agent-setup-prompt.md) 里的 prompt 交给 Claude Code / Codex 等，让它把下载、安装、两项 macOS 权限授予和应用内设置向导全程带你走一遍——那份 prompt 覆盖了脚本做不了的部分，也包括安装前该先问你的两个选择（语音识别用本地还是远程、用哪家 LLM）。

> 发布包是 ad-hoc 签名、**未经过 Apple 公证**的。`install.sh` 会替你清掉下载隔离标记，所以正常流程不会看到 Gatekeeper 警告；但这也意味着你是在信任这个仓库的作者，介意的话请自行从源码构建。

### 环境要求

- **Apple Silicon Mac**：本地语音识别基于 Apple 的 MLX，没有 Intel 版本，这条没有变通办法。
- **macOS 13 (Ventura) 或更新**。
- **[Homebrew](https://brew.sh)**（本地识别需要，用来装 Python 和 ffmpeg；纯远程识别可以不装）。
- **磁盘**：app 本体约 74 MB，本地语音环境约 1.1 GB（大头是 mlx-whisper 的依赖树，mlx-whisper 本身还不到 2 MB），首次转写另需在 `~/.cache/huggingface` 下载约 460 MB 的模型——这是一次性开销，不是卡死。
- **LLM API Key 只有「问答」和「Agent」模式需要**；纯听写不需要任何 Key、不需要联网。

### 从源码构建（开发者）

```bash
git clone https://github.com/iyidgnaw/OpenType.git
cd OpenType
./scripts/setup.sh
```

[`scripts/setup.sh`](scripts/setup.sh) 是幂等的：检查环境 → 用 Homebrew 装好 `bun` / `python@3.12` / `ffmpeg` → 搭建本地 Whisper venv → 编译出 `dist/OpenType.app`。除上面的环境要求外还需要 **Xcode 命令行工具**（`xcode-select --install`），完整 checkout 加编译产物约占 3.4 GB。

| 参数 | 作用 |
|---|---|
| `--skip-whisper` | 跳过本地 Whisper 环境 |
| `--no-build` | 只装依赖，不编译 |
| `--check` | 只检查并报告，不做任何改动 |

打发布包用 [`scripts/build-release.sh`](scripts/build-release.sh)。它会构建 app、**剥掉本地 Whisper venv**（venv 会把创建它的解释器绝对路径写死，换台机器就跑不起来，所以只能由 `install.sh` 在目标机器上现建）、重新签名并打成 zip。

## 当前交付状态

经历过一次从零重写（旧的 5/6 模式系统已删除，改为下方的 3 模式设计），通过 `./scripts/build-app.sh` 构建为 `dist/OpenType.app`，通过 `./scripts/build-release.sh` 打成对外发布的 zip。发布包是 ad-hoc 签名的；`build-app.sh` 另外支持一个可选的 Developer ID 签名 + 公证流程（`OPENTYPE_NOTARIZE=1`，需要 Developer ID 证书与 notarytool 凭证），但当前发布的包尚未走公证。默认构建**不打包开发者的 `sidecar/.env.local`/API Key**（需要显式 `--bundle-env` 才会打进去，仅供私有本地构建）。Swift 单测（183 项）与 sidecar 单测（474 项）均全绿；发布包已在干净目录完整走过一遍安装并实测转写成功。

## 当前功能

经历过一次从零重写：旧的 5/6 模式系统已整体删除，现在是精确的 3 模式设计，且语音识别与文本生成都交给一个本地 TypeScript/Bun 子进程（`sidecar/`）处理，Swift 侧只负责录音、快捷键、Accessibility 读写和本地历史/审计。工程结构见 `Sources/OpenType`、`sidecar/`；完整技术细节见 [`docs/superpowers/specs/2026-08-09-current-system-state.md`](docs/superpowers/specs/2026-08-09-current-system-state.md)。

- **3 种模式**：`transcribe`（纯转写，不经过任何 LLM）、`ask`（提问，浮窗直接给出答案）、`agent`（语音下发任务，非阻塞地交给可调用工具的 Agent Runtime 执行，结果只生成草稿，永远不会自动回车/发布/执行）
- 模式切换：菜单栏 popover 里的模式选择器、循环快捷键，或录音中途说出“agent 模式”之类的口令自动切换本次模式
- 转写模式有 **Direct** 和 **Review** 两种：Direct 直接写入；Review 会先把识别结果暂存在一个可编辑浮窗里，可以直接打字修改，也可以选中一段文字后再次按快捷键说出纠正指令（比如选中被识别错的词，说“这个不对，应该是英文 PayPal”），由 LLM 只替换选中的这一段；确认后按 `⌘↩` 才真正写入，随时可以 `Esc` 取消
- 语音识别（Whisper）可配置本地或远程：本地默认用 MLX-Whisper（Apple Silicon 专用，完全离线）；远程走 OpenAI 音频转写协议，可填自定义 URL 接兼容服务。设置里可以随时切换，并且有 Test Connection
- LLM Provider 可配置，支持 Anthropic（Messages API）和 OpenAI 兼容协议（覆盖 DeepSeek、OpenAI 本身及自建兼容服务）：填入 URL 和 API Key 后可 Test Connection，成功后拉取模型列表供选择，而不是盲填模型名
- **首次启动设置引导**：如果语音识别和 LLM 都还没配置过，打开主窗口会自动进入设置向导，走完上面两步才会进入正常界面；之后随时可以在设置里重新配置
- **Q&A 和 Agent 各有独立 tab**：可以打开某一次问答/任务的历史会话，再次用同一模式说话即视为对该会话的追问/续接，而不是每次都从头开始——真正的多轮上下文延续，不是简单拼接
- 可定制全局快捷键：左 `Option` 长按、`fn` 长按、双击 `Ctrl`/`Option`/`Shift`，以及 `⌃⇧Space` 等组合键方案（各自独立，不是三键同时双击）
- 原生菜单栏入口：点击菜单栏图标只会展开紧凑的模式切换 popover；主窗口需要单独打开，打开后会出现 Dock 图标并可以 `Cmd+Tab` 切换，关闭主窗口后 Dock 图标消失、回到纯菜单栏模式。菜单栏 popover 和主窗口都有明确的“退出 OpenType”按钮
- 本地长期记忆：sidecar 侧维护一份实体词典（术语、别名、常见指代）+ 一份自由文本的“owner facts”，都可以直接对 Agent 说“记住……”来写入，也支持手动触发一次整理（“dreaming”/consolidation）；在设置的只读“记忆”面板里可以查看，但不能在界面里手动编辑
- 所有模式的结果都会复制到剪贴板；是否额外自动写入当前输入框由设置里的开关决定（仅「听写」模式生效——「问答」结果只停留在浮窗和剪贴板、从不自动写入，「Agent」为草稿模式）；写入失败、或转写期间切换了前台应用时，结果依然保留在剪贴板
- 录音浮层：说话时显示实时字幕预览（基于系统自带识别，仅供预览），配合音量驱动的动态声波；最终识别结果始终以本地/远程 Whisper 重新识别一次为准
- 面向用户的错误提示，不直接暴露底层技术报错
- 完整审计：每一次识别、每一次修正（Review 模式下的每次语音纠错）、以及最终完成或取消，都会追加写入本地一份不可修改的 JSONL 审计日志，原始音频本身不保留

## 首次运行

需要授权两项权限，缺一不可：

1. 麦克风：录制你的语音
2. 辅助功能：读取选中文字并把结果写回当前输入框

macOS 一般会主动弹窗；如果错过了，去「系统设置 → 隐私与安全性」里补上——辅助功能通常必须在那里手动打开。

如果语音识别和 LLM Provider 都还没配置过，打开主窗口会自动进入设置引导向导（Test Connection + 模型列表选择），配置完才会进入正常界面；之后可以随时在“设置 → 语音识别 / AI 模型”里修改。

日常改完代码后重新编译，直接用 `./scripts/build-app.sh` 即可（`setup.sh` 只在环境需要初始化或修复时才需要重跑）。注意每跑一次 `build-app.sh` 都会在 `sidecar/` 下遗留一个约 57 MB 的 `.bun-build` 临时文件，它们已被 gitignore 但不会自动清理，编译多了记得扫一次：`rm -f sidecar/.*.bun-build`。

## 关于 Agent 模式的风险

Agent 模式会真的执行 shell 命令、Python 和文件操作，**没有沙箱，也不会在执行前向你确认**。这是作者针对自己机器做的明确取舍，不是疏漏——但它意味着 Agent 会照着一句口语指令去做事，包括你并不完全是那个意思的时候。这里还有已知缺陷：按下「停止」并不能可靠地阻止已经排进队列的工具调用继续执行。请据此判断是否要用；如果不接受这个取舍，「听写」和「问答」两个模式不涉及这些。

Agent 最终产出的**文字答案**始终只是草稿——复制到剪贴板，永远不会代你发送出去。

## 隐私

- 最终音频默认只在本机由 MLX-Whisper 处理，不发送到任何服务器；如果在设置里把语音识别改成远程模式，音频才会发送到用户自己配置的远程识别地址。处理结束后删除本地临时音频文件。
- 识别出的文字只在 `ask`/`agent` 两种模式下会发送给用户自己配置的 LLM Provider；`transcribe` 模式完全不经过任何 LLM，识别到什么就是什么。发送给模型的上下文里，除了本次输入，还包含**你亲口让 Agent「记住」的全部 owner facts（"关于我" 类事实）**——是全部注入，不是按相关性筛选（只排除非 owner 来源的不可信事实）。此外 sidecar 会把每次 `ask`/`agent` 的输入文本（截断约 200 字）追加到本机一个 `context-debug.log`；它不随「重置输入历史」清除。
- 实时字幕预览用的是 Apple 系统自带的本机语音识别，只作为录音时的临时预览，松开后仍会用上面配置的正式语音识别服务重新识别一次作为最终结果。
- LLM Provider 的 API Key 等配置保存在本机 sidecar 子进程的数据目录下，以 `chmod 600`（仅当前系统账户可读写）的明文 JSON 文件保存 —— 不写入代码仓库、日志或历史，接口回显时也只显示掩码后的 Key；这不是硬件隔离的 Keychain，信任边界等同于本机账户本身，细节见 [当前系统状态文档](docs/superpowers/specs/2026-08-09-current-system-state.md) 第 10 节。
- 输入历史、Q&A/Agent 对话记录、审计日志等均保存在本机 `~/Library/Application Support/OpenType/`：`memory.sqlite3`（Swift 侧的任务历史与“已学到的偏好”）和 `opentype.sqlite3`（sidecar 侧的实体词典、owner facts 与 Q&A/Agent 会话记录）是两套独立的数据库，另有 `context-debug.log`（上面提到的 ask/agent 输入调试日志）；历史可以在设置的二级数据管理中重置（`context-debug.log` 不在重置范围内）。
- 每一次识别、每一次修正（Review 转写模式下的语音纠错）、以及最终完成或取消，都会追加写入本机一份不可修改的 `audit-events.v1.jsonl`，不受历史重置影响。
- Agent 模式的结果只复制到剪贴板并生成草稿，永远不会自动回车、发布或对外执行；是否额外写入当前输入框由“自动写入”开关单独控制。

## 许可证

[MIT](LICENSE)
