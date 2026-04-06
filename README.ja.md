# DureClaw (두레클로)

<img src="https://github.com/user-attachments/assets/7ed690a2-92e8-4fbd-a0c8-510f6ee3944e" alt="DureClaw Logo" width="100%" />

分散したデバイス上の AI エージェントが単一チャネルでリアルタイムに協力するオーケストレーション基盤。
Claude Code をオーケストレーターとして、各マシンの AI エージェントをワーカーとして接続し、マルチマシン AI チームを構成する。

> *[두레 (Dure)](https://en.wikipedia.org/wiki/Dure)：朝鮮時代の農民が各自の田んぼで村全体が共同耕作を行った協働システム。*
> *DureClaw はその精神を AI エージェントに込める — それぞれのマシンで、ひとつの目標へ、ひとつのクルーとして。*

[![GitHub](https://img.shields.io/badge/DureClaw-dureclaw-black?logo=github)](https://github.com/DureClaw/dureclaw)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![npm](https://img.shields.io/badge/npm-%40dureclaw%2Fmcp-red?logo=npm)](https://www.npmjs.com/package/@dureclaw/mcp)
[![MCP Registry](https://img.shields.io/badge/MCP_Registry-io.github.dureclaw%2Fmcp-purple?logo=anthropic)](https://registry.modelcontextprotocol.io)
[![Smithery](https://img.shields.io/badge/Smithery-dureclaw%2Fmcp-blue)](https://smithery.ai/server/@dureclaw/mcp)

🌐 **[한국어](./README.md)** | **[English](./README.en.md)** | **[中文](./README.zh.md)** | **日本語**

---

## インストール

### ステップ 1 — Claude Code にプラグイン追加（必須）

```shell
/plugin marketplace add DureClaw/dureclaw
```

```shell
/plugin install dureclaw@dureclaw
```

> 手動登録：`oah setup-mcp` または `curl -fsSL .../scripts/setup-mcp.sh | bash`

**ここまでですぐに使えます。** Claude Code がオーケストレーターとして機能し、ローカルでタスクを直接実行できます。

---

### ステップ 2+3 — マルチマシンチームに拡張（オプション）

他のマシンに作業を分散するには、**Claude Code CLI 内で**コマンドまたは自然言語で実行します：

```
/setup-team
```

または**自然言語でも同様に実行**できます：

```
"チームを設定して"   "ワーカーを追加して"   "setup team"
```

自動実行の順序：
1. Phoenix サーバーの状態確認 → 未起動なら自動インストール（**Elixir 不要 — Docker または事前ビルド済みバイナリ**）
2. サーバー IP の自動検出（Tailscale を優先）
3. 現在オンラインのエージェント一覧を表示
4. リモートマシン用ワーカーインストールコマンドを出力（macOS/Linux/Windows）

```
/team-status   ← チーム状態確認（または「チームの状態を教えて」「何人オンライン？」）
```

> Phoenix サーバーは **Docker だけで Elixir なしに即起動**できます。
> `USE_DOCKER=1 bash <(curl -fsSL .../setup-server.sh)` または `docker compose up`

> マルチマシン分散処理が必要な場合のみ実行してください。

---

### ステップ 4 — ワーカーエージェントのインストール（各リモートマシン）

**Claude Code に話しかけると直接案内してくれます。**

```
"ワーカーを追加して"   "tester マシンを接続したい"   "チームに Mac Mini を追加して"
```

Claude がサーバー IP を自動検出し、マシンごとに**すぐコピー＆実行できるコマンド**を案内します。
Tailscale がなくてもインストールから順を追ってガイドします。

---

## アーキテクチャ

```
① Claude Code（オーケストレーター、MacBook）
     /plugin install dureclaw@dureclaw
   └─ MCP (oah-mcp) → Phoenix WebSocket

② Phoenix Server（メッセージバス）
     bash <(curl -fsSL .../setup-server.sh)   ← Docker または事前ビルド済みバイナリ
   ws://host:4000

③ oah-agent（ワーカー、各マシン）
     PHOENIX=ws://host:4000 ROLE=builder bash <(curl -fsSL .../setup-agent.sh)
   → WebSocket 接続 → task.assign 受信
   → AI バックエンド実行（claude / opencode / gemini / aider / codex）
   → task.result 返送
```

---

## パッケージ構成

```
dureclaw/
├── .claude-plugin/             Claude Code プラグインメタデータ
│   ├── plugin.json
│   └── marketplace.json
│
├── .claude/
│   ├── commands/               スラッシュコマンド (/setup-team, /team-status)
│   ├── agents/                 エージェント定義（orchestrator など）
│   └── skills/dureclaw/        DureClaw オーケストレーションスキル
│
├── packages/
│   ├── phoenix-server/         Elixir/Phoenix メッセージバス（コア）
│   ├── agent-daemon/           WebSocket エージェントデーモン（oah-agent）
│   ├── oah-mcp/                Claude Code MCP サーバー（@dureclaw/mcp）
│   └── ctl/                    oah-ctl 管理 CLI
│
└── scripts/
    ├── setup-server.sh         Phoenix サーバーインストール
    ├── setup-agent.sh          ワーカーエージェントインストール（oah コマンド）
    ├── setup-mcp.sh            Claude Code MCP 登録
    └── oah                     統合 CLI
```

---

## 使い方

プラグインインストール後、Claude Code から直接使用します：

```
# チーム状態確認
/team-status

# マルチマシンチームに拡張（Phoenix サーバー + ワーカーエージェント自動設定）
/setup-team

# エージェントにタスクを送信
mcp__oah__send_task(to: "builder@mac-mini", instructions: "[SHELL] make build")

# オンラインエージェント一覧
mcp__oah__get_presence
```

### 利用可能な MCP ツール

`get_presence` · `send_task` · `receive_task` · `complete_task` · `read_state` · `write_state` · `read_mailbox` · `post_message`

> 完全なツール仕様 → [docs/API_REFERENCE.md](docs/API_REFERENCE.md)

### 構成図

```
Claude Code（オーケストレーター）
  │  MCP (oah-mcp)
  ▼
Phoenix Server              ws://host:4000
  │  Phoenix Channel
  ├──▶ oah-agent (Mac Mini)    builder@mac-mini
  ├──▶ oah-agent (GPU サーバー) builder@gpu-server
  └──▶ oah-agent (ラズパイ)    executor@raspi
          └─ AI バックエンド実行 → task.result 返送
```

---

## REST API

主要エンドポイント：`/api/health` · `/api/presence` · `/api/work-keys` · `/api/state/:wk` · `/api/task` · `/api/mailbox/:agent`

> 完全な API 仕様および Phoenix Channel プロトコル → [docs/API_REFERENCE.md](docs/API_REFERENCE.md)

---

## スクリーンショット

### プラットフォーム別インストール & 接続

| プラットフォーム | インストール出力 |
|--------------|--------------|
| macOS Apple Silicon | `✅ darwin-arm64 バイナリダウンロード完了` → `→ サーバー起動 · ws://100.x.x.x:4000` |
| Linux x86_64（GPU サーバー） | `✅ linux-x86_64 エージェントインストール完了` → `✅ claude-cli 検出` → `→ builder@gpu-server 接続完了` |
| Raspberry Pi 4/5 | `✅ linux-arm64 エージェントインストール完了` → `✅ opencode 検出` → `→ executor@raspberrypi 接続完了` |
| Raspberry Pi Zero W | `✅ Python エージェントモード (armv6)` → `⚠ aider 軽量モード` → `→ executor@zero-w 接続完了 (WiFi)` |
| Windows（PowerShell） | `✅ opencode npm インストール完了` → `→ builder@DESKTOP-WIN 接続完了` |

### エージェントロール

| ロール | AI バックエンド | タスク例 |
|--------|-------------|---------|
| `builder` | claude-cli / opencode / codex | `[SHELL] make build` → コード作成・ビルド |
| `tester` | claude-cli / aider | `[SHELL] pytest tests/` → テスト実行・検証 |
| `analyst` | claude-cli / gemini | コード分析・レビュー・バグ検出 |
| `executor` | aider / opencode | 軽量コマンド実行 · RPi Zero W に最適 |

---

## 対応プラットフォーム

| プラットフォーム | アーキテクチャ | サーバー | ワーカー | 備考 |
|--------------|-------------|--------|---------|------|
| macOS（Apple Silicon） | arm64 | ✅ 事前ビルド | ✅ | M1/M2/M3/M4 |
| macOS（Intel） | x86_64 | ✅ 事前ビルド | ✅ | |
| Linux | x86_64 | ✅ 事前ビルド | ✅ | Ubuntu/Debian/CentOS |
| **Raspberry Pi 4/5** | **arm64** | ✅ 事前ビルド | ✅ | **executor ロールに最適** |
| **Raspberry Pi Zero W/2W** | **armv6/arm64** | ❌ | ✅ Python | **WiFi 内蔵 · IoT executor** |
| Windows 10/11 | x86_64 | 🐳 Docker | ✅ PowerShell | |
| Docker（全プラットフォーム） | any | ✅ | — | `ghcr.io/dureclaw/dureclaw` |

---

## 前提条件

| | 必要なもの | 用途 |
|--|-----------|------|
| **必須** | [Claude Code CLI](https://claude.ai/download) | オーケストレーター |
| **マルチマシン** | [Tailscale](https://tailscale.com/download) | マシン間プライベートネットワーク（無料、100台まで） |

その他（Phoenix サーバー、oah-agent）は**事前ビルド済みバイナリを自動ダウンロード**するため、別途インストール不要です。

---

## ドキュメント

| ドキュメント | 説明 |
|------------|------|
| [docs/CONTRIBUTING.md](./docs/CONTRIBUTING.md) | **開発ガイド** — テスト、Phoenix Channel プロトコル、PR 貢献方法 |
| [docs/PROTOCOL.md](./docs/PROTOCOL.md) | **プロトコル仕様** — 4層通信プロトコル公式定義（L1 ネットワーク ～ L4 チームプロトコル） |
| [docs/PRIVATE_NETWORK.md](./docs/PRIVATE_NETWORK.md) | **プライベートネットワーク構成** — Tailscale でリモートエージェントを一つのチームに接続する方法 |
| [docs/AGENTS.md](./docs/AGENTS.md) | エージェントロール定義 |
| [docs/METHODOLOGY.md](./docs/METHODOLOGY.md) | ワークループ方法論 |
| [docs/INSTALL.md](./docs/INSTALL.md) | インストールガイド |

---

## 活用事例

| サンプル | 説明 |
|--------|------|
| [fix-agent](./examples/fix-agent/) | 複数の AI エージェントが協力してリポジトリのバグを自動分析・修正・PR 作成 |

```
Claude Code → analyzer-agent（バグ検出）
           → fixer-agent    （コード修正）
           → tester-agent   （検証 + PR 作成）
```

---

## License

MIT © 2025-2026 [Seungwoo Hong (홍승우)](https://github.com/hongsw)

詳細は [LICENSE](./LICENSE) ファイルを参照してください。
