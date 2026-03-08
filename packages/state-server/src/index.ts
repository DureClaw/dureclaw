/**
 * open-agent-harness: Distributed State Server
 *
 * Replaces file-based state.json + mailbox/*.json with:
 * - HTTP REST API  → state CRUD
 * - WebSocket      → real-time channel (Phoenix-compatible protocol)
 * - Presence       → which agents are online
 *
 * Work Key format: LN-YYYYMMDD-XXX (from NAS multi-agent-framework PRD)
 *
 * Deploy: NAS (24/7) or any machine reachable via Tailscale
 * Port: 4000 (same as Phoenix default)
 */

import { type ServerWebSocket } from "bun";

// ─── Types ────────────────────────────────────────────────────────────────────

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
  | "mailbox.read";

interface ChannelMessage {
  work_key: string;       // LN-YYYYMMDD-XXX
  task_id?: string;
  from: string;           // agent-name@machine
  to?: string;            // target agent or "broadcast"
  event: AgentEvent;
  payload: unknown;
  ts: string;             // ISO-8601
}

interface AgentPresence {
  name: string;           // e.g. "orchestrator@mac"
  role: string;           // orchestrator|planner|builder|verifier|reviewer
  machine: string;        // mac|gpu|nas|...
  ip?: string;
  work_key?: string;
  online_since: string;
  ws: ServerWebSocket<AgentMeta>;
}

interface AgentMeta {
  name: string;
  role: string;
  machine: string;
  work_key?: string;
}

// ─── In-memory store ──────────────────────────────────────────────────────────

/** state per work_key */
const stateStore = new Map<string, Record<string, unknown>>();

/** mailbox: agent_name → queue of messages */
const mailboxStore = new Map<string, ChannelMessage[]>();

/** presence: agent_name → AgentPresence */
const presence = new Map<string, AgentPresence>();

/** channel subscriptions: work_key → Set of websockets */
const channels = new Map<string, Set<ServerWebSocket<AgentMeta>>>();

// ─── Work Key generator ───────────────────────────────────────────────────────

function generateWorkKey(): string {
  const now = new Date();
  const date = now.toISOString().slice(0, 10).replace(/-/g, "");
  const existing = [...stateStore.keys()].filter((k) => k.startsWith(`LN-${date}`));
  const seq = String(existing.length + 1).padStart(3, "0");
  return `LN-${date}-${seq}`;
}

// ─── Channel broadcast ────────────────────────────────────────────────────────

function broadcast(workKey: string, msg: ChannelMessage, exclude?: ServerWebSocket<AgentMeta>) {
  const subs = channels.get(workKey);
  if (!subs) return;
  const data = JSON.stringify(msg);
  for (const ws of subs) {
    if (ws !== exclude && ws.readyState === WebSocket.OPEN) {
      ws.send(data);
    }
  }
}

function sendTo(agentName: string, msg: ChannelMessage) {
  const p = presence.get(agentName);
  if (p && p.ws.readyState === WebSocket.OPEN) {
    p.ws.send(JSON.stringify(msg));
  } else {
    // Agent offline → queue in mailbox
    enqueueMailbox(agentName, msg);
  }
}

function enqueueMailbox(agentName: string, msg: ChannelMessage) {
  if (!mailboxStore.has(agentName)) mailboxStore.set(agentName, []);
  mailboxStore.get(agentName)!.push(msg);
}

// ─── WebSocket message handler ────────────────────────────────────────────────

function handleWsMessage(ws: ServerWebSocket<AgentMeta>, raw: string) {
  let msg: ChannelMessage;
  try {
    msg = JSON.parse(raw) as ChannelMessage;
  } catch {
    ws.send(JSON.stringify({ error: "invalid JSON" }));
    return;
  }

  const { work_key, event, from, to, payload } = msg;

  switch (event) {
    case "agent.hello": {
      // Register presence
      const meta = payload as { role: string; machine: string; ip?: string };
      presence.set(from, {
        name: from,
        role: meta.role ?? "unknown",
        machine: meta.machine ?? "unknown",
        ip: meta.ip,
        work_key,
        online_since: new Date().toISOString(),
        ws,
      });
      ws.data.name = from;
      ws.data.role = meta.role;
      ws.data.machine = meta.machine;
      ws.data.work_key = work_key;

      // Join channel
      if (!channels.has(work_key)) channels.set(work_key, new Set());
      channels.get(work_key)!.add(ws);

      // Deliver queued mailbox
      const queued = mailboxStore.get(from) ?? [];
      mailboxStore.delete(from);
      for (const qm of queued) ws.send(JSON.stringify(qm));

      // Broadcast presence update
      broadcast(work_key, {
        work_key,
        from: "server",
        event: "agent.hello",
        payload: { agent: from, role: meta.role, machine: meta.machine, queued_msgs: queued.length },
        ts: new Date().toISOString(),
      }, ws);

      console.log(`[presence] +${from} (${meta.role}@${meta.machine}) → ${work_key}`);
      ws.send(JSON.stringify({ ok: true, event: "agent.hello", work_key, queued: queued.length }));
      break;
    }

    case "task.assign":
    case "task.progress":
    case "task.blocked":
    case "task.result":
    case "task.approval_requested": {
      // Route to target agent or broadcast to channel
      if (to && to !== "broadcast") {
        sendTo(to, msg);
      } else {
        broadcast(work_key, msg, ws);
      }
      console.log(`[${event}] ${from} → ${to ?? "channel:"+work_key}`);
      break;
    }

    case "state.update": {
      const updates = payload as Record<string, unknown>;
      const current = stateStore.get(work_key) ?? {};
      stateStore.set(work_key, { ...current, ...updates, updated_at: new Date().toISOString() });
      ws.send(JSON.stringify({ ok: true, state: stateStore.get(work_key) }));
      break;
    }

    case "state.get": {
      ws.send(JSON.stringify({ ok: true, state: stateStore.get(work_key) ?? {} }));
      break;
    }

    case "mailbox.post": {
      const target = to ?? "";
      if (!target) { ws.send(JSON.stringify({ error: "missing 'to'" })); return; }
      sendTo(target, msg);
      ws.send(JSON.stringify({ ok: true, delivered: presence.has(target) }));
      break;
    }

    case "mailbox.read": {
      const msgs = mailboxStore.get(from) ?? [];
      mailboxStore.delete(from);
      ws.send(JSON.stringify({ ok: true, messages: msgs, count: msgs.length }));
      break;
    }
  }
}

