#!/usr/bin/env bun
/**
 * oah-ctl — open-agent-harness control CLI
 *
 * Usage:
 *   oah-ctl [--server ws://host:4000]     # interactive REPL (default)
 *   oah-ctl status                         # connected agents & work keys
 *   oah-ctl task "instructions"            # send task to builder
 *   oah-ctl task --to builder@gpu "..."    # send to specific agent
 *   oah-ctl logs                           # real-time event stream
 *
 * Env:
 *   STATE_SERVER   Phoenix server URL (default: ws://localhost:4000)
 */

import * as readline from "readline";

// ─── Config ───────────────────────────────────────────────────────────────────

// --server flag support
const serverFlagIdx = process.argv.findIndex(a => a === "--server" || a === "-s");
const serverFlagVal = serverFlagIdx !== -1 ? process.argv[serverFlagIdx + 1] : undefined;
const SERVER_RAW = serverFlagVal ?? process.env.STATE_SERVER ?? "ws://localhost:4000";
const WS_BASE   = SERVER_RAW.replace(/^http/, "ws").replace(/\/$/, "");
const HTTP_BASE  = SERVER_RAW.replace(/^ws/, "http").replace(/\/$/, "");
const WS_URL     = `${WS_BASE}/socket/websocket?vsn=2.0.0`;

// Strip --server flag from args
const rawArgs = process.argv.slice(2).filter((_, i) =>
  i !== serverFlagIdx - 2 && i !== serverFlagIdx - 2 + 1 &&
  process.argv[i + 2] !== "--server" && process.argv[i + 2] !== "-s" &&
  process.argv[i + 3] !== serverFlagVal
);
const args = process.argv.slice(2).filter((a, i, arr) => {
  if (a === "--server" || a === "-s") return false;
  if (arr[i - 1] === "--server" || arr[i - 1] === "-s") return false;
  return true;
});

// ─── Colors ───────────────────────────────────────────────────────────────────

const C = {
  reset:  "\x1b[0m",
  bold:   "\x1b[1m",
  dim:    "\x1b[2m",
  cyan:   "\x1b[36m",
  green:  "\x1b[32m",
  yellow: "\x1b[33m",
  red:    "\x1b[31m",
  blue:   "\x1b[34m",
  gray:   "\x1b[90m",
  white:  "\x1b[97m",
};

const c = (color: keyof typeof C, text: string) => C[color] + text + C.reset;
const bold = (t: string) => c("bold", t);
const dim  = (t: string) => c("gray", t);

// ─── Phoenix Protocol ─────────────────────────────────────────────────────────

type PhxMsg = [string | null, string | null, string, string, Record<string, unknown>];

let ws: WebSocket | null = null;
let refCounter = 0;
let joinRef: string | null = null;
let workKey = "";
let heartbeatTimer: ReturnType<typeof setInterval> | null = null;

function nextRef() { return String(++refCounter); }

function sendRaw(msg: PhxMsg) {
  if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
}

function sendEvent(event: string, payload: Record<string, unknown>) {
  sendRaw([joinRef, nextRef(), `work:${workKey}`, event, payload]);
}

function startHeartbeat() {
  if (heartbeatTimer) clearInterval(heartbeatTimer);
  heartbeatTimer = setInterval(() => {
    sendRaw([null, nextRef(), "phoenix", "heartbeat", {}]);
  }, 30_000);
}

function cleanup() {
  if (heartbeatTimer) clearInterval(heartbeatTimer);
  ws?.close();
}

// ─── REST helpers ─────────────────────────────────────────────────────────────

interface Agent {
  name: string;
  role: string;
  machine?: string;
  joined_at?: string;
}

async function apiGet<T>(path: string): Promise<T> {
  const res = await fetch(`${HTTP_BASE}${path}`);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json() as Promise<T>;
}

async function getAgents(): Promise<Agent[]> {
  const data = await apiGet<{ agents: Agent[] }>("/api/presence");
  return data.agents ?? [];
}

async function getWorkKeys(): Promise<string[]> {
  const data = await apiGet<{ work_keys: string[] }>("/api/work-keys");
  return data.work_keys ?? [];
}

