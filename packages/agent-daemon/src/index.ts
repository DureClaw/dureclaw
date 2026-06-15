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
 *   PROJECT_DIR    Working directory for the coding agent (default: process.cwd())
 *   PI_BIN         Path to pi coding-agent binary (default: pi)
 *   OPENCODE_BIN   Path to opencode binary (legacy fallback; default: opencode)
 *   BRAIN_URL      Sub-node: master pi endpoint to delegate AI tasks (keyless node)
 *   BRAIN_TOKEN    Shared fleet token for brain auth (Bearer)
 *   BRAIN_SERVE    Master: "1" to serve local pi as the fleet brain
 *   PI_BRAIN_PORT  Master brain server port (default: 4111)
 */

import { spawnCompat as spawn } from "./spawn-compat.ts";
import { hostname } from "os";
import { execSync } from "child_process";
import { readFileSync, writeFileSync, mkdirSync } from "fs";
import { dirname } from "path";
import { detectCapabilities, detectPreferredModel } from "./capabilities.ts";
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

// ─── Version ─────────────────────────────────────────────────────────────────

const AGENT_VERSION = "0.3.6";

// --version flag
if (process.argv.includes("--version") || process.argv.includes("-v")) {
  console.log(`oah-agent v${AGENT_VERSION}`);
  process.exit(0);
}

// ─── Config ───────────────────────────────────────────────────────────────────

const STATE_SERVER_RAW = process.env.STATE_SERVER ?? "ws://localhost:4000";
const AGENT_MACHINE = process.env.AGENT_MACHINE ?? hostname();
let AGENT_ROLE = process.env.AGENT_ROLE ?? "orchestrator";
let AGENT_NAME = process.env.AGENT_NAME ?? `${AGENT_ROLE}@${AGENT_MACHINE}`;
const PROJECT_DIR = process.env.PROJECT_DIR ?? process.cwd();
const PI_BIN          = process.env.PI_BIN          ?? "pi";
const OPENCODE_BIN    = process.env.OPENCODE_BIN    ?? "opencode";
const ZEROCLAW_BIN    = process.env.ZEROCLAW_BIN    ?? "zeroclaw";
const CLAUDE_BIN      = process.env.CLAUDE_BIN      ?? "claude";
const GEMINI_BIN      = process.env.GEMINI_BIN      ?? "gemini";
const CODEX_BIN       = process.env.CODEX_BIN       ?? "codex";
const AIDER_BIN       = process.env.AIDER_BIN       ?? "aider";
const OLLAMA_BIN      = process.env.OLLAMA_BIN      ?? "ollama";
const OLLAMA_MODEL    = process.env.OLLAMA_MODEL    ?? "gemma4";
// "Local hands, remote brain": a lightweight node (e.g. a container, a Pi) keeps
// the agent loop local but routes inference to a remote ollama over HTTP, so it
// needs no model and no ollama binary of its own. Set AGENT_BACKEND=remote.
const OLLAMA_REMOTE_URL = process.env.OLLAMA_REMOTE_URL ?? "";
// "Brain node" delegation: only the master holds pi auth. Sub-nodes set BRAIN_URL
// to the master's token-gated pi endpoint and delegate whole AI/coding tasks there
// (backend "remote-pi"); their local [SHELL]/sensor work still runs locally. The
// master runs the endpoint with BRAIN_SERVE=1 (its single pi auth serves the fleet).
const BRAIN_URL       = process.env.BRAIN_URL       ?? "";
const BRAIN_TOKEN     = process.env.BRAIN_TOKEN     ?? "";
const BRAIN_SERVE     = process.env.BRAIN_SERVE === "1" || process.env.BRAIN_SERVE === "true";
const BRAIN_PORT      = Number(process.env.PI_BRAIN_PORT ?? 4111);
// "auto" = pick best available from capabilities at runtime
const AGENT_BACKEND   = process.env.AGENT_BACKEND   ?? "auto";
const AGENT_CAPABILITIES = detectCapabilities();
// Brain client: advertise that this node delegates AI tasks to the master's pi.
if (BRAIN_URL && !AGENT_CAPABILITIES.includes("remote-pi")) AGENT_CAPABILITIES.push("remote-pi");
const AGENT_PREFERRED_MODEL = BRAIN_URL ? "pi/remote" : detectPreferredModel();

// Normalise server URL: always keep ws:// for WS, derive http:// for REST
const WS_BASE = STATE_SERVER_RAW.replace(/^http/, "ws").replace(/\/$/, "");
const HTTP_BASE = STATE_SERVER_RAW.replace(/^ws/, "http").replace(/\/$/, "");

