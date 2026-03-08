#!/usr/bin/env bun
/**
 * oah-mcp: open-agent-harness MCP Server
 *
 * Connects to Phoenix Channel as a named agent and exposes MCP tools
 * so Claude Code / OpenCode can participate in the multi-agent harness.
 *
 * Tools:
 *   receive_task   — pop next pending task.assign (waits up to 30s)
 *   send_task      — broadcast task.assign to another agent
 *   complete_task  — send task.result back to Phoenix
 *   get_presence   — list connected agents
 *   read_state     — read work key state
 *   write_state    — update work key state
 *   read_mailbox   — read agent mailbox messages
 *   post_message   — post message to agent mailbox
 *
 * Env vars:
 *   PHOENIX_URL    ws://host:4000  (default: ws://localhost:4000)
 *   AGENT_NAME     agent@machine   (default: agent@local)
 *   AGENT_ROLE     orchestrator|builder|...  (default: builder)
 *   WORK_KEY       LN-YYYYMMDD-XXX  (auto-discovered if omitted)
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { hostname } from "os";

// ─── Config ───────────────────────────────────────────────────────────────────

const PHOENIX_URL_RAW = process.env.PHOENIX_URL ?? "ws://localhost:4000";
const AGENT_ROLE      = process.env.AGENT_ROLE  ?? "builder";
const AGENT_MACHINE   = hostname();
const AGENT_NAME      = process.env.AGENT_NAME  ?? `${AGENT_ROLE}@${AGENT_MACHINE}`;

const WS_BASE   = PHOENIX_URL_RAW.replace(/^http/, "ws").replace(/\/$/, "");
const HTTP_BASE = PHOENIX_URL_RAW.replace(/^ws/, "http").replace(/\/$/, "");
const WS_URL    = `${WS_BASE}/socket/websocket?vsn=2.0.0`;

let WORK_KEY = process.env.WORK_KEY ?? "";

// ─── Phoenix state ────────────────────────────────────────────────────────────

type PhxMsg = [string | null, string | null, string, string, Record<string, unknown>];

let ws: WebSocket | null = null;
let joinRef: string | null = null;
let refCounter = 0;
let heartbeatTimer: ReturnType<typeof setInterval> | null = null;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let reconnectDelay = 1000;
let channelJoined = false;

// Queue for incoming task.assign events
const taskQueue: Array<Record<string, unknown>> = [];
const taskWaiters: Array<(task: Record<string, unknown>) => void> = [];

function nextRef() { return String(++refCounter); }

function sendRaw(msg: PhxMsg) {
  if (ws?.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(msg));
  }
}

function sendEvent(event: string, payload: Record<string, unknown>) {
  sendRaw([joinRef, nextRef(), `work:${WORK_KEY}`, event, payload]);
}

// ─── Phoenix connection ───────────────────────────────────────────────────────

async function fetchOrCreateWorkKey(): Promise<string> {
  try {
    const res = await fetch(`${HTTP_BASE}/api/work-keys/latest`);
    if (res.ok) {
      const { work_key } = await res.json() as { work_key: string };
      return work_key;
    }
  } catch { /* server not ready */ }

  const res = await fetch(`${HTTP_BASE}/api/work-keys`, { method: "POST" });
  const { work_key } = await res.json() as { work_key: string };
  return work_key;
}

function handleMessage(msg: PhxMsg) {
  const [, , topic, event, payload] = msg;

  if (event === "phx_reply") {
    if (topic === "phoenix") return; // heartbeat
    const status = (payload as { status?: string }).status;
    if (status === "ok") {
      channelJoined = true;
      log(`joined ${topic}`);
    }
    return;
  }

  if (event === "task.assign") {
    const p = payload as Record<string, unknown>;
    const to = p.to as string | undefined;
    if (!to || to === AGENT_NAME || to === "broadcast") {
      log(`task.assign received: ${p.task_id}`);
      if (taskWaiters.length > 0) {
        taskWaiters.shift()!(p);
      } else {
        taskQueue.push(p);
      }
    }
    return;
  }

  if (event === "agent.hello") {
    const p = payload as { agent?: string };
    if (p.agent && p.agent !== AGENT_NAME) log(`+ ${p.agent} joined`);
    return;
  }

  if (event === "agent.bye") {
    const p = payload as { agent?: string };
    if (p.agent) log(`- ${p.agent} left`);
  }
}