async function getLatestWorkKey(): Promise<string | null> {
  try {
    const data = await apiGet<{ work_key: string }>("/api/work-keys/latest");
    return data.work_key;
  } catch { return null; }
}

async function ensureWorkKey(): Promise<string> {
  const wk = await getLatestWorkKey();
  if (wk) return wk;
  const res = await fetch(`${HTTP_BASE}/api/work-keys`, { method: "POST" });
  const data = await res.json() as { work_key: string };
  console.log(dim(`[ctl] Work Key 생성: ${data.work_key}`));
  return data.work_key;
}

// ─── Channel connection ───────────────────────────────────────────────────────

type EventHandler = (event: string, payload: Record<string, unknown>) => void;

function connectChannel(onEvent: EventHandler, onJoin?: () => void): Promise<void> {
  return new Promise((resolve, reject) => {
    ws = new WebSocket(WS_URL);

    ws.onopen = () => {
      joinRef = nextRef();
      sendRaw([joinRef, joinRef, `work:${workKey}`, "phx_join", {
        agent_name: "ctl@controller",
        role: "controller",
        machine: "controller",
      }]);
      startHeartbeat();
    };

    ws.onmessage = (ev) => {
      let msg: PhxMsg;
      try { msg = JSON.parse(ev.data as string); } catch { return; }
      const [, , , event, payload] = msg;

      if (event === "phx_reply") {
        const s = (payload as { status?: string }).status;
        if (s === "ok") { onJoin?.(); resolve(); }
        else reject(new Error(`join failed: ${JSON.stringify(payload)}`));
        return;
      }
      if (event === "presence_state" || event === "presence_diff") return;
      if (event === "phx_error" || event === "phx_close") return;

      onEvent(event, payload);
    };

    ws.onerror = () => reject(new Error(`WebSocket error: ${WS_URL}`));
    ws.onclose = () => {};
  });
}

// ─── status ──────────────────────────────────────────────────────────────────

async function cmdStatus() {
  try {
    const [agents, keys] = await Promise.all([getAgents(), getWorkKeys()]);

    console.log(`\n${c("cyan", "━━━ Work Keys ━━━━━━━━━━━━━━━━━━━━━━━")}`);
    if (keys.length === 0) {
      console.log(dim("  (없음)"));
    } else {
      keys.forEach(k => console.log(`  ${c("cyan", k)}`));
    }

    console.log(`\n${c("cyan", "━━━ 에이전트 ━━━━━━━━━━━━━━━━━━━━━━━━")}`);
    if (agents.length === 0) {
      console.log(dim("  (없음 — oah-agent 실행 필요)"));
    } else {
      const roleColor: Record<string, keyof typeof C> = {
        orchestrator: "cyan", builder: "green", verifier: "yellow",
        reviewer: "blue", controller: "gray",
      };
      agents.forEach(a => {
        const col = roleColor[a.role] ?? "white";
        const joined = a.joined_at ? dim(` (${new Date(a.joined_at).toLocaleTimeString("ko-KR")})`) : "";
        console.log(`  ${c(col, (a.role ?? "?").padEnd(13))} ${bold(a.name ?? "unknown")}${joined}`);
      });
    }
    console.log();
  } catch {
    console.error(c("red", `❌ 서버 연결 실패: ${HTTP_BASE}`));
    process.exit(1);
  }
}

// ─── logs ─────────────────────────────────────────────────────────────────────

async function cmdLogs() {
  workKey = await ensureWorkKey();
  console.log(`\n${c("cyan", `[logs]`)} work:${workKey}`);
  console.log(dim("Ctrl+C로 종료\n"));

  await connectChannel((event, payload) => {
    const ts = new Date().toLocaleTimeString("ko-KR");
    const p  = payload as Record<string, unknown>;

    const color: keyof typeof C =
      event === "task.result"   ? "green"  :
      event === "task.blocked"  ? "red"    :
      event === "task.assign"   ? "yellow" :
      event.startsWith("agent") ? "cyan"   : "gray";

    const from = p.from ? dim(` ← ${p.from}`) : "";
    const to   = p.to   ? dim(` → ${p.to}`)   : "";

    console.log(`${dim(ts)} ${c(color, event.padEnd(26))}${from}${to}`);

    if (event === "task.result") {
      console.log(c("green", `  ✅ ${p.task_id} exit=${p.exit_code}`));
      const arts = p.artifacts as string[] | undefined;
      arts?.forEach(a => console.log(dim(`     ARTIFACT: ${a}`)));
    }
    if (event === "task.blocked") {
      console.log(c("red", `  ❌ ${p.task_id} — ${p.error}`));
    }
    if (event === "task.progress") {
      console.log(dim(`  … ${p.message ?? ""}`));
    }
  });

  await new Promise(() => {});
}

