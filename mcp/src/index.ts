#!/usr/bin/env bun
/**
 * DureClaw MCP (dureclaw-mcp): 브라우저 손(webclaw)·에이전트 버스 브리지
 *
 * Connects to Phoenix Channel as a named agent and exposes MCP tools
 * so Claude Code / OpenCode / Orca Mobile can participate in the multi-agent harness.
 *
 * Transports:
 *   - Stdio (default): standard I/O for local CLI tools (Claude Code, OpenCode)
 *   - SSE (Remote MCP): HTTP Server-Sent Events for remote orchestrators / Orca Mobile
 *     Usage: `bun run src/index.ts --sse [port]` or `MCP_TRANSPORT=sse MCP_PORT=4001`
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
 *   MCP_TRANSPORT  stdio | sse (default: stdio)
 *   MCP_PORT       port for SSE server (default: 4001)
 *   MCP_HOST       host for SSE server (default: 0.0.0.0)
 */

import http from "node:http";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join, basename } from "node:path";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { SSEServerTransport } from "@modelcontextprotocol/sdk/server/sse.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { hostname } from "os";

// ─── Config ──────────────────────────────────────────────────────────────────

// scripts/sync-version.ts 가 루트 VERSION 에 맞춰 갱신한다
export const MCP_VERSION = "0.5.8";
const LATEST_URL = "https://dureclaw.baryon.ai/latest.json";

const PHOENIX_URL_RAW = process.env.PHOENIX_URL ?? "ws://localhost:4000";
const AGENT_ROLE      = process.env.AGENT_ROLE  ?? "builder";
const AGENT_MACHINE   = hostname();
const AGENT_NAME      = process.env.AGENT_NAME  ?? `${AGENT_ROLE}@${AGENT_MACHINE}`;
export const OAH_SECRET = process.env.OAH_SECRET ?? "";

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

export let WORK_KEY = process.env.WORK_KEY ?? "";

// ─── Phoenix state ───────────────────────────────────────────────────────────

type PhxMsg = [string | null, string | null, string, string, Record<string, unknown>];

let ws: WebSocket | null = null;
let joinRef: string | null = null;
let refCounter = 0;
let heartbeatTimer: ReturnType<typeof setInterval> | null = null;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let reconnectDelay = 1000;
export let channelJoined = false;

// Queue for incoming task.assign events
const taskQueue: Array<Record<string, unknown>> = [];
const taskWaiters: Array<(task: Record<string, unknown>) => void> = [];

// 채널 presence — REST /api/presence 가 등록 안 된 Work Key 를 못 보는 서버에서도 노드를 찾는다
type Metas = { metas?: Array<Record<string, unknown>> };
export const channelPresence = new Map<string, Record<string, unknown>>();

export function applyPresence(map: Map<string, Record<string, unknown>>, state?: Record<string, Metas>, leaves?: Record<string, Metas>) {
  for (const name of Object.keys(leaves ?? {})) map.delete(name);
  for (const [name, v] of Object.entries(state ?? {})) {
    const meta = v?.metas?.[0];
    if (meta) map.set(name, { ...meta, name });
  }
}

// ─── Target resolution (webclaw alias) ───────────────────────────────────────

export type AgentInfo = Record<string, unknown>;

export function capsOf(a: AgentInfo): string[] {
  const c = a.capabilities;
  return Array.isArray(c) ? c.filter((x): x is string => typeof x === "string") : [];
}

export function isWebclaw(a: AgentInfo): boolean {
  return String(a.name ?? "").startsWith("webclaw@") || capsOf(a).includes("webclaw");
}

/** REST presence + channel presence (some servers don't expose every Work Key via REST). */
export async function listAgents(): Promise<AgentInfo[]> {
  const rest = await api("/api/presence")
    .then((r) => r.json() as Promise<{ agents?: AgentInfo[] }>)
    .then((j) => j.agents ?? [])
    .catch(() => [] as AgentInfo[]);
  const byName = new Map<string, AgentInfo>();
  for (const a of rest) byName.set(String(a.name), a);
  for (const [name, a] of channelPresence) if (!byName.has(name)) byName.set(name, { work_key: WORK_KEY, ...a });
  return [...byName.values()].filter((a) => a.name !== AGENT_NAME);
}

