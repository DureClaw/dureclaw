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
 *   bun run src/index.ts
 *
 * Env vars:
 *   STATE_SERVER   Base URL of phoenix-server (default: ws://localhost:4000)
 *                  Accepts ws:// or http:// — ws:// used for WebSocket,
 *                  http:// used for REST.
 *   AGENT_NAME     Unique name: role@machine (default: orchestrator@local)
 *   AGENT_ROLE     orchestrator|planner|builder|verifier|reviewer
 *   AGENT_MACHINE  machine label (default: hostname)
 *   WORK_KEY       Active Work Key (LN-YYYYMMDD-XXX). Auto-created if omitted.
 *   PROJECT_DIR    Working directory for OpenCode (default: process.cwd())
 *   OPENCODE_BIN   Path to opencode binary (default: opencode)
 */

import { spawnCompat as spawn } from "./spawn-compat.ts";
import { hostname } from "os";
import { detectCapabilities } from "./capabilities.ts";
import { orchestrateGoal } from "./orchestrator.ts";

// Node.js WebSocket polyfill (Bun has it built-in, Node.js 20 does not)
import WSPolyfill from "ws";
if (typeof (globalThis as any).WebSocket === "undefined") {
  (globalThis as any).WebSocket = WSPolyfill;
}
import {
  reflectiveAgent,
  autonomousPipeline,
  type ProgressCallback,
} from "./reflective_executor.ts";

// ─── Config ───────────────────────────────────────────────────────────────────

const STATE_SERVER_RAW = process.env.STATE_SERVER ?? "ws://localhost:4000";
const AGENT_MACHINE = process.env.AGENT_MACHINE ?? hostname();
let AGENT_ROLE = process.env.AGENT_ROLE ?? "orchestrator";
let AGENT_NAME = process.env.AGENT_NAME ?? `${AGENT_ROLE}@${AGENT_MACHINE}`;
const PROJECT_DIR = process.env.PROJECT_DIR ?? process.cwd();
const OPENCODE_BIN    = process.env.OPENCODE_BIN    ?? "opencode";
const ZEROCLAW_BIN    = process.env.ZEROCLAW_BIN    ?? "zeroclaw";
const CLAUDE_BIN      = process.env.CLAUDE_BIN      ?? "claude";
const GEMINI_BIN      = process.env.GEMINI_BIN      ?? "gemini";
const CODEX_BIN       = process.env.CODEX_BIN       ?? "codex";
const AIDER_BIN       = process.env.AIDER_BIN       ?? "aider";
// "auto" = pick best available from capabilities at runtime
const AGENT_BACKEND   = process.env.AGENT_BACKEND   ?? "auto";
const AGENT_CAPABILITIES = detectCapabilities();

// Normalise server URL: always keep ws:// for WS, derive http:// for REST
const WS_BASE = STATE_SERVER_RAW.replace(/^http/, "ws").replace(/\/$/, "");
const HTTP_BASE = STATE_SERVER_RAW.replace(/^ws/, "http").replace(/\/$/, "");

// Phoenix WebSocket path
const WS_URL = `${WS_BASE}/socket/websocket?vsn=2.0.0`;

let WORK_KEY = process.env.WORK_KEY ?? "";

// ─── Phoenix Protocol Types ──────────────────────────────────────────────────

/**
 * Phoenix WebSocket message (5-tuple):
 *   [join_ref, ref, topic, event, payload]
 *
 * - join_ref: string|null — ref from the join message; null for server pushes
 * - ref:      string|null — per-message unique reference
 * - topic:    string      — channel topic, e.g. "work:LN-20260308-001"
 * - event:    string      — event name
 * - payload:  object      — message body
 */
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

/** Max simultaneous OpenCode subprocesses per daemon. */
const MAX_CONCURRENT_TASKS = 2;

/**
 * Phase orchestration state (for orchestrator role).
 * Tracks Phase 1 task.result collection before dispatching Phase 2.
 */
interface PhaseOrchState {
  phase: 1 | 2;
  phase1TaskIds: Set<string>;
  phase1Results: Map<string, { role: string; output: string }>;
  phase2TaskIds: Set<string>;
  iteration: number;
  maxIterations: number;
  goal: string;
  repoPath: string;
}

const phaseOrch: PhaseOrchState | null = null;
let _phaseOrch: PhaseOrchState | null = phaseOrch;

/** Analysis roles for the 6-agent Phase 1/2 pipeline */
const ANALYSIS_ROLES = {
  phase1: ["code-expert", "mfg-expert", "curriculum-expert"],
  phase2: ["visual-feedback", "executor", "learner-simulator"],
} as const;

/**
 * Results queued while WS was disconnected.
 * Flushed to channel once we successfully re-join.
 */
const pendingResults: Array<{ event: AgentEvent; payload: Record<string, unknown> }> = [];

// ─── Phoenix Channel State ────────────────────────────────────────────────────

let ws: WebSocket | null = null;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let reconnectDelay = 1000;
let heartbeatTimer: ReturnType<typeof setInterval> | null = null;
let isJoined = false;

/** Monotonically increasing ref counter for messages */
let refCounter = 0;
function nextRef(): string {
  return String(++refCounter);
}

/** The join_ref used during phx_join (reused for phx_reply matching) */
let joinRef: string | null = null;

// ─── Send helpers ─────────────────────────────────────────────────────────────

function sendRaw(msg: PhxMsg) {
  if (ws?.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(msg));
  }
}