// Phoenix WebSocket path — include OAH_SECRET token if set
const OAH_SECRET = process.env.OAH_SECRET ?? "";
const WS_URL = OAH_SECRET
  ? `${WS_BASE}/socket/websocket?vsn=2.0.0&token=${encodeURIComponent(OAH_SECRET)}`
  : `${WS_BASE}/socket/websocket?vsn=2.0.0`;

/** Returns Authorization header if OAH_SECRET is set, else empty object. */
function authHeaders(): Record<string, string> {
  return OAH_SECRET ? { Authorization: `Bearer ${OAH_SECRET}` } : {};
}

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
  /** Required capabilities — agent rejects if not satisfied, server auto-reassigns */
  requires?: string[];
  /** Reassignment retry counter (incremented by server on each reassignment) */
  retry_count?: number;
  /** Backend override (e.g. "ollama"). Falls back to env/auto-detect if unset. */
  backend?: string;
  /** For [EVAL]: delegate grading to this peer agent instead of self-scoring. */
  evaluator?: string;
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
/** Watchdog: if no server message arrives within 90s, force reconnect. */
let heartbeatWatchdog: ReturnType<typeof setTimeout> | null = null;
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

// Watchdog window must comfortably exceed the heartbeat interval so a healthy
// connection (whose heartbeat replies reset the watchdog) never trips it, while
// a dead socket — e.g. after the server restarts behind a Tailscale link that
// doesn't deliver a prompt FIN — is detected in ~35s instead of 90s. A shorter
// window means presence recovers in seconds, not a minute and a half.
const HEARTBEAT_MS = 15_000;
const WATCHDOG_MS = 35_000;

function resetWatchdog() {
  if (heartbeatWatchdog) clearTimeout(heartbeatWatchdog);
  heartbeatWatchdog = setTimeout(() => {
    console.warn(`[daemon] heartbeat watchdog fired — no server message in ${WATCHDOG_MS / 1000}s, reconnecting`);
    ws?.close();
  }, WATCHDOG_MS);
}

function startHeartbeat() {
  if (heartbeatTimer) clearInterval(heartbeatTimer);
  heartbeatTimer = setInterval(() => {
    sendRaw([null, nextRef(), "phoenix", "heartbeat", {}]);
  }, HEARTBEAT_MS);
  resetWatchdog();
}