/**
 * Resolve `to` to a connected agent name.
 * - exact agent name → 그대로
 * - `webclaw` / `browser` / capability alias → 가장 최근 접속한 webclaw 노드
 * - 그 외 이름 → 그대로 (오프라인이어도 task.assign 은 보낸다)
 */
export async function resolveTarget(to?: string): Promise<{ to: string | null; error?: string; agents: AgentInfo[] }> {
  const agents = await listAgents();
  const wanted = (to ?? "").trim();
  if (!wanted) return { to: null, agents };

  if (agents.some((a) => a.name === wanted)) return { to: wanted, agents };

  const alias = wanted.toLowerCase();
  if (alias === "webclaw" || alias === "browser" || alias === "web") {
    const nodes = agents
      .filter(isWebclaw)
      .sort((a, b) => String(b.online_since ?? b.last_seen ?? "").localeCompare(String(a.online_since ?? a.last_seen ?? "")));
    if (nodes.length > 0) return { to: String(nodes[0].name), agents };
    return {
      to: null,
      agents,
      error: `연결된 webclaw 노드가 없습니다. Windows라면 DureClaw Server 설치 프로그램을 실행하고, 트레이 메뉴에서 '브라우저 손(webclaw) 연결…'을 누른 뒤 Chrome에 확장을 로드하세요. 설정이 비어 있으면 사이드 패널에 '설정 없음'이 표시됩니다.`,
    };
  }
  return { to: wanted, agents };
}

/** task.result / task.blocked 를 기다린다. notices 배열은 notify() 가 채운다. */
export function waitForTaskResult(taskId: string, timeoutMs: number, fromIndex: number): Promise<Notice | null> {
  const started = Date.now();
  return new Promise((resolve) => {
    const tick = () => {
      const found = notices
        .slice(fromIndex)
        .find((n) => (n.event === "task.result" || n.event === "task.blocked") && n.task_id === taskId);
      if (found) return resolve(found);
      if (Date.now() - started >= timeoutMs) return resolve(null);
      setTimeout(tick, 150);
    };
    tick();
  });
}

export function taskOutput(n: Notice | null): string {
  if (!n) return "";
  const p = n.payload ?? {};
  const out = p.output ?? p.summary ?? p.reason ?? "";
  return typeof out === "string" ? out : JSON.stringify(out);
}


// ─── Notifications ───────────────────────────────────────────────────────────

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
export const notices: Notice[] = [];

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

