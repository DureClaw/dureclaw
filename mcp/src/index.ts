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
 *   get_notifications — recent bus events (task 완료·실패·막힘, 승인 요청, 노드 접속·이탈)
 *   get_version    — MCP / 서버 / 최신 릴리스 버전
 *
 * Notifications:
 *   위 버스 이벤트를 MCP logging(notifications/message)으로도 클라이언트에 푸시한다.
 *
 * Env vars:
 *   PHOENIX_URL    ws://host:4000  (default: ws://localhost:4000)
 *   AGENT_NAME     agent@machine   (default: agent@local)
 *   AGENT_ROLE     orchestrator|builder|...  (default: builder)
 *   WORK_KEY       LN-YYYYMMDD-XXX  (auto-discovered if omitted)
 *   OAH_SECRET     server secret — WS token + HTTP Bearer (서버에 비밀값이 있으면 필수)
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { hostname } from "os";

// ─── Config ───────────────────────────────────────────────────────────────────

// scripts/sync-version.ts 가 루트 VERSION 에 맞춰 갱신한다
export const MCP_VERSION = "0.4.8";
const LATEST_URL = "https://dureclaw.baryon.ai/latest.json";

const PHOENIX_URL_RAW = process.env.PHOENIX_URL ?? "ws://localhost:4000";
const AGENT_ROLE      = process.env.AGENT_ROLE  ?? "builder";
const AGENT_MACHINE   = hostname();
const AGENT_NAME      = process.env.AGENT_NAME  ?? `${AGENT_ROLE}@${AGENT_MACHINE}`;
const OAH_SECRET      = process.env.OAH_SECRET  ?? "";

const WS_BASE   = PHOENIX_URL_RAW.replace(/^http/, "ws").replace(/\/$/, "");
const HTTP_BASE = PHOENIX_URL_RAW.replace(/^ws/, "http").replace(/\/$/, "");
const WS_URL    = `${WS_BASE}/socket/websocket?vsn=2.0.0`
  + (OAH_SECRET ? `&token=${encodeURIComponent(OAH_SECRET)}` : "");

// 서버 REST 호출 — 비밀값이 있으면 Bearer 를 붙인다
function api(path: string, init: RequestInit = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  if (OAH_SECRET) headers.set("Authorization", `Bearer ${OAH_SECRET}`);
  return fetch(`${HTTP_BASE}${path}`, { ...init, headers });
}

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

// 채널 presence — REST /api/presence 가 등록 안 된 Work Key 를 못 보는 서버에서도 노드를 찾는다
type Metas = { metas?: Array<Record<string, unknown>> };
const channelPresence = new Map<string, Record<string, unknown>>();

export function applyPresence(map: Map<string, Record<string, unknown>>, state?: Record<string, Metas>, leaves?: Record<string, Metas>) {
  for (const name of Object.keys(leaves ?? {})) map.delete(name);
  for (const [name, v] of Object.entries(state ?? {})) {
    const meta = v?.metas?.[0];
    if (meta) map.set(name, { ...meta, name });
  }
}

// ─── Notifications ────────────────────────────────────────────────────────────

export type Notice = {
  ts: string;
  event: string;
  level: "info" | "warning" | "error";
  title: string;
  body: string;
  task_id?: string;
  payload: Record<string, unknown>;
};

const NOTICE_LIMIT = 200;
const notices: Notice[] = [];

const clip = (v: unknown, n = 80) => {
  const s = typeof v === "string" ? v : v == null ? "" : JSON.stringify(v);
  return s.length > n ? `${s.slice(0, n)}…` : s;
};