function stopHeartbeat() {
  if (heartbeatTimer) {
    clearInterval(heartbeatTimer);
    heartbeatTimer = null;
  }
  if (heartbeatWatchdog) {
    clearTimeout(heartbeatWatchdog);
    heartbeatWatchdog = null;
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
      preferred_model: AGENT_PREFERRED_MODEL,
      version: AGENT_VERSION,
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
    // Reset watchdog on any server message (proves connection is alive)
    if (heartbeatWatchdog) resetWatchdog();
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
    const res = await fetch(`${HTTP_BASE}/api/work-keys`, { method: "POST", headers: authHeaders() });
    const { work_key } = await res.json() as { work_key: string };
    console.log(`[daemon] created Work Key: ${work_key}`);
    return work_key;
  }

  // Non-orchestrators: poll for the latest Work Key (orchestrator creates it)
  console.log(`[daemon] waiting for orchestrator to create a Work Key...`);
  for (let attempt = 1; attempt <= 30; attempt++) {
    try {
      const res = await fetch(`${HTTP_BASE}/api/work-keys/latest`, { headers: authHeaders() });
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
  const res = await fetch(`${HTTP_BASE}/api/work-keys`, { method: "POST", headers: authHeaders() });
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

      // A phx_reply is sent for EVERY pushed message (task.progress, task.result,
      // state.update, …) — not only the channel join. Only the reply whose ref
      // matches our join ref is the join ack. Without this guard every push ack
      // was mis-handled as a fresh join: duplicate "[channel] joined" logs and a
      // redundant flushPending() on each progress event.
      if (ref !== joinRef) {
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

    case "task.failed": {
      // Server-side max_retries exhausted — no more reassignment possible
      const p = payload as { task_id?: string; reason?: string; from?: string };
      if (p.task_id) {
        if (activeTasks.has(p.task_id)) {
          const t = activeTasks.get(p.task_id)!;
          t.abort.abort();
          activeTasks.delete(p.task_id);
        }
        console.error(`[task] ❌ ${p.task_id} PERMANENTLY FAILED — reason: ${p.reason ?? "unknown"} (from: ${p.from ?? "server"})`);
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

/**
 * Check if this agent satisfies all required capabilities.
 * An empty or absent requires list means no restrictions.
 */
function satisfiesRequirements(required: string[]): boolean {
  if (!required || required.length === 0) return true;
  return required.every(cap => AGENT_CAPABILITIES.includes(cap));
}

/**
 * Task ids this process has already accepted. A task can arrive via BOTH the
 * channel broadcast and mailbox polling; without this guard each would run the
 * task, doubling execution (and, for failing tasks, feeding a retry storm).
 * Bounded so an unattended long-running daemon doesn't leak memory.
 */
const handledTasks = new Set<string>();

async function handleTaskAssign(payload: TaskPayload) {
  const taskId = payload.task_id ?? `task-${Date.now()}`;

  // Idempotency: ignore a task we've already accepted (duplicate broadcast +
  // mailbox delivery, or a stale mailbox entry re-polled after restart).
  if (handledTasks.has(taskId)) {
    console.log(`[task] ${taskId} already handled — ignoring duplicate`);
    return;
  }
  handledTasks.add(taskId);
  if (handledTasks.size > 5000) {
    for (const t of [...handledTasks].slice(0, 1000)) handledTasks.delete(t);
  }

  // Capability check — reject immediately if we lack required capabilities
  const required = payload.requires;
  if (required && required.length > 0 && !satisfiesRequirements(required)) {
    console.log(`[task] ${taskId} requires [${required.join(", ")}] — I have [${AGENT_CAPABILITIES.join(", ")}] — skipping`);
    sendEvent("task.blocked", {
      task_id: taskId,
      to: payload.from,
      error: `Capability mismatch: requires [${required.join(", ")}]`,
      status: "blocked",
      requires: required,
      retry_count: payload.retry_count ?? 0,
    });
    return;
  }

  // Role check
  if (payload.role && payload.role !== AGENT_ROLE) {
    console.log(`[task] ${taskId} is for role '${payload.role}', I'm '${AGENT_ROLE}' — ignoring`);
    return;
  }

  // [EVAL] marker — run the instruction, then self-score the result so it feeds
  // the eval loop. The marker is stripped before execution.
  const evalMode = payload.instructions.trimStart().toUpperCase().startsWith("[EVAL]");
  if (evalMode) {
    payload.instructions = payload.instructions.replace(/^\s*\[eval\]\s*/i, "");
  }

  // [GRADE] task — peer evaluation delegated by another agent.
  if (payload.instructions.trimStart().toUpperCase().startsWith("[GRADE]")) {
    await handleGradeTask(payload);
    return;
  }

  // Special: [SHELL] task — run shell command directly, no OpenCode/LLM
  if (payload.instructions.trimStart().startsWith("[SHELL]")) {
    await handleShellTask(payload);
    return;
  }

  // Special: [WRITE] task — master creates a file on this node (remote deploy)
  if (payload.instructions.trimStart().toUpperCase().startsWith("[WRITE")) {
    await handleWriteTask(payload);
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
      requires: required ?? [],
      retry_count: payload.retry_count ?? 0,
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

  // Resolve effective backend: task-level override > env > auto-detect
  const taskBackendHint = (payload as Record<string, unknown>).backend as string | undefined;
  const resolvedBackend = (() => {
    const b = taskBackendHint ?? AGENT_BACKEND;
    return b === "auto" ? autoSelectBackend() : b;
  })();

  if (resolvedBackend === "claude" || resolvedBackend === "claude-cli") {
    // ── Reflective executor path: retry loop + stuck detection ───────────────
    const onProgress: ProgressCallback = (msg, tail) => {
      sendEvent("task.progress", { task_id: taskId, to: payload.from, message: msg, output_tail: tail });
    };

    const result = await reflectiveAgent(
      payload.instructions,
      AGENT_ROLE,
      payload.context ?? {},
      onProgress,
    );

    activeTasks.delete(taskId);

    if (result.solved) {
      sendEvent("task.result", {
        task_id: taskId,
        to: payload.from,
        status: "done",
        output: result.output.slice(-2000),
        exit_code: 0,
        artifacts: [],
        token_count: result.tokenCount,
        attempts: result.attempts,
      });
      console.log(`[task] ${taskId} solved via reflective executor (${result.attempts} attempt(s))`);
    } else {
      sendEvent("task.blocked", {
        task_id: taskId,
        to: payload.from,
        error: result.escalated ? "Escalated after max attempts" : "Task not solved",
        status: result.escalated ? "escalate" : "blocked",
        requires: required ?? [],
        retry_count: payload.retry_count ?? 0,
        token_count: result.tokenCount,
      });
      console.error(`[task] ${taskId} blocked by reflective executor (escalated=${result.escalated})`);
    }

  } else {
    // ── Direct subprocess path: opencode / zeroclaw / aider / gemini / etc. ──
    try {
      let result = await runOpenCode(taskId, payload, abort.signal);
      let usedBackend = resolvedBackend;

      // Reliability fallback: if a non-ollama backend failed and a local ollama
      // is available, retry once with ollama (self-contained, no auth/TTY). This
      // rescues headless nodes where e.g. codex fails on a missing-TTY/auth gate.
      if (result.exitCode !== 0 && resolvedBackend !== "ollama" && AGENT_CAPABILITIES.includes("ollama")) {
        console.log(`[backend] ${resolvedBackend} failed (exit ${result.exitCode}) — falling back to ollama`);
        result = await runOpenCode(taskId, { ...payload, backend: "ollama" }, abort.signal);
        usedBackend = "ollama";
      }
      activeTasks.delete(taskId);

      // Eval loop (only [EVAL] tasks). With an evaluator, delegate grading to a
      // peer (agent-to-agent dialog); otherwise self-score.
      let score: number | null = null;
      if (evalMode && result.exitCode === 0) {
        const peers = peerEvaluators(payload);
        if (peers.length > 0) {
          // Agent-to-agent: ask each peer to grade independently; the server
          // averages their votes into a consensus (majority/quorum).
          console.log(`[eval] ${taskId} → ${peers.length} peer(s) grading: ${peers.join(", ")}`);
          for (const peer of peers) {
            sendEvent("task.assign", {
              task_id: `${taskId}-grade-${peer}`,
              to: peer,
              from: AGENT_NAME,
              work_key: WORK_KEY,
              instructions: `[GRADE]\nEVAL_ID: ${taskId}\nGRADED_AGENT: ${AGENT_NAME}\nGOAL:\n${payload.instructions}\nRESULT:\n${result.output.slice(0, 1500)}`,
            });
          }
        } else {
          score = await scoreResult(payload.instructions, result.output, usedBackend);
        }
      }

      sendEvent("task.result", {
        task_id: taskId,
        to: payload.from,
        status: result.exitCode === 0 ? "done" : "blocked",
        output: stripAnsi(result.output).slice(-2000),
        exit_code: result.exitCode,
        artifacts: result.artifacts,
        backend: usedBackend,
        ...(score != null ? { score } : {}),
      });

      console.log(
        `[task] ${taskId} completed via ${usedBackend} (exit ${result.exitCode})` +
          (score != null ? ` — self-score ${score}` : ""),
      );

    } catch (err) {
      activeTasks.delete(taskId);
      const errMsg = err instanceof Error ? err.message : String(err);

      sendEvent("task.blocked", {
        task_id: taskId,
        to: payload.from,
        error: errMsg,
        status: "blocked",
        requires: required ?? [],
        retry_count: payload.retry_count ?? 0,
      });

      console.error(`[task] ${taskId} blocked: ${errMsg}`);
    }
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
    output: stripAnsi(output).trim(),
    exit_code: exitCode,
    sys: sysInfo,
    artifacts: [],
  });
}

/**
 * [WRITE] task — the master creates a file on this node (remote file deploy).
 * Format:
 *   [WRITE] <path>\n<text content...>          — UTF-8 text
 *   [WRITE:b64] <path>\n<base64 content>        — binary (decoded)
 * Parent dirs are created. Pairs with [SHELL] to deploy-and-run on any node.
 */
async function handleWriteTask(payload: TaskPayload) {
  const taskId = payload.task_id ?? `task-${Date.now()}`;
  const raw = payload.instructions.trimStart();
  const isB64 = /^\[WRITE:b64\]/i.test(raw);
  const instr = raw.replace(/^\[WRITE(:b64)?\]\s*/i, "");
  const nl = instr.indexOf("\n");
  const path = (nl < 0 ? instr : instr.slice(0, nl)).trim();
  const body = nl < 0 ? "" : instr.slice(nl + 1);

  let output = "";
  let exitCode = 0;
  try {
    if (!path) throw new Error("no path given — usage: [WRITE] <path>\\n<content>");
    const dir = dirname(path);
    if (dir && dir !== ".") mkdirSync(dir, { recursive: true });
    const data: string | Buffer = isB64 ? Buffer.from(body, "base64") : body;
    writeFileSync(path, data);
    const bytes = isB64 ? (data as Buffer).length : Buffer.byteLength(body);
    output = `wrote ${bytes} bytes → ${path}`;
    console.log(`[write] ${taskId}: ${output}`);
  } catch (err) {
    output = err instanceof Error ? err.message : String(err);
    exitCode = 1;
    console.log(`[write] ${taskId} failed: ${output}`);
  }

  sendEvent("task.result", {
    task_id: taskId,
    to: payload.from ?? "http@controller",
    from: AGENT_NAME,
    role: AGENT_ROLE,
    status: exitCode === 0 ? "done" : "blocked",
    output,
    exit_code: exitCode,
    sys: { machine: AGENT_MACHINE, agent: AGENT_NAME, os: process.platform, path },
    artifacts: [],
  });
}

/**
 * Strip ANSI/VT control sequences. CLIs like `ollama run` emit terminal spinner
 * and cursor escapes that otherwise pollute the captured task output.
 */
function stripAnsi(s: string): string {
  // CSI sequences (incl. private `?` forms), plus stray spinner braille chars.
  // eslint-disable-next-line no-control-regex
  return s.replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, "").replace(/[⠀-⣿]/g, "");
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
    const presRes = await fetch(`${HTTP_BASE}/api/capabilities`, { headers: authHeaders() });
    const builders: Array<{ name: string; capabilities: string[]; role: string; os: string }> =
      presRes.ok ? (await presRes.json() as any).builders ?? [] : [];

    if (builders.length === 0) {
      // Fallback: use presence
      const pres = await fetch(`${HTTP_BASE}/api/presence`, { headers: authHeaders() });
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
        headers: { "Content-Type": "application/json", ...authHeaders() },
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
  // Remote-inference backends: no local subprocess, just an HTTP call.
  const requested = payload.backend ?? AGENT_BACKEND;
  const resolvedReq = requested === "auto" ? autoSelectBackend() : requested;
  if (resolvedReq === "remote") {
    console.log(`[backend] using: remote (${OLLAMA_REMOTE_URL} · ${OLLAMA_MODEL})`);
    return runRemoteOllama(taskId, payload);
  }
  // Brain node: delegate the whole task to the master's authenticated pi.
  if (resolvedReq === "remote-pi") {
    console.log(`[backend] using: remote-pi (brain ${BRAIN_URL})`);
    return runRemoteBrain(taskId, payload);
  }

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
 *   claude-cli > pi > opencode > gemini > codex > aider > zeroclaw
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

    // Pi coding agent (@earendil-works/pi-coding-agent)  — `pi -p "<prompt>"`
    case "pi":
    case "pi-agent":
      return [PI_BIN, "-p", prompt];

    // OpenCode  — `opencode run "<prompt>"` (legacy fallback; pi is now default)
    case "opencode":
      return [OPENCODE_BIN, "run", "--format", "default", prompt];

    // ZeroClaw  — `zeroclaw agent -m "<prompt>"`
    case "zeroclaw":
      return [ZEROCLAW_BIN, "agent", "-m", prompt];

    // Google Gemini CLI  — `gemini -p "<prompt>"`
    case "gemini":
      return [GEMINI_BIN, "-p", prompt];

    // OpenAI Codex CLI  — `codex exec --skip-git-repo-check "<prompt>"`
    // Bare `codex "<prompt>"` launches the interactive TUI, which fails in a
    // headless daemon with "stdin is not a terminal". `exec` is the documented
    // non-interactive mode; --skip-git-repo-check allows running outside a repo.
    case "codex":
      return [CODEX_BIN, "exec", "--skip-git-repo-check", prompt];

    // Aider  — `aider --message "<prompt>" --yes-always --no-git`
    case "aider":
      return [AIDER_BIN, "--message", prompt, "--yes-always", "--no-git"];

    // Ollama local LLM  — `ollama run <model> "<prompt>" --nowordwrap`
    case "ollama":
      return [OLLAMA_BIN, "run", OLLAMA_MODEL, "--nowordwrap", prompt];

    default:
      console.warn(`[backend] unknown backend "${resolved}", falling back to pi`);
      return [PI_BIN, "-p", prompt];
  }
}

/**
 * Pick best available backend from detected capabilities.
 * Local ollama is preferred over codex/aider: on a headless node those launch
 * interactive flows or need cloud auth and fail unattended, whereas ollama is
 * self-contained. Cloud coding CLIs (claude/pi/gemini) still win when
 * present since they're the strongest when authenticated.
 */
function autoSelectBackend(): string {
  // Brain node: if a master pi endpoint is configured, delegate AI tasks there
  // (this node holds no provider auth — it's a keyless hand).
  if (BRAIN_URL) return "remote-pi";
  const priority = ["claude-cli", "pi", "opencode", "gemini", "ollama", "codex", "aider", "zeroclaw"];
  for (const b of priority) {
    if (AGENT_CAPABILITIES.includes(b)) return b;
  }
  return "pi"; // last resort
}

// ─── Remote inference (local hands, remote brain) ──────────────────────────────

/** Call a remote ollama's /api/generate. No local model or binary needed. */
async function remoteOllamaGenerate(prompt: string): Promise<string> {
  const url = OLLAMA_REMOTE_URL.replace(/\/$/, "");
  const res = await fetch(`${url}/api/generate`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ model: OLLAMA_MODEL, prompt, stream: false }),
  });
  if (!res.ok) throw new Error(`remote ollama ${res.status}`);
  const data = (await res.json()) as { response?: string };
  return data.response ?? "";
}

/** Run a task by delegating inference to the remote ollama. */
async function runRemoteOllama(taskId: string, payload: TaskPayload): Promise<OpenCodeResult> {
  try {
    const output = await remoteOllamaGenerate(payload.instructions);
    return { output, exitCode: 0, artifacts: [] };
  } catch (err) {
    console.log(`[task] ${taskId} remote inference failed: ${err}`);
    return { output: err instanceof Error ? err.message : String(err), exitCode: 1, artifacts: [] };
  }
}

/**
 * Brain-node delegation: POST the task to the master's token-gated pi endpoint
 * and return its output. The sub-node holds no provider auth; the master's single
 * authenticated pi does the coding work. See startBrainServer (the master side).
 */
async function runRemoteBrain(taskId: string, payload: TaskPayload): Promise<OpenCodeResult> {
  try {
    const url = BRAIN_URL.replace(/\/$/, "");
    const res = await fetch(`${url}/brain/exec`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(BRAIN_TOKEN ? { Authorization: `Bearer ${BRAIN_TOKEN}` } : {}),
      },
      body: JSON.stringify({ prompt: buildSystemPrompt(payload), task_id: taskId }),
    });
    if (!res.ok) throw new Error(`brain ${res.status}`);
    const data = (await res.json()) as { output?: string; exit_code?: number };
    return { output: data.output ?? "", exitCode: data.exit_code ?? 0, artifacts: [] };
  } catch (err) {
    console.log(`[task] ${taskId} brain delegation failed: ${err}`);
    return { output: err instanceof Error ? err.message : String(err), exitCode: 1, artifacts: [] };
  }
}

