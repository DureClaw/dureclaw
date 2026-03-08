#!/usr/bin/env bun
/**
 * open-agent-harness: Agent Daemon
 *
 * Per-machine daemon that connects to a Phoenix Channel (work:{WORK_KEY}) and:
 *  1. Sends phx_join to register presence
 *  2. Listens for task.assign events
 *  3. Spawns OpenCode CLI subprocess for each task
 *  4. Streams task.progress back to channel
 *  5. Returns task.result (or task.blocked on failure)
 *
 * Implements the real Phoenix 5-tuple WebSocket protocol:
 *   [join_ref, ref, topic, event, payload]
 *
 * Usage:
 *   STATE_SERVER=ws://100.x.x.x:4000 \
 *   AGENT_NAME=builder@gpu \
 *   AGENT_ROLE=builder \
 *   WORK_KEY=LN-20260308-001 \
 *   bun run agent-daemon.ts
 *
 * Env vars:
 *   STATE_SERVER   Base URL of phoenix-server (default: ws://localhost:4000)
 *   AGENT_NAME     Unique name: role@machine (default: orchestrator@local)
 *   AGENT_ROLE     orchestrator|planner|builder|verifier|reviewer
 *   AGENT_MACHINE  machine label (default: hostname)
 *   WORK_KEY       Active Work Key (LN-YYYYMMDD-XXX). Auto-created if omitted.
 *   PROJECT_DIR    Working directory for OpenCode (default: process.cwd())
 *   OPENCODE_BIN   Path to opencode binary (default: opencode)
 */

import { spawn } from "bun";
import { hostname } from "os";

// ─── Config ───────────────────────────────────────────────────────────────────

const STATE_SERVER_RAW = process.env.STATE_SERVER ?? "ws://localhost:4000";
const AGENT_MACHINE = process.env.AGENT_MACHINE ?? hostname();
const AGENT_ROLE = process.env.AGENT_ROLE ?? "orchestrator";
const AGENT_NAME = process.env.AGENT_NAME ?? `${AGENT_ROLE}@${AGENT_MACHINE}`;
const PROJECT_DIR = process.env.PROJECT_DIR ?? process.cwd();
const OPENCODE_BIN = process.env.OPENCODE_BIN ?? "opencode";

// Normalise server URL: always keep ws:// for WS, derive http:// for REST
const WS_BASE = STATE_SERVER_RAW.replace(/^http/, "ws").replace(/\/$/, "");
const HTTP_BASE = STATE_SERVER_RAW.replace(/^ws/, "http").replace(/\/$/, "");

// Phoenix WebSocket path
const WS_URL = `${WS_BASE}/socket/websocket?vsn=2.0.0`;

let WORK_KEY = process.env.WORK_KEY ?? "";

// ─── Phoenix Protocol Types ──────────────────────────────────────────────────

type PhxMsg = [string | null, string | null, string, string, Record<string, unknown>];

type AgentEvent =
  | "agent.hello"
  | "agent.bye"
  | "task.assign"
  | "task.progress"
  | "task.blocked"
  | "task.result"
  | "task.approval_requested"
  | "state.update"
  | "state.get"
  | "mailbox.post"
  | "mailbox.read"
  | "mailbox.message"
  | "mailbox.delivered";

interface TaskPayload {
  task_id: string;
  role?: string;
  instructions: string;
  context?: Record<string, unknown>;
  timeout_ms?: number;
  to?: string;
  from?: string;
}

// ─── Active task tracking ─────────────────────────────────────────────────────

const activeTasks = new Map<string, { abort: AbortController }>();

// ─── Phoenix Channel State ────────────────────────────────────────────────────

let ws: WebSocket | null = null;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let reconnectDelay = 1000;
let heartbeatTimer: ReturnType<typeof setInterval> | null = null;

let refCounter = 0;
function nextRef(): string {
  return String(++refCounter);
}

let joinRef: string | null = null;

// ─── Send helpers ─────────────────────────────────────────────────────────────

function sendRaw(msg: PhxMsg) {
  if (ws?.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(msg));
  }
}