/** 버스 이벤트 → 알림. 알릴 이벤트가 아니면 null. (공통 사양: docs/PLAN_windows-server-gui-notify-update.md) */
export function toNotice(event: string, p: Record<string, unknown>, self: string): Notice | null {
  const from = (p.from ?? p.agent ?? "?") as string;
  const base = { ts: new Date().toISOString(), event, payload: p, ...(p.task_id ? { task_id: String(p.task_id) } : {}) };
  switch (event) {
    case "task.result": {
      const ok = p.status === "done" || p.status === undefined;
      return { ...base, level: ok ? "info" : "error", title: ok ? "✅ 작업 완료" : "❌ 작업 실패",
        body: `${from}: ${clip(p.summary ?? p.output ?? p.task_id)}` };
    }
    case "task.blocked":
      return { ...base, level: "warning", title: "⏸ 작업 막힘", body: `${from}: ${clip(p.reason ?? p.summary ?? p.task_id)}` };
    case "task.approval_requested":
      return { ...base, level: "warning", title: "🙋 승인 요청", body: `${from}: ${clip(p.instructions ?? p.reason ?? p.task_id)}` };
    case "mailbox.message":
      return { ...base, level: "info", title: "✉ 메일박스", body: `${from}: ${clip(p.event ?? p.type ?? p.payload)}` };
    case "agent.hello":
    case "agent.bye":
      if (from === self) return null;
      return { ...base, level: "info", title: event === "agent.hello" ? "🟢 노드 접속" : "⚪ 노드 이탈",
        body: `${from}${p.role ? ` (${p.role})` : ""}` };
    default:
      return null;
  }
}

function notify(n: Notice) {
  notices.push(n);
  if (notices.length > NOTICE_LIMIT) notices.shift();
  log(`${n.title} ${n.body}`);
  server.sendLoggingMessage({ level: n.level, logger: "dureclaw", data: { title: n.title, body: n.body, event: n.event, task_id: n.task_id, ts: n.ts } })
    .catch(() => { /* 클라이언트 미연결 */ });
}

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
    const res = await api("/api/work-keys/latest");
    if (res.ok) {
      const { work_key } = await res.json() as { work_key: string };
      return work_key;
    }
  } catch { /* server not ready */ }

  const res = await api("/api/work-keys", { method: "POST" });
  const { work_key } = await res.json() as { work_key: string };
  return work_key;
}

