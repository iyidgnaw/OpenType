<div align="center">

<img src="docs/assets/icon.png" width="128" alt="OpenType">

# OpenType

**中文** · [English](README.en.md)

本地优先的 macOS AI 语音输入工具。按住快捷键说话，松开后直接转成文字、回答你的问题，或者把一个任务交给 Agent 去做。语音识别默认完全在本机运行，纯听写不需要 API Key，也不需要联网。

**[功能介绍与使用说明 → opentype-site.vercel.app](https://opentype-site.vercel.app/)**

</div>

## 安装

从 [Releases](https://github.com/iyidgnaw/OpenType/releases/latest) 下载 `OpenType-<版本>-macos-arm64.zip`（约 24 MB），解压后在该目录里运行：

```bash
./install.sh
```

它会把 app 装进 `/Applications`、装好依赖、在 app 内部搭建本地语音识别环境，然后重新签名。可以反复运行，重跑时会保留已建好的语音环境。加 `--skip-whisper` 可跳过本地识别，改在应用内配置远程识别服务。

装完还有两件只能你自己做的事：

1. **授权麦克风和辅助功能**——缺一不可。macOS 一般会主动弹窗；错过了就去「系统设置 → 隐私与安全性」补上，辅助功能通常必须在那里手动打开。
2. **走一遍应用内设置向导**——选语音识别来源，以及（如果要用问答和 Agent 模式）填一个 LLM 的 API Key。

首次转写会下载约 460 MB 的语音模型，只发生一次，长时间等待不是卡死。

> 发布包是 ad-hoc 签名、**未经 Apple 公证**的。`install.sh` 会替你清掉下载隔离标记，正常流程不会看到 Gatekeeper 警告；但这也意味着你在信任本仓库作者，介意的话请从源码自行构建。

**不想自己盯着这套流程**，可以把 [`docs/onboarding/coding-agent-setup-prompt.md`](docs/onboarding/coding-agent-setup-prompt.md) 里的 prompt 交给 Claude Code / Codex 等，让它把下载、安装、权限授予和设置向导全程带你走一遍。

## 依赖

- **Apple Silicon Mac**：本地语音识别基于 Apple 的 MLX，没有 Intel 版本，无变通办法。
- **macOS 13 (Ventura) 或更新**。
- **[Homebrew](https://brew.sh)**：本地识别需要，`install.sh` 用它安装 `python@3.12` 和 `ffmpeg`。只用远程识别的话不需要。
- **磁盘**：app 本体约 74 MB，本地语音环境约 1.1 GB，模型另占约 460 MB。
- **LLM API Key**：只有问答和 Agent 模式需要，纯听写不需要。

## 从源码构建

```bash
git clone https://github.com/iyidgnaw/OpenType.git
cd OpenType
./scripts/setup.sh
```

[`scripts/setup.sh`](scripts/setup.sh) 是幂等的，检查环境、装依赖、搭建 Whisper venv、编译出 `dist/OpenType.app`；`--check` 只体检不改动。除上面的依赖外还需要 **Xcode 命令行工具**。打发布包用 [`scripts/build-release.sh`](scripts/build-release.sh)。

架构和开发约定见 [`CLAUDE.md`](CLAUDE.md)。

## 关于 Agent 模式

Agent 模式会真的执行 shell 命令、Python 和文件操作，**没有沙箱，也不会在执行前向你确认**——这是作者针对自己机器做的明确取舍。已知缺陷：按下「停止」并不能可靠地阻止已排队的工具调用继续执行。听写和问答两个模式不涉及这些。Agent 产出的文字答案始终只是草稿，只复制到剪贴板，永远不会代你发送。

## 许可证

[MIT](LICENSE)