export function notify(n: Notice) {
  notices.push(n);
  if (notices.length > NOTICE_LIMIT) notices.shift();
  log(`${n.title} ${n.body}`);

  const msgPayload = {
    level: n.level,
    logger: "dureclaw",
    data: { title: n.title, body: n.body, event: n.event, task_id: n.task_id, ts: n.ts },
  };

  if (stdioServer) {
    stdioServer.sendLoggingMessage(msgPayload).catch(() => { /* stdio client disconnected */ });
  }

  for (const session of activeSessions.values()) {
    session.server.sendLoggingMessage(msgPayload).catch(() => { /* sse client disconnected */ });
  }
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

export function connect() {
  log(`connecting → ${WS_URL}`);
  try {
    ws = new WebSocket(WS_URL);
  } catch (err) {
    log(`ws connection init error: ${err}`);
    return;
  }

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

export function disconnect() {
  if (heartbeatTimer) { clearInterval(heartbeatTimer); heartbeatTimer = null; }
  if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
  if (ws) {
    ws.onclose = null;
    ws.onerror = null;
    ws.close();
    ws = null;
  }
  channelJoined = false;
}

/** a > b (MAJOR.MINOR.PATCH 숫자 비교, 접미사 무시) */
export function newerThan(a: string, b: string): boolean {
  const p = (v: string) => v.replace(/^v/, "").split(/[.-]/).slice(0, 3).map((x) => parseInt(x, 10) || 0);
  const [x, y] = [p(a), p(b)];
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] > y[i];
  return false;
}

function log(msg: string) {
  process.stderr.write(`[dureclaw-mcp:${AGENT_NAME}] ${msg}\n`);
}

// ─── MCP Server Factory ───────────────────────────────────────────────────────

type DispatchResult = {
  taskId?: string;
  to?: string | null;
  notice?: Notice | null;
  error?: string;
};

async function dispatchAndWait(
  toArg: string | undefined,
  instructions: string,
  role: string | undefined,
  timeoutMs: number,
): Promise<DispatchResult> {
  const resolved = await resolveTarget(toArg);
  if (resolved.error) return { error: resolved.error };

  const taskId = `mcp-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const payload: Record<string, unknown> = {
    task_id: taskId,
    from: AGENT_NAME,
    role: role ?? "builder",
    to: resolved.to,
    instructions,
  };
  const start = notices.length;
  sendEvent("task.assign", payload);
  if (resolved.to) {
    await api(`/api/mailbox/${encodeURIComponent(resolved.to)}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    }).catch(() => {});
  }

  const notice = await waitForTaskResult(taskId, timeoutMs, start);
  if (!notice) {
    return {
      taskId,
      to: resolved.to,
      notice: null,
      error: `시간 초과 (${Math.round(timeoutMs / 1000)}초). task_id=${taskId} · to=${resolved.to ?? "broadcast"} — webclaw 노드가 연결되어 있는지, Chrome 확장이 로드됐는지 확인하세요.`,
    };
  }
  return { taskId, to: resolved.to, notice };
}

