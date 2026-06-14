/**
 * Minimal Phoenix Channel (v2.0.0) client.
 *
 * Speaks the exact same wire protocol as packages/agent-daemon — the 5-tuple
 * frame `[join_ref, ref, topic, event, payload]` over `/socket/websocket?vsn=2.0.0`.
 * This is what makes a simulated worker indistinguishable from a real one on the
 * bus: presence, dashboards and event streams treat it identically.
 */

export interface PhxIdentity {
  agent_name: string;
  role: string;
  machine: string;
  capabilities: string[];
  preferred_model: string;
  version: string;
}

/** Phoenix WebSocket frame: [join_ref, ref, topic, event, payload]. */
type PhxFrame = [string | null, string | null, string, string, Record<string, unknown>];

type EventHandler = (payload: Record<string, unknown>) => void;

export interface PhoenixOpts {
  /** Base server URL — accepts ws://, wss://, http://, https://. */
  server: string;
  workKey: string;
  identity: PhxIdentity;
  /** Optional OAH_SECRET bearer token. */
  token?: string;
  /** Tag used to prefix log lines, e.g. the agent name. */
  logTag?: string;
}

export class PhoenixChannel {
  private ws: WebSocket | null = null;
  private readonly wsUrl: string;
  private readonly topic: string;
  private readonly opts: PhoenixOpts;

  private refCounter = 0;
  private joinRef: string | null = null;
  private joined = false;
  private closing = false;

  private heartbeat: ReturnType<typeof setInterval> | null = null;
  private readonly handlers = new Map<string, Set<EventHandler>>();
  private readonly joinWaiters: Array<(presences: Record<string, unknown>) => void> = [];

  constructor(opts: PhoenixOpts) {
    this.opts = opts;
    const wsBase = opts.server.replace(/^http/, "ws").replace(/\/$/, "");
    this.wsUrl = opts.token
      ? `${wsBase}/socket/websocket?vsn=2.0.0&token=${encodeURIComponent(opts.token)}`
      : `${wsBase}/socket/websocket?vsn=2.0.0`;
    this.topic = `work:${opts.workKey}`;
  }

  private log(msg: string): void {
    const tag = this.opts.logTag ?? this.opts.identity.agent_name;
    console.log(`[sim:${tag}] ${msg}`);
  }

  private nextRef(): string {
    return String(++this.refCounter);
  }

  /** Connect and join the work channel. Resolves once the server replies "ok". */
  connect(): Promise<Record<string, unknown>> {
    return new Promise((resolve, reject) => {
      this.joinWaiters.push(resolve);
      this.ws = new WebSocket(this.wsUrl);

      const failTimer = setTimeout(() => {
        if (!this.joined) reject(new Error(`join timeout for ${this.topic}`));
      }, 15_000);

      this.ws.onopen = () => {
        this.joinRef = this.nextRef();
        this.sendRaw([this.joinRef, this.joinRef, this.topic, "phx_join", {
          agent_name: this.opts.identity.agent_name,
          role: this.opts.identity.role,
          machine: this.opts.identity.machine,
          capabilities: this.opts.identity.capabilities,
          preferred_model: this.opts.identity.preferred_model,
          version: this.opts.identity.version,
        }]);
        this.startHeartbeat();
      };

      this.ws.onmessage = (ev) => {
        clearTimeout(failTimer);
        this.handleFrame(ev.data as string);
      };

      this.ws.onerror = () => {
        /* surfaced via onclose */
      };

      this.ws.onclose = () => {
        this.stopHeartbeat();
        this.joined = false;
        if (this.closing) return;
        this.log(`disconnected — reconnecting in 1s`);
        setTimeout(() => this.connect().catch(() => {}), 1_000);
      };
    });
  }

  private handleFrame(data: string): void {
    let frame: PhxFrame;
    try {
      frame = JSON.parse(data) as PhxFrame;
    } catch {
      return;
    }
    const [, ref, topic, event, payload] = frame;

    if (event === "phx_reply") {
      if (topic === "phoenix") return; // heartbeat ack
      const status = (payload as { status?: string }).status;
      if (ref === this.joinRef && status === "ok" && !this.joined) {
        this.joined = true;
        const response = (payload as { response?: Record<string, unknown> }).response ?? {};
        const presences = (response.presences as Record<string, unknown>) ?? {};
        this.log(`joined ${topic}`);
        for (const w of this.joinWaiters.splice(0)) w(presences);
      }
      return;
    }

    const set = this.handlers.get(event);
    if (set) for (const h of set) h(payload);
  }

  /** Register an event handler. Returns an unsubscribe function. */
  on(event: string, handler: EventHandler): () => void {
    let set = this.handlers.get(event);
    if (!set) {
      set = new Set();
      this.handlers.set(event, set);
    }
    set.add(handler);
    return () => set!.delete(handler);
  }

  /** Push an event to the channel (broadcast to all members server-side). */
  push(event: string, payload: Record<string, unknown>): void {
    if (this.ws?.readyState === WebSocket.OPEN && this.joined) {
      this.sendRaw([this.joinRef, this.nextRef(), this.topic, event, payload]);
    } else {
      this.log(`⚠️  dropped ${event} (not joined)`);
    }
  }

  private sendRaw(frame: PhxFrame): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(frame));
    }
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeat = setInterval(() => {
      this.sendRaw([null, this.nextRef(), "phoenix", "heartbeat", {}]);
    }, 30_000);
  }

  private stopHeartbeat(): void {
    if (this.heartbeat) {
      clearInterval(this.heartbeat);
      this.heartbeat = null;
    }
  }

  /** Leave the channel and close the socket. */
  close(): void {
    this.closing = true;
    this.stopHeartbeat();
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.sendRaw([this.joinRef, this.nextRef(), this.topic, "phx_leave", {}]);
    }
    this.ws?.close();
  }
}

/** Create a Work Key via REST, or return the latest existing one. */
export async function ensureWorkKey(
  server: string,
  opts: { token?: string; reuseLatest?: boolean; goal?: string } = {},
): Promise<string> {
  const httpBase = server.replace(/^ws/, "http").replace(/\/$/, "");
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (opts.token) headers.Authorization = `Bearer ${opts.token}`;

  if (opts.reuseLatest) {
    try {
      const res = await fetch(`${httpBase}/api/work-keys/latest`, { headers });
      if (res.ok) {
        const { work_key } = (await res.json()) as { work_key: string };
        return work_key;
      }
    } catch {
      /* fall through to create */
    }
  }

  const res = await fetch(`${httpBase}/api/work-keys`, {
    method: "POST",
    headers,
    body: JSON.stringify({ goal: opts.goal ?? "DureClaw simulation" }),
  });
  if (!res.ok) throw new Error(`POST /api/work-keys failed: ${res.status}`);
  const { work_key } = (await res.json()) as { work_key: string };
  return work_key;
}