function sendEvent(event: AgentEvent, payload: Record<string, unknown>) {
  const topic = `work:${WORK_KEY}`;
  sendRaw([joinRef, nextRef(), topic, event, payload]);
}

// ─── Heartbeat ───────────────────────────────────────────────────────────────

function startHeartbeat() {
  if (heartbeatTimer) clearInterval(heartbeatTimer);
  heartbeatTimer = setInterval(() => {
    sendRaw([null, nextRef(), "phoenix", "heartbeat", {}]);
  }, 30_000);
}

function stopHeartbeat() {
  if (heartbeatTimer) {
    clearInterval(heartbeatTimer);
    heartbeatTimer = null;
  }
}

// ─── WebSocket connection ─────────────────────────────────────────────────────

function connect() {
  console.log(`[daemon] connecting → ${WS_URL}`);
  ws = new WebSocket(WS_URL);

  ws.onopen = async () => {
    reconnectDelay = 1000;
    console.log(`[daemon] WebSocket connected`);

    if (!WORK_KEY) {
      WORK_KEY = await fetchOrCreateWorkKey();
    }

    joinRef = nextRef();
    const topic = `work:${WORK_KEY}`;
    sendRaw([joinRef, joinRef, topic, "phx_join", {
      agent_name: AGENT_NAME,
      role: AGENT_ROLE,
      machine: AGENT_MACHINE,
    }]);

    console.log(`[daemon] sent phx_join → ${topic}`);
    startHeartbeat();
  };

  ws.onmessage = (ev) => {
    let msg: PhxMsg;
    try {
      msg = JSON.parse(ev.data as string) as PhxMsg;
    } catch {
      return;
    }
    handlePhxMessage(msg);
  };

  ws.onerror = (err) => {
    console.error(`[daemon] ws error`, err);
  };

  ws.onclose = () => {
    stopHeartbeat();
    console.log(`[daemon] disconnected — reconnecting in ${reconnectDelay}ms`);
    reconnectTimer = setTimeout(connect, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 2, 30_000);
  };
}

// ─── Work Key management ──────────────────────────────────────────────────────

async function fetchOrCreateWorkKey(): Promise<string> {
  if (AGENT_ROLE === "orchestrator") {
    const res = await fetch(`${HTTP_BASE}/api/work-keys`, { method: "POST" });
    const { work_key } = await res.json() as { work_key: string };
    console.log(`[daemon] created Work Key: ${work_key}`);
    return work_key;
  }

  console.log(`[daemon] waiting for orchestrator to create a Work Key...`);
  for (let attempt = 1; attempt <= 30; attempt++) {
    try {
      const res = await fetch(`${HTTP_BASE}/api/work-keys/latest`);
      if (res.ok) {
        const { work_key } = await res.json() as { work_key: string };
        console.log(`[daemon] discovered Work Key: ${work_key}`);
        return work_key;
      }
    } catch { /* server not ready yet */ }
    await new Promise(r => setTimeout(r, 2_000));
    if (attempt % 5 === 0) console.log(`[daemon] still waiting... (${attempt * 2}s)`);
  }

  console.warn(`[daemon] no Work Key found after 60s, creating one`);
  const res = await fetch(`${HTTP_BASE}/api/work-keys`, { method: "POST" });
  const { work_key } = await res.json() as { work_key: string };
  return work_key;
}

// ─── Phoenix message handler ──────────────────────────────────────────────────