/**
 * Master side of brain-node delegation. Exposes the local authenticated pi over
 * a token-gated HTTP endpoint so keyless fleet nodes can delegate AI tasks here.
 * Enable with BRAIN_SERVE=1 (requires BRAIN_TOKEN). Bun-only (the master runs Bun).
 */
function startBrainServer(): void {
  if (!BRAIN_SERVE) return;
  if (!BRAIN_TOKEN) {
    console.warn("[brain] BRAIN_SERVE set but BRAIN_TOKEN empty — refusing to serve");
    return;
  }
  const BunRef = (globalThis as Record<string, unknown>)["Bun"] as
    | { serve: (opts: unknown) => unknown }
    | undefined;
  if (!BunRef?.serve) {
    console.warn("[brain] Bun.serve unavailable (node runtime?) — brain server disabled");
    return;
  }
  BunRef.serve({
    port: BRAIN_PORT,
    hostname: "0.0.0.0",
    idleTimeout: 255,
    async fetch(req: Request): Promise<Response> {
      const url = new URL(req.url);
      if (url.pathname === "/brain/health") {
        return Response.json({ ok: true, backend: autoSelectBackend(), agent: AGENT_NAME });
      }
      if (req.method !== "POST" || url.pathname !== "/brain/exec") {
        return new Response("not found", { status: 404 });
      }
      if ((req.headers.get("authorization") ?? "") !== `Bearer ${BRAIN_TOKEN}`) {
        return new Response("unauthorized", { status: 401 });
      }
      const body = (await req.json().catch(() => ({}))) as { prompt?: string; backend?: string };
      const prompt = body.prompt ?? "";
      if (!prompt) return new Response(JSON.stringify({ error: "no prompt" }), { status: 400 });
      // backend "auto" here resolves to the master's local pi/claude — never remote-pi
      const backend = body.backend && body.backend !== "remote-pi" ? body.backend : "pi";
      console.log(`[brain] exec (${prompt.length} chars) via ${backend}`);
      try {
        const output = await captureCmd(buildAgentCmd(backend, prompt));
        return Response.json({ output, exit_code: 0 });
      } catch (err) {
        return Response.json({ output: String(err), exit_code: 1 }, { status: 500 });
      }
    },
  });
  console.log(`[brain] serving authenticated pi on :${BRAIN_PORT} (token-gated, fleet brain)`);
}