function connect() {
  log(`connecting → ${WS_URL}`);
  ws = new WebSocket(WS_URL);

  ws.onopen = async () => {
    reconnectDelay = 1000;
    log("WebSocket connected");

    if (!WORK_KEY) {
      WORK_KEY = await fetchOrCreateWorkKey();
    }

    joinRef = nextRef();
    sendRaw([joinRef, joinRef, `work:${WORK_KEY}`, "phx_join", {
      agent_name: AGENT_NAME,
      role: AGENT_ROLE,
      machine: AGENT_MACHINE,
    }]);

    if (heartbeatTimer) clearInterval(heartbeatTimer);
    heartbeatTimer = setInterval(() => {
      sendRaw([null, nextRef(), "phoenix", "heartbeat", {}]);
    }, 30_000);
  };

  ws.onmessage = (ev) => {
    try { handleMessage(JSON.parse(ev.data as string) as PhxMsg); } catch { /* */ }
  };

  ws.onerror = () => { log("ws error"); };

  ws.onclose = () => {
    channelJoined = false;
    if (heartbeatTimer) { clearInterval(heartbeatTimer); heartbeatTimer = null; }
    log(`disconnected — retry in ${reconnectDelay}ms`);
    reconnectTimer = setTimeout(connect, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 2, 30_000);
  };
}

function log(msg: string) {
  process.stderr.write(`[oah-mcp:${AGENT_NAME}] ${msg}\n`);
}

// ─── MCP Server ───────────────────────────────────────────────────────────────