function handleMessage(msg: PhxMsg) {
  const [, , topic, event, payload] = msg;

  if (event === "phx_reply") {
    if (topic === "phoenix") return; // heartbeat
    const { status, response } = payload as { status?: string; response?: { presences?: Record<string, Metas> } };
    if (status === "ok" && msg[1] === joinRef) {
      channelJoined = true;
      channelPresence.clear();
      applyPresence(channelPresence, response?.presences);
      log(`joined ${topic} (${channelPresence.size} online)`);
    }
    return;
  }

  if (event === "presence_state") {
    channelPresence.clear();
    applyPresence(channelPresence, payload as Record<string, Metas>);
    return;
  }
  if (event === "presence_diff") {
    const d = payload as { joins?: Record<string, Metas>; leaves?: Record<string, Metas> };
    applyPresence(channelPresence, d.joins, d.leaves);
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

  const n = toNotice(event, payload, AGENT_NAME);
  if (n) notify(n);
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
      version: MCP_VERSION,
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

/** a > b (MAJOR.MINOR.PATCH 숫자 비교, 접미사 무시) */
export function newerThan(a: string, b: string): boolean {
  const p = (v: string) => v.replace(/^v/, "").split(/[.-]/).slice(0, 3).map((x) => parseInt(x, 10) || 0);
  const [x, y] = [p(a), p(b)];
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] > y[i];
  return false;
}

function log(msg: string) {
  process.stderr.write(`[oah-mcp:${AGENT_NAME}] ${msg}\n`);
}

// ─── MCP Server ───────────────────────────────────────────────────────────────

const server = new Server(
  { name: "oah", version: MCP_VERSION },
  { capabilities: { tools: {}, logging: {} } }
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
    {
      name: "get_notifications",
      description: "최근 버스 알림(작업 완료·실패·막힘, 승인 요청, 메일박스, 노드 접속·이탈)을 반환한다.",
      inputSchema: {
        type: "object",
        properties: {
          since: { type: "string", description: "이 시각(ISO8601) 이후 알림만" },
          task_id: { type: "string", description: "이 task_id 의 알림만 (send_task 가 돌려준 값)" },
          limit: { type: "number", description: "최대 개수 (기본 20)" },
        },
        required: [],
      },
    },
    {
      name: "get_version",
      description: "MCP·서버·최신 릴리스 버전을 반환하고 업데이트가 필요한지 알려준다.",
      inputSchema: { type: "object", properties: {}, required: [] },
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
        await api(`/api/mailbox/${encodeURIComponent(a.to as string)}`, {
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
      await api(`/api/task/${a.task_id}/result`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      }).catch(() => {});

      return text(`완료 전송 (task_id: ${a.task_id}, status: ${a.status})`);
    }

    // ── get_presence ──────────────────────────────────────────────────────────
    case "get_presence": {
      // REST(서버에 등록된 Work Key 전체) + 이 채널의 presence 를 합친다
      const rest = await api("/api/presence").then((r) => r.json() as Promise<{ agents?: Array<Record<string, unknown>> }>)
        .then((j) => j.agents ?? []).catch(() => []);
      const byName = new Map<string, Record<string, unknown>>();
      for (const a of rest) byName.set(String(a.name), a);
      for (const [name, a] of channelPresence) if (!byName.has(name)) byName.set(name, { work_key: WORK_KEY, ...a });
      const agents = [...byName.values()].filter((a) => a.name !== AGENT_NAME);
      return text(JSON.stringify({ work_key: WORK_KEY, connected: channelJoined, agents }, null, 2));
    }

    // ── read_state ────────────────────────────────────────────────────────────
    case "read_state": {
      if (!WORK_KEY) return text("WORK_KEY not set");
      const res = await api(`/api/state/${WORK_KEY}`);
      return text(JSON.stringify(await res.json(), null, 2));
    }

    // ── write_state ───────────────────────────────────────────────────────────
    case "write_state": {
      if (!WORK_KEY) return text("WORK_KEY not set");
      let updates: unknown;
      try { updates = JSON.parse(a.updates as string); } catch { return text("updates must be valid JSON"); }
      const res = await api(`/api/state/${WORK_KEY}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(updates),
      });
      return text(JSON.stringify(await res.json(), null, 2));
    }

    // ── read_mailbox ──────────────────────────────────────────────────────────
    case "read_mailbox": {
      const agent = (a.agent as string) || AGENT_NAME;
      const res = await api(`/api/mailbox/${encodeURIComponent(agent)}`);
      return text(JSON.stringify(await res.json(), null, 2));
    }

    // ── post_message ──────────────────────────────────────────────────────────
    case "post_message": {
      let payload: unknown;
      try { payload = JSON.parse(a.payload as string); } catch { payload = a.payload; }
      const body = { from: AGENT_NAME, to: a.to, event: a.type, payload, ts: new Date().toISOString() };
      await api(`/api/mailbox/${encodeURIComponent(a.to as string)}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      return text(`메시지 전송 완료 → ${a.to} (type: ${a.type})`);
    }

    // ── get_notifications ─────────────────────────────────────────────────────
    case "get_notifications": {
      const since = a.since ? Date.parse(a.since as string) : NaN;
      const limit = Number(a.limit) > 0 ? Number(a.limit) : 20;
      const list = notices
        .filter((n) => Number.isNaN(since) || Date.parse(n.ts) > since)
        .filter((n) => !a.task_id || n.task_id === a.task_id)
        .slice(-limit)
        .map(({ payload: _p, ...n }) => n);
      return text(list.length ? JSON.stringify(list, null, 2) : "알림 없음");
    }

    // ── get_version ───────────────────────────────────────────────────────────
    case "get_version": {
      const serverVersion = await api("/api/health").then((r) => r.json() as Promise<{ version?: string }>)
        .then((j) => j.version ?? null).catch(() => null);
      const latest = await fetch(LATEST_URL).then((r) => r.ok ? r.json() as Promise<{ version?: string }> : null)
        .then((j) => j?.version ?? null).catch(() => null);
      const outdated = (v: string | null) => !!(latest && v && newerThan(latest, v));
      return text(JSON.stringify({
        mcp: MCP_VERSION,
        server: serverVersion,
        latest,
        mcp_update: outdated(MCP_VERSION) ? "bash <(curl -fsSL https://dureclaw.baryon.ai/mcp)" : null,
        server_update: outdated(serverVersion) ? "https://github.com/DureClaw/homepage/releases/latest" : null,
      }, null, 2));
    }

    default:
      return text(`Unknown tool: ${name}`);
  }
});

// ─── Start ────────────────────────────────────────────────────────────────────

if (import.meta.main) {
  connect();
  const transport = new StdioServerTransport();
  await server.connect(transport);
}