function handlePhxMessage([msgJoinRef, ref, topic, event, payload]: PhxMsg) {
  const _ = { msgJoinRef, ref };

  switch (event) {
    case "phx_reply": {
      const status = (payload as { status?: string }).status;
      const response = (payload as { response?: unknown }).response;

      if (topic === "phoenix") return;

      if (status === "ok") {
        const workKey = (response as { work_key?: string })?.work_key ?? WORK_KEY;
        console.log(`[channel] joined ${topic} (work_key=${workKey})`);
      } else {
        console.error(`[channel] join failed: ${topic}`, payload);
      }
      break;
    }

    case "phx_error":
      console.error(`[channel] error on ${topic}:`, payload);
      break;

    case "phx_close":
      console.log(`[channel] closed: ${topic}`);
      break;

    case "agent.hello": {
      const p = payload as { agent?: string; role?: string; machine?: string };
      if (p.agent && p.agent !== AGENT_NAME) {
        console.log(`[presence] +${p.agent} (${p.role}@${p.machine}) joined ${topic}`);
      }
      break;
    }

    case "agent.bye": {
      const p = payload as { agent?: string };
      if (p.agent) console.log(`[presence] -${p.agent} left`);
      break;
    }

    case "task.assign": {
      const p = payload as unknown as TaskPayload;
      const to = p.to;
      if (!to || to === AGENT_NAME || to === "broadcast") {
        handleTaskAssign(p);
      }
      break;
    }

    case "task.approval_requested": {
      const p = payload as { task_id?: string; from?: string };
      console.log(`\n⚠️  APPROVAL REQUESTED by ${p.from}`);
      console.log(`Task: ${p.task_id}`);
      console.log(`Details:`, JSON.stringify(payload, null, 2));
      console.log(`\nApprove: curl -X POST ${HTTP_BASE}/api/mailbox/${p.from} -d '{"approved":true}'`);
      break;
    }

    case "mailbox.message":
    case "mailbox.delivered": {
      const p = payload as { count?: number };
      if (event === "mailbox.delivered" && (p.count ?? 0) > 0) {
        console.log(`[mailbox] ${p.count} queued message(s) delivered`);
      }
      break;
    }

    default:
      if (event !== "presence_state" && event !== "presence_diff") {
        console.log(`[event] ${event} on ${topic}`);
      }
  }
}

// ─── Task execution ───────────────────────────────────────────────────────────

async function handleTaskAssign(payload: TaskPayload) {
  const taskId = payload.task_id ?? `task-${Date.now()}`;

  if (payload.role && payload.role !== AGENT_ROLE) {
    console.log(`[task] ${taskId} is for role '${payload.role}', I'm '${AGENT_ROLE}' — ignoring`);
    return;
  }

  console.log(`\n[task] assigned: ${taskId}`);
  console.log(`[task] instructions: ${payload.instructions.slice(0, 120)}...`);

  const abort = new AbortController();
  activeTasks.set(taskId, { abort });

  sendEvent("task.progress", {
    task_id: taskId,
    to: payload.from,
    message: `Starting task as ${AGENT_ROLE}`,
    status: "running",
  });

  try {
    const result = await runOpenCode(taskId, payload, abort.signal);
    activeTasks.delete(taskId);

    sendEvent("task.result", {
      task_id: taskId,
      to: payload.from,
      status: "done",
      output: result.output.slice(-2000),
      exit_code: result.exitCode,
      artifacts: result.artifacts,
    });

    console.log(`[task] ${taskId} completed (exit ${result.exitCode})`);

  } catch (err) {
    activeTasks.delete(taskId);
    const errMsg = err instanceof Error ? err.message : String(err);

    sendEvent("task.blocked", {
      task_id: taskId,
      to: payload.from,
      error: errMsg,
      status: "blocked",
    });

    console.error(`[task] ${taskId} blocked: ${errMsg}`);
  }
}

// ─── OpenCode subprocess runner ───────────────────────────────────────────────

interface OpenCodeResult {
  output: string;
  exitCode: number;
  artifacts: string[];
}