// ─── Self-evaluation (eval loop) ───────────────────────────────────────────────

/** Run a backend command and capture stdout (used for self-scoring). */
async function captureCmd(cmd: string[]): Promise<string> {
  const effectiveDir = (globalThis as Record<string, unknown>)["EFFECTIVE_PROJECT_DIR"] as string ?? PROJECT_DIR;
  const proc = spawn({ cmd, cwd: effectiveDir, stdout: "pipe", stderr: "pipe", env: process.env });
  let out = "";
  const decoder = new TextDecoder();
  const reader = proc.stdout.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      out += decoder.decode(value);
    }
  } catch { /* closed */ }
  await proc.exited;
  return out;
}

/** Extract a 0.0–1.0 score from a model's grading reply. */
function parseScore(s: string): number | null {
  const m = s.match(/(?:^|[^0-9.])([01](?:\.\d+)?|0?\.\d+)/);
  if (!m) return null;
  let v = parseFloat(m[1]!);
  if (Number.isNaN(v)) return null;
  if (v > 1) v = v / 100; // tolerate "85" meaning 0.85
  return Math.max(0, Math.min(1, v));
}

/**
 * Self-score a result against its goal — the "judgment" half of the eval loop.
 * Asks the backend for a single 0.00–1.00 number. Returns null if it can't
 * produce one (the run is still recorded, just unscored).
 */