// ─── HTTP + WebSocket Server ──────────────────────────────────────────────────

const server = Bun.serve<AgentMeta>({
  port: Number(process.env.PORT ?? 4000),
  hostname: process.env.HOST ?? "0.0.0.0",

  fetch(req, server) {
    const url = new URL(req.url);

    // WebSocket upgrade
    if (req.headers.get("upgrade") === "websocket") {
      const upgraded = server.upgrade(req, {
        data: { name: "", role: "", machine: "", work_key: "" },
      });
      return upgraded ? undefined : new Response("WebSocket upgrade failed", { status: 400 });
    }

    // ── REST API ───────────────────────────────────────────────────────────

    // GET /health
    if (url.pathname === "/health") {
      return Response.json({ ok: true, agents: presence.size, channels: channels.size });
    }

    // GET /presence
    if (url.pathname === "/presence") {
      const agents = [...presence.values()].map((p) => ({
        name: p.name, role: p.role, machine: p.machine,
        work_key: p.work_key, online_since: p.online_since,
      }));
      return Response.json({ agents });
    }

    // POST /work-key  → generate new Work Key
    if (url.pathname === "/work-key" && req.method === "POST") {
      const wk = generateWorkKey();
      stateStore.set(wk, {
        work_key: wk, status: "created", goal: null,
        loop_count: 0, tasks: [], created_at: new Date().toISOString(),
      });
      return Response.json({ work_key: wk });
    }

    // GET /state/:work_key
    const stateMatch = url.pathname.match(/^\/state\/(.+)$/);
    if (stateMatch) {
      const wk = stateMatch[1];
      if (req.method === "GET") {
        return Response.json(stateStore.get(wk) ?? {});
      }
      if (req.method === "PATCH") {
        return req.json().then((updates: Record<string, unknown>) => {
          const current = stateStore.get(wk) ?? {};
          stateStore.set(wk, { ...current, ...updates, updated_at: new Date().toISOString() });
          return Response.json(stateStore.get(wk));
        });
      }
    }

    // GET  /mailbox/:agent  → read messages
    // POST /mailbox/:agent  → post message
    const mailboxMatch = url.pathname.match(/^\/mailbox\/(.+)$/);
    if (mailboxMatch) {
      const agent = mailboxMatch[1];
      if (req.method === "GET") {
        const msgs = mailboxStore.get(agent) ?? [];
        mailboxStore.delete(agent);
        return Response.json({ messages: msgs, count: msgs.length });
      }
      if (req.method === "POST") {
        return req.json().then((msg: ChannelMessage) => {
          sendTo(agent, msg);
          return Response.json({ ok: true, delivered: presence.has(agent) });
        });
      }
    }

    return new Response("Not Found", { status: 404 });
  },

  websocket: {
    open(ws) {
      console.log(`[ws] connected`);
    },
    message(ws, data) {
      handleWsMessage(ws, typeof data === "string" ? data : data.toString());
    },
    close(ws) {
      const name = ws.data.name;
      if (name) {
        presence.delete(name);
        const wk = ws.data.work_key;
        if (wk) channels.get(wk)?.delete(ws);
        console.log(`[presence] -${name} offline`);
      }
    },
  },
});

console.log(`
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 open-agent-harness | state-server
 http://0.0.0.0:${server.port}
 ws://0.0.0.0:${server.port}/ws
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Endpoints:
   GET  /health
   GET  /presence
   POST /work-key
   GET  /state/:work_key
   PATCH /state/:work_key
   GET  /mailbox/:agent
   POST /mailbox/:agent
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
`);