export function createMcpServer(): Server {
  const server = new Server(
    { name: "dureclaw", version: MCP_VERSION },
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
        description: "다른 에이전트에게 태스크를 전송한다. to에 'webclaw'를 넣으면 연결된 webclaw 브라우저 노드로 자동 라우팅된다. 예: to='webclaw', instructions='[OPEN] https://www.naver.com'",
        inputSchema: {
          type: "object",
          properties: {
            to:           { type: "string", description: "대상 에이전트 이름 또는 별칭 (예: webclaw, deskclaw@pc, agent1@machine)" },
            instructions: { type: "string", description: "태스크 지시사항 ([OPEN] https://... 같은 webclaw 마커)" },
            role:         { type: "string", description: "대상 역할 (builder/reviewer/executor/...)" },
            task_id:      { type: "string", description: "태스크 ID (생략 시 자동 생성)" },
          },
          required: ["instructions"],
        },
      },
      {
        name: "browser_run",
        description: "webclaw 브라우저에서 여러 줄 마커를 순서대로 실행하고, task.result가 올 때까지 기다려 결과 전체를 돌려준다. 예: instructions='[OPEN] https://www.naver.com\\n[SHOT] webclaw-shots/naver.jpg'",
        inputSchema: {
          type: "object",
          properties: {
            instructions: { type: "string", description: "webclaw 마커 여러 줄 ([OPEN], [DOM], [CLICK], [FILL], [SHOT] 등)" },
            to:           { type: "string", description: "대상 webclaw 노드 (기본: webclaw 별칭 → 가장 최근 노드)" },
            timeout_s:    { type: "number", description: "전체 대기 시간(초). 기본 60, 최대 300" },
          },
          required: ["instructions"],
        },
      },
      {
        name: "browser_screenshot",
        description: "webclaw로 URL을 열고(선택) 스크린샷을 찍어 MCP image content로 바로 돌려준다. 예: url='https://www.naver.com' → 대화에 네이버 화면이 이미지로 표시된다.",
        inputSchema: {
          type: "object",
          properties: {
            url:        { type: "string", description: "먼저 열 URL (생략하면 현재 탭)" },
            to:         { type: "string", description: "대상 webclaw 노드 (기본: webclaw 별칭)" },
            timeout_s:  { type: "number", description: "대기 시간(초). 기본 60, 최대 300" },
          },
          required: [],
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
            since:   { type: "string", description: "이 시각(ISO8601) 이후 알림만" },
            task_id: { type: "string", description: "이 task_id 의 알림만 (send_task 가 돌려준 값)" },
            limit:   { type: "number", description: "최대 개수 (기본 20)" },
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

      case "send_task": {
        const resolved = await resolveTarget(a.to as string | undefined);
        if (resolved.error) return text(resolved.error);

        const taskId = (a.task_id as string) ?? `mcp-${Date.now()}`;
        const payload: Record<string, unknown> = {
          task_id:      taskId,
          from:         AGENT_NAME,
          role:         a.role ?? "builder",
          to:           resolved.to,
          instructions: a.instructions,
        };
        sendEvent("task.assign", payload);

        // Also enqueue to mailbox if `to` specified
        if (resolved.to) {
          await api(`/api/mailbox/${encodeURIComponent(resolved.to)}`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(payload),
          }).catch(() => {});
        }

        const aliasNote = a.to && resolved.to && a.to !== resolved.to ? ` (별칭 '${a.to}' → ${resolved.to})` : "";
        return text(`태스크 전송 완료 (task_id: ${taskId}, to: ${resolved.to ?? "broadcast"})${aliasNote}`);
      }

      case "browser_run": {
        const raw = String(a.instructions ?? "");
        const lines = raw.split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
        if (!lines.length) return text("instructions가 필요합니다. 예: '[OPEN] https://www.naver.com\\n[SHOT] webclaw-shots/naver.jpg'");
        const totalMs = Math.min(300, Math.max(5, Number(a.timeout_s) || 60)) * 1000;
        const started = Date.now();
        const results: Array<Record<string, unknown>> = [];
        let allOk = true;

        for (const line of lines) {
          const remaining = totalMs - (Date.now() - started);
          if (remaining < 1000) {
            results.push({ line, error: "전체 시간 초과" });
            allOk = false;
            break;
          }
          const r = await dispatchAndWait((a.to as string) || "webclaw", line, undefined, remaining);
          if (r.error) {
            results.push({ line, task_id: r.taskId, to: r.to, error: r.error });
            allOk = false;
            break;
          }
          const n = r.notice!;
          const status = String(n.payload.status ?? "done");
          const output = taskOutput(n);
          results.push({ line, task_id: r.taskId, to: r.to, event: n.event, status, output });
          if (n.event === "task.blocked" || status === "failed") { allOk = false; break; }
        }

        return text(JSON.stringify({ ok: allOk, results }, null, 2));
      }

      case "browser_screenshot": {
        const target = (a.to as string) || "webclaw";
        const totalMs = Math.min(300, Math.max(5, Number(a.timeout_s) || 60)) * 1000;
        const started = Date.now();
        const url = String(a.url ?? "").trim();

        if (url) {
          const open = await dispatchAndWait(target, `[OPEN] ${url}`, undefined, totalMs);
          if (open.error) return text(open.error);
          const out = taskOutput(open.notice);
          if (String(open.notice?.payload.status ?? "done") === "failed") {
            return text(`페이지 열기 실패: ${out}`);
          }
        }

        const rel = `webclaw-shots/mcp-${Date.now()}.jpg`;
        const remaining = Math.max(5000, totalMs - (Date.now() - started));
        const shot = await dispatchAndWait(target, `[SHOT] ${rel}`, undefined, remaining);
        if (shot.error) return text(shot.error);

        const out = taskOutput(shot.notice);
        if (String(shot.notice?.payload.status ?? "done") === "failed") {
          return text(`스크린샷 실패: ${out}`);
        }

        const m = out.match(/→\s*(.+?)(?:\s+\(\d+\s+bytes\)|$)/m);
        let file = m?.[1]?.trim() || "";
        if (!file) file = join(homedir(), "Downloads", rel);
        try {
          const buf = await readFile(file);
          const mimeType = /\.png$/i.test(file) ? "image/png" : "image/jpeg";
          return {
            content: [
              { type: "image" as const, data: buf.toString("base64"), mimeType },
              { type: "text" as const, text: `webclaw 스크린샷 (${shot.to ?? target})\n${file}\n${out}` },
            ],
          } as unknown as ReturnType<typeof text>;
        } catch {
          return text(`스크린샷은 저장됐지만 파일을 읽지 못했습니다.\n${out}\n경로: ${file || rel}`);
        }
      }

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

        await api(`/api/task/${a.task_id}/result`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload),
        }).catch(() => {});

        return text(`완료 전송 (task_id: ${a.task_id}, status: ${a.status})`);
      }

      case "get_presence": {
        const rest = await api("/api/presence").then((r) => r.json() as Promise<{ agents?: Array<Record<string, unknown>> }>)
          .then((j) => j.agents ?? []).catch(() => []);
        const byName = new Map<string, Record<string, unknown>>();
        for (const a of rest) byName.set(String(a.name), a);
        for (const [name, a] of channelPresence) if (!byName.has(name)) byName.set(name, { work_key: WORK_KEY, ...a });
        const agents = [...byName.values()].filter((a) => a.name !== AGENT_NAME);
        return text(JSON.stringify({ work_key: WORK_KEY, connected: channelJoined, agents }, null, 2));
      }

      case "read_state": {
        if (!WORK_KEY) return text("WORK_KEY not set");
        const res = await api(`/api/state/${WORK_KEY}`);
        return text(JSON.stringify(await res.json(), null, 2));
      }

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

      case "read_mailbox": {
        const agent = (a.agent as string) || AGENT_NAME;
        const res = await api(`/api/mailbox/${encodeURIComponent(agent)}`);
        return text(JSON.stringify(await res.json(), null, 2));
      }

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

  return server;
}