// ─── task ─────────────────────────────────────────────────────────────────────

async function cmdTask(taskArgs: string[]) {
  let to: string | undefined;
  let role = "builder";
  const remaining: string[] = [];

  for (let i = 0; i < taskArgs.length; i++) {
    if ((taskArgs[i] === "--to" || taskArgs[i] === "-t") && taskArgs[i + 1]) {
      to = taskArgs[++i];
    } else if (taskArgs[i] === "--role" && taskArgs[i + 1]) {
      role = taskArgs[++i];
    } else {
      remaining.push(taskArgs[i]);
    }
  }

  const instructions = remaining.join(" ");
  if (!instructions) {
    console.error(c("red", '사용법: oah-ctl task [--to agent] "instructions"'));
    process.exit(1);
  }

  workKey = await ensureWorkKey();
  const taskId = `ctl-${Date.now()}`;

  console.log(`\n${c("cyan", "[task]")} ${bold(taskId)}`);
  console.log(dim(`  wk:   ${workKey}`));
  console.log(dim(`  to:   ${to ?? `${role} (broadcast)`}`));
  console.log(dim(`  ins:  ${instructions.slice(0, 80)}${instructions.length > 80 ? "…" : ""}\n`));

  let done = false;
  await connectChannel((event, payload) => {
    const p = payload as Record<string, unknown>;
    if (p.task_id !== taskId) return;

    if (event === "task.progress") {
      process.stdout.write(dim(`  … ${p.message ?? "working"}\r`));
    }
    if (event === "task.result") {
      console.log(c("green", `\n✅ 완료 (exit ${p.exit_code})`));
      const arts = p.artifacts as string[] | undefined;
      if (arts?.length) {
        console.log(c("cyan", "ARTIFACTS:"));
        arts.forEach(a => console.log(`  ${a}`));
      }
      done = true;
      cleanup();
      process.exit(0);
    }
    if (event === "task.blocked") {
      console.log(c("red", `\n❌ 블록됨: ${p.error}`));
      done = true;
      cleanup();
      process.exit(1);
    }
  }, () => {
    sendEvent("task.assign", {
      task_id: taskId,
      from: "ctl@controller",
      to,
      role,
      instructions,
    });
    console.log(dim("[ctl] task.assign 전송됨 — 결과 대기 중..."));
  });

  await new Promise(() => {});
}

// ─── interactive REPL ─────────────────────────────────────────────────────────

function printHelp() {
  console.log(`
${dim("명령어:")}
  ${c("cyan", "status")}  ${dim("(s)")}          연결된 에이전트 목록
  ${c("cyan", "task")}    ${dim("(t) <text>")}    builder에게 태스크 전송
  ${c("cyan", "task")}    ${dim("--to <agent>")}  특정 에이전트에게
  ${c("cyan", "logs")}    ${dim("(l)")}          이벤트 스트림 ON/OFF
  ${c("cyan", "help")}    ${dim("(h)")}          이 도움말
  ${c("cyan", "quit")}    ${dim("(q)")}          종료
  ${dim("<아무 텍스트>      builder에게 즉시 태스크")}
`);
}

function printPrompt(rl: readline.Interface) {
  rl.setPrompt(`${c("cyan", "oah")}${c("green", `·${workKey.slice(-7) || "????"}`)} ${c("gray", "❯")} `);
  rl.prompt();
}