async function scoreResult(goal: string, output: string, backend: string): Promise<number | null> {
  try {
    const prompt =
      "You are grading a result against a goal. Reply with ONLY one number " +
      "between 0.00 and 1.00 — no words, no explanation — rating how well the " +
      `RESULT achieves the GOAL.\n\nGOAL:\n${goal.slice(0, 500)}\n\nRESULT:\n${output.slice(0, 2000)}\n\nScore (0.00-1.00):`;
    const raw =
      backend === "remote"
        ? await remoteOllamaGenerate(prompt)
        : stripAnsi(await captureCmd(buildAgentCmd(backend, prompt)));
    return parseScore(raw);
  } catch {
    return null;
  }
}

/**
 * [GRADE] task — peer evaluation. Another agent delegated its result here for an
 * INDEPENDENT score (agent-to-agent dialog, no self-grading bias). Parse the
 * goal/result out of the instruction, score it, and reply with the verdict.
 */
/** Parse the evaluator list (comma-separated) for a peer evaluation. */
function peerEvaluators(payload: TaskPayload): string[] {
  if (!payload.evaluator) return [];
  return payload.evaluator.split(",").map((s) => s.trim()).filter(Boolean);
}

async function handleGradeTask(payload: TaskPayload): Promise<void> {
  const taskId = payload.task_id ?? `grade-${Date.now()}`;
  const instr = payload.instructions;
  const evalId = instr.match(/EVAL_ID:\s*(.+)/)?.[1]?.trim();
  const graded = instr.match(/GRADED_AGENT:\s*(.+)/)?.[1]?.trim() ?? "unknown";
  const goal = instr.match(/GOAL:\s*([\s\S]*?)\nRESULT:/)?.[1]?.trim() ?? "";
  const result = instr.match(/RESULT:\s*([\s\S]*)$/)?.[1]?.trim() ?? "";
  const requested = payload.backend ?? AGENT_BACKEND;
  const backend = requested === "auto" ? autoSelectBackend() : requested;
  const score = await scoreResult(goal, result, backend);
  console.log(`[grade] ${AGENT_NAME} independently graded ${graded} → ${score}`);
  sendEvent("task.result", {
    task_id: taskId,
    to: payload.from,
    from: AGENT_NAME,
    status: "done",
    score: score ?? 0,
    graded,
    evaluator: AGENT_NAME,
    eval_id: evalId,
    goal: goal.slice(0, 200),
    output: `peer-graded ${graded}: ${score ?? "n/a"}`,
  });
}