// ─── Sessions & Transports ───────────────────────────────────────────────────

export interface SseSession {
  sessionId: string;
  transport: SSEServerTransport;
  server: Server;
  createdAt: Date;
}

export const activeSessions = new Map<string, SseSession>();
let stdioServer: Server | null = null;

export function isAuthorized(req: http.IncomingMessage, url: URL, secret: string = OAH_SECRET): boolean {
  if (!secret) return true;
  const tokenParam = url.searchParams.get("token");
  if (tokenParam === secret) return true;
  const authHeader = req.headers["authorization"];
  if (authHeader && authHeader.toLowerCase().startsWith("bearer ")) {
    if (authHeader.slice(7).trim() === secret) return true;
  }
  const customHeader = req.headers["x-oah-secret"];
  if (typeof customHeader === "string" && customHeader === secret) return true;
  return false;
}

export interface SseServerInstance {
  server: http.Server;
  port: number;
  host: string;
  close: () => Promise<void>;
}

export function startSseServer(
  port: number = Number(process.env.MCP_PORT || process.env.PORT) || 4001,
  host: string = process.env.MCP_HOST || process.env.HOST || "0.0.0.0"
): Promise<SseServerInstance> {
  return new Promise((resolve, reject) => {
    const httpServer = http.createServer(async (req, res) => {
      // CORS headers
      res.setHeader("Access-Control-Allow-Origin", "*");
      res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
      res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization, X-OAH-Secret");

      if (req.method === "OPTIONS") {
        res.writeHead(204).end();
        return;
      }

      const hostHeader = req.headers.host || `localhost:${port}`;
      const url = new URL(req.url ?? "/", `http://${hostHeader}`);

      // Health / Status discovery
      if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({
          status: "ok",
          name: "oah-mcp",
          version: MCP_VERSION,
          transport: "sse",
          port,
          sessions: activeSessions.size,
          work_key: WORK_KEY,
          connected: channelJoined,
          endpoints: {
            sse: "/sse",
            message: "/message",
          },
        }, null, 2));
        return;
      }

      // GET /sse (Remote MCP SSE entrypoint)
      if (req.method === "GET" && url.pathname === "/sse") {
        if (!isAuthorized(req, url)) {
          res.writeHead(401, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "Unauthorized: Invalid or missing OAH_SECRET" }));
          return;
        }

        const transport = new SSEServerTransport("/message", res);
        const sessionMcp = createMcpServer();
        const sessionId = transport.sessionId;

        const sessionRecord: SseSession = {
          sessionId,
          transport,
          server: sessionMcp,
          createdAt: new Date(),
        };
        activeSessions.set(sessionId, sessionRecord);
        log(`SSE client connected [session: ${sessionId}] (active: ${activeSessions.size})`);

        const cleanup = () => {
          if (activeSessions.has(sessionId)) {
            activeSessions.delete(sessionId);
            log(`SSE client disconnected [session: ${sessionId}] (active: ${activeSessions.size})`);
          }
        };

        transport.onclose = cleanup;
        req.on("close", cleanup);

        await sessionMcp.connect(transport);
        return;
      }

      // POST /message (Remote MCP JSON-RPC incoming message endpoint)
      if (req.method === "POST" && url.pathname === "/message") {
        const sessionId = url.searchParams.get("sessionId");
        if (!sessionId) {
          res.writeHead(400, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "Missing sessionId query parameter" }));
          return;
        }

        const session = activeSessions.get(sessionId);
        if (!session) {
          res.writeHead(404, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: `Session '${sessionId}' not found or closed` }));
          return;
        }

        if (!isAuthorized(req, url)) {
          res.writeHead(401, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "Unauthorized: Invalid or missing OAH_SECRET" }));
          return;
        }

        await session.transport.handlePostMessage(req, res);
        return;
      }

      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: `Not found: ${req.method} ${url.pathname}` }));
    });

    httpServer.on("error", (err) => {
      log(`HTTP server error: ${err.message}`);
      reject(err);
    });

    httpServer.listen(port, host, () => {
      const addr = httpServer.address();
      const actualPort = typeof addr === "object" && addr ? addr.port : port;
      log(`Remote MCP (SSE) server listening on http://${host}:${actualPort}/sse`);
      resolve({
        server: httpServer,
        port: actualPort,
        host,
        close: () => new Promise<void>((res) => {
          for (const s of activeSessions.values()) {
            s.transport.close().catch(() => {});
          }
          activeSessions.clear();
          httpServer.close(() => res());
        }),
      });
    });
  });
}