async function cmdInteractive() {
  workKey = await ensureWorkKey().catch(() => "");

  console.log(`
${c("cyan", "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")}
${bold(" oah-ctl")} ${dim("interactive mode")}
${dim(` server : ${HTTP_BASE}`)}
${dim(` wk     : ${workKey || "(없음)"}`)}
${c("cyan", "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")}
${dim(' help 또는 h 로 명령어 보기')}
`);

  let logsEnabled = false;

  if (workKey) {
    await connectChannel((event, payload) => {
      const p = payload as Record<string, unknown>;
      const ts = new Date().toLocaleTimeString("ko-KR");

      // Always show task results / agent events
      if (event === "task.result") {
        process.stdout.write("\n");
        console.log(c("green", `✅ [${ts}] ${p.task_id} 완료 (exit ${p.exit_code})`));
        const arts = p.artifacts as string[] | undefined;
        arts?.forEach(a => console.log(dim(`   ARTIFACT: ${a}`)));
        rl.prompt();
      } else if (event === "task.blocked") {
        process.stdout.write("\n");
        console.log(c("red", `❌ [${ts}] ${p.task_id} — ${p.error}`));
        rl.prompt();
      } else if (event === "agent.hello") {
        process.stdout.write("\n");
        console.log(c("cyan", `[+] ${p.from ?? p.agent} 접속`));
        rl.prompt();
      } else if (event === "agent.bye") {
        process.stdout.write("\n");
        console.log(dim(`[-] ${p.from ?? p.agent} 종료`));
        rl.prompt();
      } else if (logsEnabled) {
        const color: keyof typeof C = event.startsWith("task.assign") ? "yellow" : "gray";
        process.stdout.write("\n");
        console.log(dim(ts) + " " + c(color, event));
        rl.prompt();
      }
    }).catch(() => {
      console.log(dim("[ctl] 채널 연결 실패 — 서버 없이 REST만 사용합니다"));
    });
  }

  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
    terminal: true,
  });

  printPrompt(rl);

  rl.on("line", async (line) => {
    const trimmed = line.trim();
    if (!trimmed) { printPrompt(rl); return; }

    const parts  = trimmed.split(/\s+/);
    const cmd    = parts[0].toLowerCase();
    const rest   = parts.slice(1);

    if (cmd === "quit" || cmd === "q" || cmd === "exit") {
      cleanup();
      process.exit(0);
    }

    if (cmd === "help" || cmd === "h") {
      printHelp();
    } else if (cmd === "status" || cmd === "s") {
      await cmdStatus();
    } else if (cmd === "logs" || cmd === "l") {
      logsEnabled = !logsEnabled;
      console.log(dim(`[logs] ${logsEnabled ? "ON" : "OFF"}`));
    } else if (cmd === "task" || cmd === "t") {
      if (!rest.length) { console.log(c("red", '태스크 내용을 입력하세요')); }
      else {
        let to: string | undefined;
        let role = "builder";
        const remaining: string[] = [];
        for (let i = 0; i < rest.length; i++) {
          if ((rest[i] === "--to" || rest[i] === "-t") && rest[i + 1]) { to = rest[++i]; }
          else if (rest[i] === "--role" && rest[i + 1]) { role = rest[++i]; }
          else remaining.push(rest[i]);
        }
        const instructions = remaining.join(" ");
        if (!instructions) { console.log(c("red", '태스크 내용을 입력하세요')); }
        else {
          const taskId = `ctl-${Date.now()}`;
          sendEvent("task.assign", { task_id: taskId, from: "ctl@controller", to, role, instructions });
          console.log(dim(`[→] task.assign: ${taskId} → ${to ?? role}`));
        }
      }
    } else {
      // Raw text = task to builder
      const taskId = `ctl-${Date.now()}`;
      sendEvent("task.assign", {
        task_id: taskId,
        from: "ctl@controller",
        role: "builder",
        instructions: trimmed,
      });
      console.log(dim(`[→] ${taskId} → builder`));
    }

    printPrompt(rl);
  });

  rl.on("close", () => { cleanup(); process.exit(0); });
  await new Promise(() => {});
}

// ─── Entry ────────────────────────────────────────────────────────────────────

process.on("SIGINT",  () => { cleanup(); process.exit(0); });
process.on("SIGTERM", () => { cleanup(); process.exit(0); });

const cmd = args[0];
if      (cmd === "status" || cmd === "s") await cmdStatus();
else if (cmd === "logs"   || cmd === "l") await cmdLogs();
else if (cmd === "task"   || cmd === "t") await cmdTask(args.slice(1));
else                                       await cmdInteractive();