async function runOpenCode(
  taskId: string,
  payload: TaskPayload,
  signal: AbortSignal,
): Promise<OpenCodeResult> {
  const timeout = payload.timeout_ms ?? 300_000;
  const timeoutId = setTimeout(() => {
    if (!signal.aborted) console.log(`[task] ${taskId} timed out`);
  }, timeout);

  const systemPrompt = buildSystemPrompt(payload);

  const proc = spawn({
    cmd: [OPENCODE_BIN, "run", "--format", "default", systemPrompt],
    cwd: PROJECT_DIR,
    stdout: "pipe",
    stderr: "pipe",
    env: {
      ...process.env,
      HARNESS_WORK_KEY: WORK_KEY,
      HARNESS_TASK_ID: taskId,
      HARNESS_AGENT_NAME: AGENT_NAME,
      HARNESS_STATE_SERVER: HTTP_BASE,
    },
  });

  let output = "";
  let lastProgressAt = Date.now();
  const PROGRESS_INTERVAL = 10_000;

  const readOutput = async () => {
    const reader = proc.stdout.getReader();
    const decoder = new TextDecoder();
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        const chunk = decoder.decode(value);
        output += chunk;
        process.stdout.write(chunk);

        const now = Date.now();
        if (now - lastProgressAt > PROGRESS_INTERVAL) {
          lastProgressAt = now;
          sendEvent("task.progress", {
            task_id: taskId,
            message: "Working...",
            output_tail: output.slice(-500),
          });
        }
      }
    } catch { /* stream closed */ }
  };

  const readStderr = async () => {
    const reader = proc.stderr.getReader();
    const decoder = new TextDecoder();
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        const chunk = decoder.decode(value);
        output += chunk;
        process.stderr.write(chunk);
      }
    } catch { /* stream closed */ }
  };

  await Promise.all([readOutput(), readStderr()]);
  const exitCode = await proc.exited;
  clearTimeout(timeoutId);

  const artifacts = output
    .split("\n")
    .filter((l) => l.startsWith("ARTIFACT:"))
    .map((l) => l.replace("ARTIFACT:", "").trim());

  return { output, exitCode, artifacts };
}

// ─── System prompt builder ────────────────────────────────────────────────────

function buildSystemPrompt(payload: TaskPayload): string {
  const roleDescriptions: Record<string, string> = {
    orchestrator: "You are the Orchestrator. You coordinate tasks, break down goals, and delegate to specialists. You do NOT write code directly.",
    planner: "You are the Planner. You analyze requirements, identify risks, and create detailed task plans. Output plans as TASKS.md format.",
    builder: "You are the Builder. You write and modify code. You have full filesystem access. Focus on implementation.",
    verifier: "You are the Verifier. You run tests, linters, and type checkers. Report results clearly. Do NOT modify production code.",
    reviewer: "You are the Reviewer. You read code and provide feedback. You do NOT modify files. Output review as structured markdown.",
  };

  const roleDesc = roleDescriptions[AGENT_ROLE] ?? `You are a ${AGENT_ROLE} agent.`;
  const contextStr = payload.context
    ? `\n\nContext:\n${JSON.stringify(payload.context, null, 2)}`
    : "";

  return [
    `[MULTI-AGENT HARNESS — DISTRIBUTED MODE]`,
    `Agent: ${AGENT_NAME} | Role: ${AGENT_ROLE} | Work Key: ${WORK_KEY}`,
    `Channel: work:${WORK_KEY} @ ${HTTP_BASE}`,
    ``,
    roleDesc,
    ``,
    `You are operating autonomously as part of a multi-agent team. Do NOT ask for user input.`,
    `Do NOT request approval unless the action is irreversible (deployment, deletion, public posting).`,
    `Report blockers by outputting: BLOCKED: <reason>`,
    `Report artifact paths by outputting: ARTIFACT: <path>`,
    ``,
    `Task Instructions:`,
    payload.instructions,
    contextStr,
  ].join("\n");
}

// ─── Graceful shutdown ────────────────────────────────────────────────────────

function shutdown(reason: string) {
  console.log(`\n[daemon] shutting down (${reason})...`);
  stopHeartbeat();

  if (ws?.readyState === WebSocket.OPEN && WORK_KEY) {
    sendEvent("agent.bye", { reason });
    setTimeout(() => {
      ws?.close();
      process.exit(0);
    }, 100);
  } else {
    process.exit(0);
  }
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));

// ─── Entry point ─────────────────────────────────────────────────────────────

console.log(`
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 open-agent-harness | agent-daemon
 Agent : ${AGENT_NAME}
 Role  : ${AGENT_ROLE}
 Server: ${WS_URL}
 Dir   : ${PROJECT_DIR}
 Proto : Phoenix Channel (vsn 2.0.0)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
`);

connect();
