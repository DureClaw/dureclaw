/**
 * A virtual worker: a real Phoenix-bus agent whose execution is replaced by a
 * scenario script. It joins the work channel exactly like packages/agent-daemon
 * (same presence fields), listens for `task.assign` targeted at it, simulates
 * work for the configured latency (emitting `task.progress`), and returns a
 * deterministic `task.result` carrying the scenario-defined `emits`.
 */

import { PhoenixChannel, type PhxIdentity } from "./phoenix.ts";
import type { FleetMember } from "./scenario.ts";

const SIM_VERSION = "0.4.0-sim";

export class SimWorker {
  readonly name: string;
  private readonly channel: PhoenixChannel;
  private readonly member: FleetMember;

  constructor(member: FleetMember, opts: { server: string; workKey: string; token?: string }) {
    this.member = member;
    this.name = member.name;
    const machine = member.name.includes("@") ? member.name.split("@")[1]! : member.name;

    const identity: PhxIdentity = {
      agent_name: member.name,
      role: member.role,
      machine,
      capabilities: member.caps,
      preferred_model: member.preferred_model ?? "sim",
      version: SIM_VERSION,
    };

    this.channel = new PhoenixChannel({
      server: opts.server,
      workKey: opts.workKey,
      identity,
      token: opts.token,
      logTag: member.name,
    });
  }

  async start(): Promise<void> {
    await this.channel.connect();
    this.channel.on("task.assign", (payload) => this.onAssign(payload));
  }

  private onAssign(payload: Record<string, unknown>): void {
    const to = payload.to as string | undefined;
    // Same client-side routing as the real daemon: act only if addressed to us.
    if (to && to !== this.name && to !== "broadcast") return;

    const taskId = (payload.task_id as string) ?? `sim-${Date.now()}`;
    const from = (payload.from as string) ?? "orchestrator@sim";
    const emits = (payload.emits as Record<string, unknown>) ?? {};
    const latency = (payload.latency_ms as number) ?? this.member.latency_ms;

    // Progress mid-flight so the dashboard shows concurrent live activity.
    const midpoint = Math.max(50, Math.floor(latency / 2));
    setTimeout(() => {
      this.channel.push("task.progress", {
        task_id: taskId,
        to: from,
        message: `${this.member.role} working… (${this.describeCaps()})`,
        status: "running",
      });
    }, midpoint);

    setTimeout(() => {
      this.channel.push("task.result", {
        task_id: taskId,
        to: from,
        status: "done",
        summary: `${this.member.role} completed`,
        latency_ms: latency,
        ...emits,
      });
    }, latency);
  }

  private describeCaps(): string {
    return this.member.caps.length ? this.member.caps.join(", ") : "no caps";
  }

  stop(): void {
    this.channel.close();
  }
}