function sendEvent(event: AgentEvent, payload: Record<string, unknown>) {
  if (ws?.readyState === WebSocket.OPEN && isJoined) {
    const topic = `work:${WORK_KEY}`;
    sendRaw([joinRef, nextRef(), topic, event, payload]);
  } else {
    // WS disconnected — queue for delivery after reconnect
    pendingResults.push({ event, payload });
    console.log(`[daemon] queued ${event} (pending=${pendingResults.length})`);
  }
}

function flushPending() {
  if (pendingResults.length === 0) return;
  console.log(`[daemon] flushing ${pendingResults.length} pending result(s)`);
  while (pendingResults.length > 0) {
    const item = pendingResults.shift()!;
    const topic = `work:${WORK_KEY}`;
    sendRaw([joinRef, nextRef(), topic, item.event, item.payload]);
  }
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

    // If no work key, fetch or create one via REST
    if (!WORK_KEY) {
      WORK_KEY = await fetchOrCreateWorkKey();
    }

    // Join the Phoenix channel
    joinRef = nextRef();
    const topic = `work:${WORK_KEY}`;
    sendRaw([joinRef, joinRef, topic, "phx_join", {
      agent_name: AGENT_NAME,
      role: AGENT_ROLE,
      machine: AGENT_MACHINE,
      capabilities: AGENT_CAPABILITIES,
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
    isJoined = false;
    console.log(`[daemon] disconnected — reconnecting in ${reconnectDelay}ms`);
    reconnectTimer = setTimeout(connect, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 2, 30_000);
  };
}

// ─── Work Key management ──────────────────────────────────────────────────────

async function fetchOrCreateWorkKey(): Promise<string> {
  if (AGENT_ROLE === "orchestrator") {
    // Orchestrator always creates a fresh Work Key
    const res = await fetch(`${HTTP_BASE}/api/work-keys`, { method: "POST" });
    const { work_key } = await res.json() as { work_key: string };
    console.log(`[daemon] created Work Key: ${work_key}`);
    return work_key;
  }

  // Non-orchestrators: poll for the latest Work Key (orchestrator creates it)
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

  // Last resort: create own Work Key
  console.warn(`[daemon] no Work Key found after 60s, creating one`);
  const res = await fetch(`${HTTP_BASE}/api/work-keys`, { method: "POST" });
  const { work_key } = await res.json() as { work_key: string };
  return work_key;
}

// ─── Phoenix message handler ──────────────────────────────────────────────────

function handlePhxMessage([msgJoinRef, ref, topic, event, payload]: PhxMsg) {
  const _ = { msgJoinRef, ref }; // used for pattern matching if needed

  switch (event) {
    // Phoenix system events
    case "phx_reply": {
      const status = (payload as { status?: string }).status;
      const response = (payload as { response?: unknown }).response;

      if (topic === "phoenix") {
        // heartbeat reply — ignore
        return;
      }

      if (status === "ok") {
        const resp = response as { work_key?: string; project?: Record<string, unknown> };
        const workKey = resp.work_key ?? WORK_KEY;
        const project = resp.project ?? {};

        isJoined = true;
        console.log(`[channel] joined ${topic} (work_key=${workKey})`);

        // Override PROJECT_DIR if the work key has one set
        const serverDir = project["project_dir"] as string | undefined;
        if (serverDir && serverDir !== PROJECT_DIR) {
          console.log(`[project] project_dir from server: ${serverDir}`);
          (globalThis as Record<string, unknown>)["EFFECTIVE_PROJECT_DIR"] = serverDir;
        }

        if (project["goal"]) {
          console.log(`[project] goal: ${String(project["goal"]).slice(0, 100)}`);
        }

        if (project["shared_context"] && Object.keys(project["shared_context"] as object).length > 0) {
          console.log(`[project] shared_context keys: ${Object.keys(project["shared_context"] as object).join(", ")}`);
        }

        // Deliver any results that were queued during disconnect
        flushPending();
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

    // Agent presence events
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

    // Role change: dashboard sends agent.setRole targeted at this agent
    case "agent.setRole": {
      const p = payload as { to?: string; role?: string };
      if (p.to && p.to !== AGENT_NAME) break; // not for us
      if (!p.role) break;
      const oldRole = AGENT_ROLE;
      AGENT_ROLE = p.role;
      AGENT_NAME = `${AGENT_ROLE}@${AGENT_MACHINE}`;
      console.log(`[daemon] role changed: ${oldRole} → ${AGENT_ROLE} (rejoining...)`);
      // Leave and rejoin with new role
      const topic = `work:${WORK_KEY}`;
      sendRaw([joinRef, nextRef(), topic, "phx_leave", {}]);
      isJoined = false;
      setTimeout(() => {
        joinRef = nextRef();
        sendRaw([joinRef, joinRef, topic, "phx_join", {
          agent_name: AGENT_NAME,
          role: AGENT_ROLE,
          machine: AGENT_MACHINE,
          capabilities: AGENT_CAPABILITIES,
        }]);
      }, 300);
      break;
    }

    // Task events — only handle if targeted at us or broadcast
    case "task.assign": {
      const p = payload as unknown as TaskPayload;
      const to = p.to;
      if (!to || to === AGENT_NAME || to === "broadcast") {
        handleTaskAssign(p);
      }
      break;
    }

    // Phase orchestration: collect Phase 1 results before dispatching Phase 2
    case "task.result": {
      const p = payload as { task_id?: string; role?: string; output?: string; status?: string };
      if (_phaseOrch && p.task_id) {
        handlePhaseResult(p.task_id, p.role ?? "unknown", p.output ?? "");
      }
      break;
    }

    case "task.cancel": {
      const p = payload as { task_id?: string };
      if (p.task_id && activeTasks.has(p.task_id)) {
        const task = activeTasks.get(p.task_id)!;
        task.abort.abort();
        activeTasks.delete(p.task_id);
        console.log(`[task] ${p.task_id} cancelled`);
        sendEvent("task.result", {
          task_id: p.task_id,
          from: AGENT_NAME,
          status: "cancelled",
          output: "Task cancelled by request",
          exit_code: -1,
        });
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

    // Mailbox delivery
    case "mailbox.message":
    case "mailbox.delivered": {
      const p = payload as { count?: number; messages?: unknown[] };
      if (event === "mailbox.delivered" && (p.count ?? 0) > 0) {
        console.log(`[mailbox] ${p.count} queued message(s) delivered`);
      }
      break;
    }

    default:
      // Log other events for debugging (avoid noise from server broadcasts)
      if (event !== "presence_state" && event !== "presence_diff") {
        console.log(`[event] ${event} on ${topic}`);
      }
  }
}

// ─── Task execution ───────────────────────────────────────────────────────────

async function handleTaskAssign(payload: TaskPayload) {
  const taskId = payload.task_id ?? `task-${Date.now()}`;

  // Role check
  if (payload.role && payload.role !== AGENT_ROLE) {
    console.log(`[task] ${taskId} is for role '${payload.role}', I'm '${AGENT_ROLE}' — ignoring`);
    return;
  }

  // Special: [SHELL] task — run shell command directly, no OpenCode/LLM
  if (payload.instructions.trimStart().startsWith("[SHELL]")) {
    await handleShellTask(payload);
    return;
  }

  // [ORCHESTRATE] task — AI decomposes goal and dispatches subtasks
  if (payload.instructions.trimStart().startsWith("[ORCHESTRATE]")) {
    await handleOrchestrateTask(payload);
    return;
  }

  // Special: analyze_pipeline task (orchestrator only)
  const instrLower = payload.instructions.toLowerCase();
  if (AGENT_ROLE === "orchestrator" && instrLower.startsWith("[analyze_pipeline]")) {
    await handleAnalyzePipeline(payload);
    return;
  }

  // Analysis roles: use reflectiveAgent (auto-picks claude-cli / SDK / OpenAI)
  const analysisRoles = [...ANALYSIS_ROLES.phase1, ...ANALYSIS_ROLES.phase2] as string[];
  if (analysisRoles.includes(AGENT_ROLE)) {
    const onProgress: ProgressCallback = (msg, tail) => {
      sendEvent("task.progress", { task_id: taskId, to: payload.from, message: msg, output_tail: tail });
    };

    const result = await reflectiveAgent(
      payload.instructions,
      AGENT_ROLE,
      payload.context ?? {},
      onProgress,
    );

    sendEvent("task.result", {
      task_id: taskId,
      to: payload.from,
      role: AGENT_ROLE,
      status: result.solved ? "done" : (result.escalated ? "escalate" : "blocked"),
      output: result.output.slice(-2000),
      exit_code: result.solved ? 0 : 1,
      artifacts: [],
      token_count: result.tokenCount,
    });
    return;
  }

  // Concurrency limit — reject if too many tasks are already running
  if (activeTasks.size >= MAX_CONCURRENT_TASKS) {
    console.warn(`[task] ${taskId} rejected — already running ${activeTasks.size}/${MAX_CONCURRENT_TASKS} tasks`);
    sendEvent("task.blocked", {
      task_id: taskId,
      to: payload.from,
      error: `Agent busy (${activeTasks.size} active tasks). Try again later.`,
      status: "blocked",
    });
    return;
  }

  console.log(`\n[task] assigned: ${taskId}`);
  console.log(`[task] instructions: ${payload.instructions.slice(0, 120)}...`);

  const abort = new AbortController();
  activeTasks.set(taskId, { abort });

  // Report start
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

// ─── Shell task handler ───────────────────────────────────────────────────────

async function handleShellTask(payload: TaskPayload) {
  const taskId = payload.task_id ?? `task-${Date.now()}`;
  // Extract command after [SHELL] prefix
  const cmd = payload.instructions.replace(/^\[SHELL\]\s*/i, "").trim();

  console.log(`[shell] ${taskId}: ${cmd.slice(0, 80)}`);

  let output = "";
  let exitCode = 0;

  try {
    const isWindows = process.platform === "win32";
    const shellCmd = isWindows
      ? ["cmd.exe", "/c", cmd]
      : ["sh", "-c", cmd];
    const proc = spawn({
      cmd: shellCmd,
      cwd: PROJECT_DIR,
      stdout: "pipe",
      stderr: "pipe",
    });

    const decoder = new TextDecoder();
    const readStream = async (stream: ReadableStream<Uint8Array>) => {
      const reader = stream.getReader();
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          output += decoder.decode(value);
        }
      } catch { /* closed */ }
    };

    await Promise.all([readStream(proc.stdout), readStream(proc.stderr)]);
    exitCode = await proc.exited;
  } catch (err) {
    output = err instanceof Error ? err.message : String(err);
    exitCode = 1;
  }

  // Inject system info automatically
  const sysInfo = {
    machine: AGENT_MACHINE,
    agent: AGENT_NAME,
    role: AGENT_ROLE,
    cwd: PROJECT_DIR,
    user: process.env.USER ?? process.env.USERNAME ?? "unknown",
    os: process.platform,
  };

  sendEvent("task.result", {
    task_id: taskId,
    to: payload.from ?? "http@controller",
    from: AGENT_NAME,
    role: AGENT_ROLE,
    status: exitCode === 0 ? "done" : "blocked",
    output: output.trim(),
    exit_code: exitCode,
    sys: sysInfo,
    artifacts: [],
  });
}

// ─── Orchestrate task handler ─────────────────────────────────────────────────

async function handleOrchestrateTask(payload: TaskPayload) {
  const taskId = payload.task_id ?? `task-${Date.now()}`;
  const goal = payload.instructions.replace(/^\[ORCHESTRATE\]\s*/i, "").trim();

  console.log(`\n[orchestrate] ${taskId}: ${goal.slice(0, 100)}`);

  const progress = (msg: string) => {
    sendEvent("task.progress", { task_id: taskId, message: msg, status: "running" });
  };

  try {
    // Fetch current builders from server
    progress("Fetching available builders...");
    const presRes = await fetch(`${HTTP_BASE}/api/capabilities`);
    const builders: Array<{ name: string; capabilities: string[]; role: string; os: string }> =
      presRes.ok ? (await presRes.json() as any).builders ?? [] : [];

    if (builders.length === 0) {
      // Fallback: use presence
      const pres = await fetch(`${HTTP_BASE}/api/presence`);
      const data = await pres.json() as any;
      for (const a of (data.agents ?? [])) {
        if (a.role === "builder") {
          builders.push({ name: a.name, capabilities: a.capabilities ?? [], role: a.role, os: a.machine });
        }
      }
    }

    progress(`${builders.length} builder(s) available. Decomposing goal...`);

    const plan = await orchestrateGoal(goal, builders, progress);

    progress(`Plan: ${plan.reasoning}. Dispatching ${plan.subtasks.length} subtask(s)...`);
    console.log(`[orchestrate] plan: ${plan.reasoning}`);

    // Dispatch subtasks
    const dispatchedIds: string[] = [];
    for (const subtask of plan.subtasks) {
      const taskRes = await fetch(`${HTTP_BASE}/api/task`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          work_key: WORK_KEY,
          instructions: subtask.instructions,
          role: subtask.role ?? "builder",
          to: subtask.target_agent ?? undefined,
          depends_on: subtask.depends_on ?? [],
        }),
      });
      const { task_id: dispId } = await taskRes.json() as { task_id: string };
      dispatchedIds.push(dispId);
      console.log(`[orchestrate] dispatched ${dispId}: ${subtask.instructions.slice(0, 60)}`);
    }

    sendEvent("task.result", {
      task_id: taskId,
      from: AGENT_NAME,
      status: "done",
      output: `Orchestrated ${plan.subtasks.length} subtasks.\nReasoning: ${plan.reasoning}\nTask IDs: ${dispatchedIds.join(", ")}`,
      exit_code: 0,
      artifacts: [],
      plan: plan,
      dispatched_tasks: dispatchedIds,
    });

  } catch (err) {
    const errMsg = err instanceof Error ? err.message : String(err);
    sendEvent("task.blocked", {
      task_id: taskId,
      from: AGENT_NAME,
      error: errMsg,
      status: "blocked",
    });
    console.error(`[orchestrate] ${taskId} failed: ${errMsg}`);
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
  const timeout = payload.timeout_ms ?? 300_000; // 5min default
  const timeoutId = setTimeout(() => {
    if (!signal.aborted) console.log(`[task] ${taskId} timed out`);
  }, timeout);

  const systemPrompt = buildSystemPrompt(payload);

  const effectiveDir = (globalThis as Record<string, unknown>)["EFFECTIVE_PROJECT_DIR"] as string ?? PROJECT_DIR;

  // Task-level backend override > env AGENT_BACKEND > auto-detect from capabilities
  const taskBackend = (payload as Record<string, unknown>).backend as string | undefined;
  const agentCmd = buildAgentCmd(taskBackend ?? AGENT_BACKEND, systemPrompt);

  const proc = spawn({
    cmd: agentCmd,
    cwd: effectiveDir,
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

// ─── Multi-backend command builder ───────────────────────────────────────────

/**
 * Priority order for "auto":
 *   claude-cli > opencode > gemini > codex > aider > zeroclaw
 * Each backend's CLI interface is different — map to correct argv.
 */
function buildAgentCmd(backend: string, prompt: string): string[] {
  const resolved = backend === "auto" ? autoSelectBackend() : backend;
  console.log(`[backend] using: ${resolved}`);

  switch (resolved) {
    // Claude Code CLI  — `claude -p "<prompt>"`
    case "claude-cli":
    case "claude":
      return [CLAUDE_BIN, "-p", prompt];

    // OpenCode  — `opencode run "<prompt>"`
    case "opencode":
      return [OPENCODE_BIN, "run", "--format", "default", prompt];

    // ZeroClaw  — `zeroclaw agent -m "<prompt>"`
    case "zeroclaw":
      return [ZEROCLAW_BIN, "agent", "-m", prompt];

    // Google Gemini CLI  — `gemini -p "<prompt>"`
    case "gemini":
      return [GEMINI_BIN, "-p", prompt];

    // OpenAI Codex CLI  — `codex "<prompt>"`
    case "codex":
      return [CODEX_BIN, prompt];

    // Aider  — `aider --message "<prompt>" --yes-always --no-git`
    case "aider":
      return [AIDER_BIN, "--message", prompt, "--yes-always", "--no-git"];

    default:
      console.warn(`[backend] unknown backend "${resolved}", falling back to opencode`);
      return [OPENCODE_BIN, "run", "--format", "default", prompt];
  }
}

/** Pick best available backend from detected capabilities. */
function autoSelectBackend(): string {
  const priority = ["claude-cli", "opencode", "gemini", "codex", "aider", "zeroclaw"];
  for (const b of priority) {
    if (AGENT_CAPABILITIES.includes(b)) return b;
  }
  return "opencode"; // last resort
}

// ─── System prompt builder ────────────────────────────────────────────────────

function buildSystemPrompt(payload: TaskPayload): string {
  const roleDescriptions: Record<string, string> = {
    // Core workflow agents
    orchestrator: "You are the Orchestrator. You coordinate tasks, break down goals, and delegate to specialists. You do NOT write code directly.",
    planner: "You are the Planner. You analyze requirements, identify risks, and create detailed task plans. Output plans as TASKS.md format.",
    builder: "You are the Builder. You write and modify code. You have full filesystem access. Focus on implementation.",
    verifier: "You are the Verifier. You run tests, linters, and type checkers. Report results clearly. Do NOT modify production code.",
    reviewer: "You are the Reviewer. You read code and provide feedback. You do NOT modify files. Output review as structured markdown.",
    // Phase 1 analysis agents
    "code-expert": "You are the Code Expert. Analyze repository structure, ML components, notebook quality, and agenda alignment. Use Qdrant RAG (collection: code_cells) for semantic search instead of loading full files. Output report as .opencode/reports/phase1_code_expert_<ts>.md",
    "mfg-expert": "You are the Manufacturing AI Expert. Evaluate manufacturing domain applicability, standards compliance (ISO 9001, IEC 62443), and edge deployment readiness. Query Qdrant (collection: mfg_standards) for domain knowledge. Output report as .opencode/reports/phase1_mfg_expert_<ts>.md",
    "curriculum-expert": "You are the Curriculum Expert. Assess learning objectives, Bloom's taxonomy coverage, prerequisite sequencing, and pedagogical quality vs reference curricula. Query Qdrant (collections: bloom_taxonomy, curriculum_refs). Output report as .opencode/reports/phase1_curriculum_expert_<ts>.md",
    // Phase 2 evaluation agents
    "visual-feedback": "You are the Visual Feedback Agent. Evaluate notebook visual quality, accessibility, figure labeling, and colorblind safety. Use Phase 1 context to prioritize which notebooks to assess. Output report as .opencode/reports/phase2_visual_feedback_<ts>.md",
    "executor": "You are the Executor. Run Jupyter notebooks, verify cell outputs, check model convergence, and identify runtime errors. Use jupyter nbconvert for execution. Output report as .opencode/reports/phase2_executor_<ts>.md",
    "learner-simulator": "You are the Learner Simulator. Think like an intermediate Python developer with no ML background. Identify confusion points, missing prerequisites, jargon, and predicted drop-off points. Query Qdrant (collection: misconception_db). Output report as .opencode/reports/phase2_learner_simulator_<ts>.md",
  };

  const roleDesc = roleDescriptions[AGENT_ROLE] ?? `You are a ${AGENT_ROLE} agent.`;
  const contextStr = payload.context
    ? `\n\nContext:\n${JSON.stringify(payload.context, null, 2)}`
    : "";

  return [
    `[MULTI-AGENT HARNESS — DISTRIBUTED MODE]`,
    `Agent: ${AGENT_NAME} | Role: ${AGENT_ROLE} | Work Key: ${WORK_KEY}`,
    `Project Dir: ${(globalThis as Record<string, unknown>)["EFFECTIVE_PROJECT_DIR"] as string ?? PROJECT_DIR}`,
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

// ─── Phase Orchestration (orchestrator-only) ─────────────────────────────────

/**
 * Dispatch Phase 1 analysis agents (code-expert, mfg-expert, curriculum-expert)
 * simultaneously via Phoenix Channel task.assign.
 *
 * Alternatively, if ANTHROPIC_API_KEY is set, run inline via Claude SDK
 * when all agents are on the same machine (local mode).
 */
async function dispatchPhase1(goal: string, repoPath: string, maxIterations = 3) {
  const useInlineSDK = !!process.env.ANTHROPIC_API_KEY && process.env.PHASE_INLINE !== "false";

  if (useInlineSDK) {
    // Inline mode: Claude SDK runs agents in-process (single machine)
    console.log(`[phase] running Phase 1 + 2 inline via Claude SDK`);
    const onProgress: ProgressCallback = (msg, tail) => {
      sendEvent("task.progress", { message: msg, output_tail: tail.slice(-200) });
    };

    try {
      const result = await autonomousPipeline(goal, { repo_path: repoPath }, onProgress, maxIterations);

      // Store synthesis in state
      await fetch(`${HTTP_BASE}/api/state/${WORK_KEY}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          pipeline_result: {
            synthesis: result.synthesis,
            success: result.success,
            total_tokens: result.totalTokens,
            iterations: result.iterations,
          },
          status: result.success ? "done" : "escalate",
        }),
      });

      sendEvent("task.result", {
        task_id: `pipeline-${Date.now()}`,
        status: result.success ? "done" : "escalate",
        output: result.synthesis.slice(-2000),
        artifacts: [],
        phase1_count: result.phase1.length,
        phase2_count: result.phase2.length,
        total_tokens: result.totalTokens,
      });
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      console.error(`[phase] pipeline error: ${errMsg}`);
      sendEvent("task.blocked", { error: errMsg, task_id: `pipeline-${Date.now()}` });
    }
    return;
  }

  // Distributed mode: dispatch via Phoenix Channel to remote agents
  console.log(`[phase] dispatching Phase 1 agents via Phoenix Channel`);
  const timestamp = Date.now();

  _phaseOrch = {
    phase: 1,
    phase1TaskIds: new Set(),
    phase1Results: new Map(),
    phase2TaskIds: new Set(),
    iteration: 1,
    maxIterations,
    goal,
    repoPath,
  };

  for (const role of ANALYSIS_ROLES.phase1) {
    const taskId = `phase1-${role}-${timestamp}`;
    _phaseOrch.phase1TaskIds.add(taskId);

    sendEvent("task.assign", {
      task_id: taskId,
      role,
      to: `${role}@broadcast`, // any agent with this role
      from: AGENT_NAME,
      instructions: [
        `[PHASE 1 ANALYSIS] Goal: ${goal}`,
        `Repository: ${repoPath}`,
        `Your role: ${role}`,
        `Work Key: ${WORK_KEY}`,
        `State Server: ${HTTP_BASE}`,
        ``,
        `Perform your specialized analysis and output a structured report.`,
        `Report: .opencode/reports/phase1_${role.replace("-", "_")}_${timestamp}.md`,
        ``,
        `Use [SOLVED] when complete, [BLOCKED: reason] if stuck.`,
      ].join("\n"),
      context: { repo_path: repoPath, goal, phase: 1, iteration: 1 },
      timeout_ms: 600_000, // 10min per analysis agent
    });

    console.log(`[phase1] dispatched ${role} (task: ${taskId})`);
  }
}

/**
 * Called when a task.result arrives for a Phase 1 agent.
 * When all 3 Phase 1 results are collected, dispatches Phase 2.
 */
function handlePhaseResult(taskId: string, role: string, output: string) {
  if (!_phaseOrch) return;

  if (_phaseOrch.phase === 1 && _phaseOrch.phase1TaskIds.has(taskId)) {
    _phaseOrch.phase1Results.set(role, { role, output });
    console.log(`[phase1] received result from ${role} (${_phaseOrch.phase1Results.size}/${_phaseOrch.phase1TaskIds.size})`);

    // Store phase1 result in shared state
    const phase1Partial: Record<string, string> = {};
    _phaseOrch.phase1Results.forEach((v, k) => { phase1Partial[k] = v.output.slice(0, 3000); });
    fetch(`${HTTP_BASE}/api/state/${WORK_KEY}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ phase1_results: phase1Partial }),
    }).catch(e => console.error(`[phase] state update failed: ${e}`));

    // All Phase 1 results collected → dispatch Phase 2
    if (_phaseOrch.phase1Results.size >= _phaseOrch.phase1TaskIds.size) {
      console.log(`[phase1] all results received — dispatching Phase 2`);
      _phaseOrch.phase = 2;
      dispatchPhase2();
    }
  } else if (_phaseOrch.phase === 2 && _phaseOrch.phase2TaskIds.has(taskId)) {
    console.log(`[phase2] received result from ${role}`);
    _phaseOrch.phase2TaskIds.delete(taskId);

    if (_phaseOrch.phase2TaskIds.size === 0) {
      console.log(`[phase2] all results received — pipeline iteration ${_phaseOrch.iteration} complete`);
      // Future: check if iteration needed, or synthesize
      synthesizePipelineResults();
    }
  }
}

/**
 * Dispatch Phase 2 evaluation agents with Phase 1 context.
 */
function dispatchPhase2() {
  if (!_phaseOrch) return;

  const timestamp = Date.now();
  const phase1Context: Record<string, string> = {};
  _phaseOrch.phase1Results.forEach((v, k) => { phase1Context[k] = v.output.slice(0, 3000); });

  for (const role of ANALYSIS_ROLES.phase2) {
    const taskId = `phase2-${role}-${timestamp}`;
    _phaseOrch.phase2TaskIds.add(taskId);

    sendEvent("task.assign", {
      task_id: taskId,
      role,
      to: `${role}@broadcast`,
      from: AGENT_NAME,
      instructions: [
        `[PHASE 2 EVALUATION] Goal: ${_phaseOrch.goal}`,
        `Repository: ${_phaseOrch.repoPath}`,
        `Your role: ${role}`,
        `Iteration: ${_phaseOrch.iteration}/${_phaseOrch.maxIterations}`,
        ``,
        `Phase 1 results are available in your context. Use them to guide your evaluation.`,
        `Report: .opencode/reports/phase2_${role.replace("-", "_")}_${timestamp}.md`,
        ``,
        `Use [SOLVED] when complete, [BLOCKED: reason] if stuck.`,
      ].join("\n"),
      context: {
        repo_path: _phaseOrch.repoPath,
        goal: _phaseOrch.goal,
        phase: 2,
        iteration: _phaseOrch.iteration,
        phase1_results: phase1Context,
      },
      timeout_ms: 600_000,
    });

    console.log(`[phase2] dispatched ${role} (task: ${taskId})`);
  }
}

/**
 * Synthesize final pipeline results using reflective agent (inline).
 * Only called in distributed mode when all Phase 2 results are received.
 */
async function synthesizePipelineResults() {
  if (!_phaseOrch) return;

  console.log(`[pipeline] synthesizing results`);
  sendEvent("task.progress", { message: "Synthesizing pipeline results...", status: "running" });

  const phase1Summary = Array.from(_phaseOrch.phase1Results.values())
    .map(r => `## ${r.role}\n${r.output.slice(0, 2000)}`)
    .join("\n\n");

  const synthesisTask = `Synthesize analysis pipeline results for: ${_phaseOrch.goal}\n\n${phase1Summary}`;

  if (process.env.ANTHROPIC_API_KEY) {
    const onProgress: ProgressCallback = (msg, tail) => {
      sendEvent("task.progress", { message: msg, output_tail: tail.slice(-200) });
    };

    const result = await reflectiveAgent(synthesisTask, "orchestrator", {}, onProgress, 3);

    sendEvent("task.result", {
      task_id: `synthesis-${Date.now()}`,
      status: result.solved ? "done" : "escalate",
      output: result.output,
      escalated: result.escalated,
      total_tokens: result.tokenCount,
    });
  } else {
    // No SDK — emit collected Phase 1 results as final output
    sendEvent("task.result", {
      task_id: `synthesis-${Date.now()}`,
      status: "done",
      output: `Phase 1+2 pipeline complete. Results stored in state.phase1_results.`,
    });
  }

  _phaseOrch = null;
}

/**
 * Start a 6-agent analysis pipeline (orchestrator only).
 * Called when a task.assign has type="analyze_pipeline".
 */
async function handleAnalyzePipeline(payload: TaskPayload) {
  const ctx = payload.context as { repo_path?: string; max_iterations?: number } | undefined;
  const repoPath = ctx?.repo_path ?? PROJECT_DIR;
  const maxIterations = ctx?.max_iterations ?? 3;

  console.log(`\n[pipeline] starting 6-agent analysis`);
  console.log(`[pipeline] goal: ${payload.instructions.slice(0, 80)}`);
  console.log(`[pipeline] repo: ${repoPath}, iterations: ${maxIterations}`);

  await dispatchPhase1(payload.instructions, repoPath, maxIterations);
}

// ─── Graceful shutdown ────────────────────────────────────────────────────────

function shutdown(reason: string) {
  console.log(`\n[daemon] shutting down (${reason})...`);
  stopHeartbeat();

  if (ws?.readyState === WebSocket.OPEN && WORK_KEY) {
    sendEvent("agent.bye", { reason });
    // Give send a tick to flush before closing
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