const server = new Server(
  { name: "oah", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "receive_task",
      description: "다음 태스크를 수신한다. 최대 30초 대기. task.assign이 없으면 null 반환.",
      inputSchema: { type: "object", properties: {}, required: [] },
    },
    {
      name: "send_task",
      description: "다른 에이전트에게 태스크를 전송한다 (task.assign 브로드캐스트).",
      inputSchema: {
        type: "object",
        properties: {
          to:           { type: "string", description: "대상 에이전트 이름 (예: agent1@machine)" },
          instructions: { type: "string", description: "태스크 지시사항" },
          role:         { type: "string", description: "대상 역할 (builder/reviewer/...)" },
          task_id:      { type: "string", description: "태스크 ID (생략 시 자동 생성)" },
        },
        required: ["instructions"],
      },
    },
    {
      name: "complete_task",
      description: "태스크 완료 결과를 Phoenix에 전송한다.",
      inputSchema: {
        type: "object",
        properties: {
          task_id:   { type: "string", description: "완료할 task_id" },
          status:    { type: "string", enum: ["done", "blocked"], description: "완료 상태" },
          summary:   { type: "string", description: "결과 요약" },
          artifacts: { type: "string", description: "생성 파일 목록 (쉼표 구분)" },
        },
        required: ["task_id", "status", "summary"],
      },
    },
    {
      name: "get_presence",
      description: "현재 Phoenix 채널에 연결된 에이전트 목록을 반환한다.",
      inputSchema: { type: "object", properties: {}, required: [] },
    },
    {
      name: "read_state",
      description: "현재 Work Key의 상태를 읽는다.",
      inputSchema: { type: "object", properties: {}, required: [] },
    },
    {
      name: "write_state",
      description: "Work Key 상태를 업데이트한다.",
      inputSchema: {
        type: "object",
        properties: {
          updates: { type: "string", description: "업데이트할 JSON 문자열 (예: {\"status\":\"running\"})" },
        },
        required: ["updates"],
      },
    },
    {
      name: "read_mailbox",
      description: "에이전트 mailbox의 메시지를 읽고 비운다.",
      inputSchema: {
        type: "object",
        properties: {
          agent: { type: "string", description: "에이전트 이름 (기본: 현재 에이전트)" },
        },
        required: [],
      },
    },
    {
      name: "post_message",
      description: "다른 에이전트의 mailbox에 메시지를 전송한다.",
      inputSchema: {
        type: "object",
        properties: {
          to:      { type: "string", description: "대상 에이전트 이름" },
          type:    { type: "string", description: "이벤트 타입 (예: task.result, task.blocked)" },
          payload: { type: "string", description: "전송할 JSON 페이로드 문자열" },
        },
        required: ["to", "type", "payload"],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const a = (args ?? {}) as Record<string, unknown>;

  const text = (s: string) => ({ content: [{ type: "text" as const, text: s }] });

  switch (name) {
    // ── receive_task ──────────────────────────────────────────────────────────
    case "receive_task": {
      if (taskQueue.length > 0) {
        return text(JSON.stringify(taskQueue.shift(), null, 2));
      }
      // Wait up to 30s for a task
      const task = await new Promise<Record<string, unknown> | null>((resolve) => {
        const timer = setTimeout(() => {
          const idx = taskWaiters.indexOf(resolve as (t: Record<string, unknown>) => void);
          if (idx !== -1) taskWaiters.splice(idx, 1);
          resolve(null);
        }, 30_000);

        taskWaiters.push((t) => { clearTimeout(timer); resolve(t); });
      });
      return text(task ? JSON.stringify(task, null, 2) : "null (no task within 30s)");
    }

    // ── send_task ─────────────────────────────────────────────────────────────
    case "send_task": {
      const taskId = (a.task_id as string) ?? `mcp-${Date.now()}`;
      const payload: Record<string, unknown> = {
        task_id:      taskId,
        from:         AGENT_NAME,
        role:         a.role ?? "builder",
        to:           a.to ?? null,
        instructions: a.instructions,
      };
      sendEvent("task.assign", payload);

      // Also enqueue to mailbox if `to` specified
      if (a.to) {
        await fetch(`${HTTP_BASE}/api/mailbox/${a.to}`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload),
        }).catch(() => {});
      }

      return text(`태스크 전송 완료 (task_id: ${taskId}, to: ${a.to ?? "broadcast"})`);
    }

    // ── complete_task ─────────────────────────────────────────────────────────
    case "complete_task": {
      const payload: Record<string, unknown> = {
        task_id:   a.task_id,
        from:      AGENT_NAME,
        status:    a.status,
        summary:   a.summary,
        artifacts: a.artifacts
          ? (a.artifacts as string).split(",").map((s) => s.trim()).filter(Boolean)
          : [],
      };
      sendEvent("task.result", payload);

      // Also persist via REST for polling
      await fetch(`${HTTP_BASE}/api/task/${a.task_id}/result`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      }).catch(() => {});

      return text(`완료 전송 (task_id: ${a.task_id}, status: ${a.status})`);
    }

    // ── get_presence ──────────────────────────────────────────────────────────
    case "get_presence": {
      const res = await fetch(`${HTTP_BASE}/api/presence`);
      const data = await res.json() as { agents: unknown[] };
      return text(JSON.stringify(data, null, 2));
    }

    // ── read_state ────────────────────────────────────────────────────────────
    case "read_state": {
      if (!WORK_KEY) return text("WORK_KEY not set");
      const res = await fetch(`${HTTP_BASE}/api/state/${WORK_KEY}`);
      return text(JSON.stringify(await res.json(), null, 2));
    }

    // ── write_state ───────────────────────────────────────────────────────────
    case "write_state": {
      if (!WORK_KEY) return text("WORK_KEY not set");
      let updates: unknown;
      try { updates = JSON.parse(a.updates as string); } catch { return text("updates must be valid JSON"); }
      const res = await fetch(`${HTTP_BASE}/api/state/${WORK_KEY}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(updates),
      });
      return text(JSON.stringify(await res.json(), null, 2));
    }

    // ── read_mailbox ──────────────────────────────────────────────────────────
    case "read_mailbox": {
      const agent = (a.agent as string) || AGENT_NAME;
      const res = await fetch(`${HTTP_BASE}/api/mailbox/${encodeURIComponent(agent)}`);
      return text(JSON.stringify(await res.json(), null, 2));
    }

    // ── post_message ──────────────────────────────────────────────────────────
    case "post_message": {
      let payload: unknown;
      try { payload = JSON.parse(a.payload as string); } catch { payload = a.payload; }
      const body = { from: AGENT_NAME, to: a.to, event: a.type, payload, ts: new Date().toISOString() };
      await fetch(`${HTTP_BASE}/api/mailbox/${encodeURIComponent(a.to as string)}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      return text(`메시지 전송 완료 → ${a.to} (type: ${a.type})`);
    }

    default:
      return text(`Unknown tool: ${name}`);
  }
});

// ─── Start ────────────────────────────────────────────────────────────────────

connect();

const transport = new StdioServerTransport();
await server.connect(transport);
