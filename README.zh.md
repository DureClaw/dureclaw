# DureClaw (두레클로)

<img src="https://github.com/user-attachments/assets/7ed690a2-92e8-4fbd-a0c8-510f6ee3944e" alt="DureClaw Logo" width="100%" />

分布式设备上的 AI 智能体通过单一频道实时协作的编排基础设施。
以 Claude Code 作为编排器，将各机器上的 AI 智能体作为工作节点连接，组成多机器 AI 团队。

> *[두레 (Dure)](https://en.wikipedia.org/wiki/Dure)：朝鲜时代农民在各自田地上、全村共同耕作的协作制度。*
> *DureClaw 将这种精神注入 AI 智能体 —— 各自的机器，共同的目标，一支队伍。*

[![GitHub](https://img.shields.io/badge/DureClaw-dureclaw-black?logo=github)](https://github.com/DureClaw/dureclaw)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![npm](https://img.shields.io/badge/npm-%40dureclaw%2Fmcp-red?logo=npm)](https://www.npmjs.com/package/@dureclaw/mcp)
[![MCP Registry](https://img.shields.io/badge/MCP_Registry-io.github.dureclaw%2Fmcp-purple?logo=anthropic)](https://registry.modelcontextprotocol.io)
[![Smithery](https://img.shields.io/badge/Smithery-dureclaw%2Fmcp-blue)](https://smithery.ai/server/@dureclaw/mcp)

🌐 **[한국어](./README.md)** | **[English](./README.en.md)** | **中文** | **[日本語](./README.ja.md)**

---

## 安装

> 一句话总结：`(1) 添加市场 → (2) 安装插件 → (3) /reload-plugins → (4) /dureteam-status`，到这一步即可在 Claude Code 中立即使用。

### 第一步 — 添加市场

直接在 Claude Code 提示符中输入：

```
/plugin marketplace add DureClaw/dureclaw
```

预期输出：
```
Successfully added marketplace: dureclaw
```

---

### 第二步 — 安装插件

```
/plugin install dureclaw@dureclaw
```

预期输出：
```
✓ Installed dureclaw. Run /reload-plugins to apply.
```

> 仅需手动注册 MCP 时：`oah setup-mcp` 或 `curl -fsSL https://dureclaw.baryon.ai/scripts/setup-mcp.sh | bash`

---

### 第三步 — 重新加载插件（必须）

安装后 **必须执行一次**，斜杠命令、技能、智能体才会生效。

```
/reload-plugins
```

预期输出（示例）：
```
Reloaded: N plugins · M skills · K agents · ...
```

> 可能会显示 1 条加载错误。可用 `/doctor` 查看详情，但 DureClaw 本身通常不受影响。

---

### 第四步 — 首次运行命令（从这里开始即可使用）

重新加载完成后，以下任意一种输入都是相同的入口：

```
/dureteam-status                            ← 斜杠命令
"显示团队状态" / "团队怎么样"             ← 中文自然语言
"show team" / "现在有几个智能体在线？"    ← 英文/混合也可以
```

初次会显示 “暂无团队 / Phoenix 未连接”，这是正常的。如果只用本机一台，到此即可 — Claude Code 自身就是编排器，可立即执行任务。

要扩展为多机器，请继续第五步。

---

### 第五步 — 启动 Phoenix 服务器（仅多机器扩展时）

要跨机器协作，需要在一台机器（通常是主桌面 / 服务器）上运行作为消息总线的 Phoenix 服务器。

#### 5-A. 自动启动（最简单）

在 Claude Code 中：

```
/setup-team
```

或自然语言：

```
"帮我配置团队"   "添加工作节点"   "setup team"
```

自动执行顺序：
1. 检查 Phoenix 服务器状态 → 未运行则自动安装（**无需 Elixir — 自动选择 Docker 或预构建二进制**）
2. 自动检测服务器 IP（优先使用 Tailscale）
3. 列出当前在线智能体
4. 自动生成各平台工作节点安装命令（macOS / Linux / Windows）

#### 5-B. 仅手动启动服务器

```bash
bash <(curl -fsSL https://dureclaw.baryon.ai/server)
```

选项：

```bash
# 自定义端口
PORT=8080 bash <(curl -fsSL https://dureclaw.baryon.ai/server)

# 强制使用 Docker（无 Elixir 的机器）
USE_DOCKER=1 bash <(curl -fsSL https://dureclaw.baryon.ai/server)

# docker compose
docker compose up
```

成功输出：
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 DureClaw Phoenix Server
 Port    : 4000
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ Tailscale 已连接: 100.x.x.x
✅ 安装完成
```

> 服务器以前台（阻塞）方式运行。如需后台运行，请使用 `nohup … &` 或 `tmux/screen`。

---

### 第六步 — 安装工作节点（各远程机器）

Phoenix 服务器启动后，从其他机器连接工作节点。

**最简单方式** — 直接用自然语言告诉 Claude Code：

```
"帮我添加工作节点"   "想连接一台 tester 机器"   "把 Mac Mini 加入团队"
```

Claude 会自动检测服务器 IP，并按 OS / 架构提供 **可直接复制执行的一行命令**。即使没有 Tailscale，也会逐步引导完成安装。

手动一行命令请参阅 [添加分布式子智能体 — 按 OS / 架构的一行安装](#添加分布式子智能体--按-os--架构的一行安装) 章节。

---

## 架构

```
① Claude Code（编排器，MacBook）
     /plugin install dureclaw@dureclaw
   └─ MCP (oah-mcp) → Phoenix WebSocket

② Phoenix Server（消息总线）
     bash <(curl -fsSL .../setup-server.sh)   ← Docker 或预构建二进制
   ws://host:4000

③ oah-agent（工作节点，各机器）
     PHOENIX=ws://host:4000 ROLE=builder bash <(curl -fsSL .../setup-agent.sh)
   → WebSocket 连接 → 接收 task.assign
   → 执行 AI 后端（claude / opencode / gemini / aider / codex）
   → 返回 task.result
```

---

## 包结构

```
dureclaw/
├── .claude-plugin/             Claude Code 插件元数据
│   ├── plugin.json
│   └── marketplace.json
│
├── commands/                   斜杠命令 (/setup-team, /dureteam-status)
├── agents/                     智能体定义（orchestrator 等）
├── skills/                     DureClaw 编排技能 (dureclaw, dureclaw-run)
│
├── packages/
│   ├── phoenix-server/         Elixir/Phoenix 消息总线（核心）
│   ├── agent-daemon/           WebSocket 智能体守护进程（oah-agent）
│   ├── oah-mcp/                Claude Code MCP 服务器（@dureclaw/mcp）
│   └── ctl/                    oah-ctl 管理 CLI
│
└── scripts/
    ├── setup-server.sh         Phoenix 服务器安装
    ├── setup-agent.sh          工作节点安装（oah 命令）
    ├── setup-mcp.sh            Claude Code MCP 注册
    └── oah                     统一 CLI
```

---

## 使用方法

安装插件后，在 Claude Code 中直接使用：

```
# 查看团队状态
/dureteam-status

# 扩展为多机器团队（自动配置 Phoenix 服务器 + 工作节点）
/setup-team

# 向智能体发送任务
mcp__oah__send_task(to: "builder@mac-mini", instructions: "[SHELL] make build")

# 列出在线智能体
mcp__oah__get_presence
```

### 可用 MCP 工具

`get_presence` · `send_task` · `receive_task` · `complete_task` · `read_state` · `write_state` · `read_mailbox` · `post_message`

> 完整工具说明 → [docs/API_REFERENCE.md](docs/API_REFERENCE.md)

### 系统结构图

```
Claude Code（编排器）
  │  MCP (oah-mcp)
  ▼
Phoenix Server              ws://host:4000
  │  Phoenix Channel
  ├──▶ oah-agent (Mac Mini)    builder@mac-mini
  ├──▶ oah-agent (GPU 服务器)  builder@gpu-server
  └──▶ oah-agent (树莓派)      executor@raspi
          └─ 执行 AI 后端 → 返回 task.result
```

---

## REST API

主要端点：`/api/health` · `/api/presence` · `/api/work-keys` · `/api/state/:wk` · `/api/task` · `/api/mailbox/:agent`

> 完整 API 规范及 Phoenix Channel 协议 → [docs/API_REFERENCE.md](docs/API_REFERENCE.md)

---

## 截图

### 各平台安装 & 连接

| 平台 | 安装输出 |
|------|---------|
| macOS Apple Silicon | `✅ darwin-arm64 二进制下载完成` → `→ 服务器启动 · ws://100.x.x.x:4000` |
| Linux x86_64（GPU 服务器） | `✅ linux-x86_64 智能体安装完成` → `✅ 检测到 claude-cli` → `→ builder@gpu-server 连接成功` |
| Raspberry Pi 4/5 | `✅ linux-arm64 智能体安装完成` → `✅ 检测到 opencode` → `→ executor@raspberrypi 连接成功` |
| Raspberry Pi Zero W | `✅ Python 智能体模式 (armv6)` → `⚠ aider 轻量模式` → `→ executor@zero-w 连接成功 (WiFi)` |
| Windows（PowerShell） | `✅ opencode npm 安装完成` → `→ builder@DESKTOP-WIN 连接成功` |

### 智能体角色

| 角色 | AI 后端 | 任务示例 |
|------|---------|---------|
| `builder` | claude-cli / opencode / codex | `[SHELL] make build` → 代码编写 & 构建 |
| `tester` | claude-cli / aider | `[SHELL] pytest tests/` → 测试执行 & 验证 |
| `analyst` | claude-cli / gemini | 代码分析·审查·缺陷检测 |
| `executor` | aider / opencode | 轻量命令执行 · 树莓派 Zero W 最优 |

**任务调度 & 多智能体状态（6台设备同时连接）**

![DureClaw 控制台 — 任务调度](./docs/screenshots/02-task-dispatch.png)

**智能体详情 — 实时查看各机器 capability**

![DureClaw 控制台 — 智能体详情](./docs/screenshots/03-agent-presence.png)

---

## 支持平台

| 平台 | 架构 | 服务器 | 工作节点 | 备注 |
|------|------|--------|---------|------|
| macOS（Apple Silicon） | arm64 | ✅ 预构建 | ✅ | M1/M2/M3/M4 |
| macOS（Intel） | x86_64 | ✅ 预构建 | ✅ | |
| Linux | x86_64 | ✅ 预构建 | ✅ | Ubuntu/Debian/CentOS |
| **Raspberry Pi 4/5** | **arm64** | ✅ 预构建 | ✅ | **executor 角色最优** |
| **Raspberry Pi Zero W/2W** | **armv6/arm64** | ❌ | ✅ Python | **内置 WiFi · IoT executor** |
| Windows 10/11 | x86_64 | 🐳 Docker | ✅ PowerShell | |
| Docker（所有平台） | any | ✅ | — | `ghcr.io/dureclaw/dureclaw` |

---

## 前置条件

| | 所需 | 用途 |
|--|------|------|
| **必须** | [Claude Code CLI](https://claude.ai/download) | 编排器 |
| **多机器** | [Tailscale](https://tailscale.com/download) | 机器间私有网络（免费，最多 100 台） |

其余组件（Phoenix 服务器、oah-agent）**自动下载预构建二进制**，无需额外安装。

---

## 文档

| 文档 | 说明 |
|------|------|
| [docs/CONTRIBUTING.md](./docs/CONTRIBUTING.md) | **开发指南** — 测试、Phoenix Channel 协议、PR 贡献方法 |
| [docs/PROTOCOL.md](./docs/PROTOCOL.md) | **协议规范** — 4层通信协议正式定义（L1 网络 ~ L4 团队协议） |
| [docs/PRIVATE_NETWORK.md](./docs/PRIVATE_NETWORK.md) | **私有网络配置** — 通过 Tailscale 将远程智能体连接为一个团队 |
| [docs/AGENTS.md](./docs/AGENTS.md) | 智能体角色定义 |
| [docs/METHODOLOGY.md](./docs/METHODOLOGY.md) | 工作循环方法论 |
| [docs/INSTALL.md](./docs/INSTALL.md) | 安装指南 |

---

## 示例

| 示例 | 说明 |
|------|------|
| [fix-agent](./examples/fix-agent/) | 多个 AI 智能体协作自动分析缺陷、修复代码、创建 PR |

```
Claude Code → analyzer-agent（缺陷检测）
           → fixer-agent    （代码修复）
           → tester-agent   （验证 + 创建 PR）
```

---

## License

MIT © 2025-2026 [Seungwoo Hong (홍승우)](https://github.com/hongsw)

详见 [LICENSE](./LICENSE) 文件。