export async function startStdioServer(): Promise<Server> {
  const mcp = createMcpServer();
  stdioServer = mcp;
  const transport = new StdioServerTransport();
  await mcp.connect(transport);
  log("MCP server connected via stdio transport");
  return mcp;
}

// ─── CLI Argument Parser ──────────────────────────────────────────────────────

export function parseArgs(args: string[]) {
  let transport: "stdio" | "sse" =
    process.env.MCP_TRANSPORT === "sse" ? "sse" : "stdio";
  let port = Number(process.env.MCP_PORT || process.env.PORT) || 4001;
  let host = process.env.MCP_HOST || process.env.HOST || "0.0.0.0";

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--sse") {
      transport = "sse";
      const next = args[i + 1];
      if (next && !next.startsWith("-") && !isNaN(Number(next))) {
        port = Number(next);
        i++;
      }
    } else if (arg === "--port" || arg === "-p") {
      const next = args[++i];
      if (next && !isNaN(Number(next))) port = Number(next);
    } else if (arg === "--host") {
      const next = args[++i];
      if (next) host = next;
    } else if (arg === "--transport") {
      const next = args[++i];
      if (next === "sse" || next === "stdio") transport = next;
    }
  }
  return { transport, port, host };
}

// ─── Start ───────────────────────────────────────────────────────────────────

if (import.meta.main) {
  connect();
  const { transport, port, host } = parseArgs(process.argv.slice(2));
  if (transport === "sse") {
    await startSseServer(port, host);
  } else {
    await startStdioServer();
  }
}