// ─── System prompt builder ────────────────────────────────────────────────────

/** Load ~/.oah/soul.md if it exists — injected into every system prompt */
function loadSoul(): string {
  try {
    const soulPath = `${process.env.HOME ?? "~"}/.oah/soul.md`;
    const fs = require("fs");
    if (fs.existsSync(soulPath)) {
      return fs.readFileSync(soulPath, "utf8").trim();
    }
  } catch { /* ignore */ }
  return "";
}

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

  const soul = loadSoul();
  const soulSection = soul
    ? [``, `## Agent Soul (Machine Identity)`, soul, ``]
    : [];

  return [
    `[MULTI-AGENT HARNESS — DISTRIBUTED MODE]`,
    `Agent: ${AGENT_NAME} | Role: ${AGENT_ROLE} | Work Key: ${WORK_KEY}`,
    `Project Dir: ${(globalThis as Record<string, unknown>)["EFFECTIVE_PROJECT_DIR"] as string ?? PROJECT_DIR}`,
    `Channel: work:${WORK_KEY} @ ${HTTP_BASE}`,
    ``,
    roleDesc,
    ...soulSection,
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
        headers: { "Content-Type": "application/json", ...authHeaders() },
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
      headers: { "Content-Type": "application/json", ...authHeaders() },
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

// ─── Mailbox polling (fallback for missed WebSocket events) ───────────────────
// Polls GET /api/mailbox/{AGENT_NAME} every 5s and processes any queued tasks.
// This ensures tasks are handled even if the agent joined a different work key
// or missed the broadcast.

const seenMailboxTasks = new Set<string>();

async function pollMailbox() {
  try {
    const res = await fetch(`${HTTP_BASE}/api/mailbox/${encodeURIComponent(AGENT_NAME)}`, { headers: authHeaders() });
    if (!res.ok) return;
    const data = await res.json() as { count: number; messages: TaskPayload[] };
    for (const msg of data.messages ?? []) {
      const tid = msg.task_id;
      if (!tid || seenMailboxTasks.has(tid) || activeTasks.has(tid)) continue;
      seenMailboxTasks.add(tid);
      console.log(`[mailbox] received task ${tid} via polling`);
      handleTaskAssign(msg);
    }
  } catch { /* server unreachable, will retry */ }
}

// ─── Entry point ─────────────────────────────────────────────────────────────

console.log(`
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 open-agent-harness | agent-daemon v${AGENT_VERSION}
 Agent : ${AGENT_NAME}
 Role  : ${AGENT_ROLE}
 Server: ${WS_URL}
 Dir   : ${PROJECT_DIR}
 Proto : Phoenix Channel (vsn 2.0.0)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
`);

connect();
startBrainServer();

// Start mailbox polling after a brief delay to let WebSocket settle
setTimeout(() => {
  pollMailbox();
  setInterval(pollMailbox, 5_000);
}, 3_000);

// ─── Metrics Push ────────────────────────────────────────────────────────────

function execSafe(cmd: string): string {
  try { return execSync(cmd, { stdio: "pipe", encoding: "utf8", timeout: 3000 }).trim(); }
  catch { return ""; }
}

function readSafe(path: string): string {
  try { return readFileSync(path, "utf8"); } catch { return ""; }
}

async function collectMetrics(): Promise<Record<string, unknown>> {
  const m: Record<string, unknown> = { ts: Date.now() };

  // ── Ollama ──────────────────────────────────────────────────────────────
  try {
    const r = await fetch("http://localhost:11434/api/ps", { signal: AbortSignal.timeout(2000) });
    if (r.ok) {
      const d = await r.json() as { models?: Array<{ name: string; size_vram?: number }> };
      m.ollama = {
        running: true,
        models: (d.models ?? []).map(x => ({
          name: x.name,
          vram_mb: Math.round((x.size_vram ?? 0) / 1024 / 1024),
        })),
      };
    } else {
      m.ollama = { running: false };
    }
  } catch {
    const pid = execSafe("pgrep -x ollama");
    m.ollama = { running: pid !== "" };
  }

  // ── GPU (nvidia-smi) ─────────────────────────────────────────────────────
  const gpuOut = execSafe(
    "nvidia-smi --query-gpu=name,memory.used,memory.free,memory.total,temperature.gpu,utilization.gpu --format=csv,noheader,nounits"
  );
  if (gpuOut) {
    m.gpu = gpuOut.split("\n").map(line => {
      const [name, used, free, total, temp, util] = line.split(",").map(s => s.trim());
      return { name, used_mb: +used, free_mb: +free, total_mb: +total, temp_c: +temp, util_pct: +util };
    });
  }

  // ── System RAM ───────────────────────────────────────────────────────────
  if (process.platform === "linux") {
    const mem = readSafe("/proc/meminfo");
    const getKb = (key: string) => {
      const m2 = mem.match(new RegExp(`${key}:\\s+(\\d+)`));
      return m2 ? parseInt(m2[1]) * 1024 : 0;
    };
    const total = getKb("MemTotal");
    const avail = getKb("MemAvailable");
    m.ram = { total_mb: Math.round(total / 1024 / 1024), used_mb: Math.round((total - avail) / 1024 / 1024) };
  } else if (process.platform === "darwin") {
    const hw = execSafe("sysctl -n hw.memsize");
    const total = parseInt(hw) || 0;
    const vmstat = execSafe("vm_stat");
    const freePages = +(vmstat.match(/Pages free:\s+(\d+)/)?.[1] ?? 0);
    const used = total - freePages * 4096;
    m.ram = { total_mb: Math.round(total / 1024 / 1024), used_mb: Math.round(used / 1024 / 1024) };
  }

  // ── Key services ─────────────────────────────────────────────────────────
  m.services = {
    docker: execSafe("pgrep -x dockerd") !== "" || execSafe("docker info --format '{{.ServerVersion}}' 2>/dev/null") !== "",
    open_webui: execSafe("pgrep -f open-webui") !== "" || execSafe("docker ps --filter name=open-webui -q 2>/dev/null") !== "",
    litellm: execSafe("pgrep -f litellm") !== "" || execSafe("docker ps --filter name=litellm -q 2>/dev/null") !== "",
  };

  return m;
}

async function pushMetrics() {
  if (!isJoined) return;
  try {
    const metrics = await collectMetrics();
    sendEvent("metrics.update" as AgentEvent, {
      agent: AGENT_NAME,
      machine: AGENT_MACHINE,
      metrics,
    });
  } catch (e) {
    console.warn("[metrics] collection error:", e);
  }
}

// Push metrics 10s after join stabilises, then every 30s
setTimeout(() => {
  pushMetrics();
  setInterval(pushMetrics, 30_000);
}, 10_000);
