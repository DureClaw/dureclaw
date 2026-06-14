/**
 * Scenario runner — the simulation coordinator.
 *
 * Joins the work channel as `orchestrator@sim`, spins up one SimWorker per fleet
 * member, then drives each scenario event end-to-end on the REAL bus:
 *
 *   trigger → fan-out task.assign → fan-in task.result
 *           → task.approval_requested (HITL gate) → approve → state.update (quarantine)
 *
 * Everything flows through actual Phoenix channels, so the dashboard and event
 * stream are identical to a physical fleet. Output is deterministic.
 */

import { PhoenixChannel, ensureWorkKey, type PhxIdentity } from "./phoenix.ts";
import { SimWorker } from "./worker.ts";
import { loadScenario, type Scenario, type ScenarioEvent } from "./scenario.ts";

export interface RunnerOpts {
  scenario: string;
  server: string;
  workKey?: string;
  token?: string;
  /** Skip interactive prompts — auto-trigger and auto-approve (CI / unattended). */
  auto?: boolean;
  /**
   * Fleet member names that are REAL agents already on the bus (e.g. a physical
   * Pi). The runner does not spawn a virtual worker for these — it still fans
   * the task out to them and collects their genuine result. Keeps the physical
   * "wow" while simulating the rest.
   */
  real?: string[];
}

const SIM_VERSION = "0.4.0-sim";

export class SimRunner {
  private readonly scenario: Scenario;
  private readonly opts: RunnerOpts;
  private workKey = "";
  private coord!: PhoenixChannel;
  private readonly workers: SimWorker[] = [];

  constructor(opts: RunnerOpts) {
    this.opts = opts;
    this.scenario = loadScenario(opts.scenario);
  }

  async run(): Promise<void> {
    this.workKey = this.opts.workKey ?? (await ensureWorkKey(this.opts.server, { token: this.opts.token }));

    banner(`DureClaw SIM · scenario "${this.scenario.name}"`);
    console.log(`  work key : ${this.workKey}`);
    console.log(`  server   : ${this.opts.server}`);
    console.log(`  fleet    : ${this.scenario.fleet.map((m) => m.name).join(", ")}`);
    console.log(`  dashboard: ${this.opts.server.replace(/^ws/, "http")}/dashboard?work_key=${this.workKey}\n`);

    // Bring the virtual fleet online — but skip members backed by a REAL agent.
    const realSet = new Set(this.opts.real ?? []);
    for (const member of this.scenario.fleet) {
      if (realSet.has(member.name)) {
        console.log(`   ⚡ ${member.name} — REAL agent (expected on bus, not simulated)`);
        continue;
      }
      const w = new SimWorker(member, { server: this.opts.server, workKey: this.workKey, token: this.opts.token });
      this.workers.push(w);
    }
    await Promise.all(this.workers.map((w) => w.start()));
    console.log(`✅ ${this.workers.length} virtual workers online${realSet.size ? ` · ${realSet.size} real` : ""}\n`);

    // Coordinator presence.
    const identity: PhxIdentity = {
      agent_name: "orchestrator@sim",
      role: "orchestrator",
      machine: "sim",
      capabilities: ["orchestration"],
      preferred_model: "sim",
      version: SIM_VERSION,
    };
    this.coord = new PhoenixChannel({
      server: this.opts.server,
      workKey: this.workKey,
      identity,
      token: this.opts.token,
      logTag: "runner",
    });
    await this.coord.connect();

    for (let i = 0; i < this.scenario.events.length; i++) {
      await this.runEvent(this.scenario.events[i]!, i + 1);
    }

    console.log(`\n🏁 scenario complete.`);
    this.shutdown();
  }

  private async runEvent(event: ScenarioEvent, idx: number): Promise<void> {
    banner(`Event ${idx}: ${event.trigger}${event.lot ? ` · lot ${event.lot}` : ""}`);

    if (this.opts.auto) {
      console.log(`▶ auto-trigger in 1.5s…`);
      await sleep(1500);
    } else {
      await prompt(`⏎  Press ENTER to inject "${event.trigger}" (physical trigger) `);
    }

    const baseId = `sim-${event.trigger}-${Date.now()}`;
    const expected = new Map<string, string>(); // task_id -> agent name
    const results = new Map<string, Record<string, unknown>>();

    const done = new Promise<void>((resolve) => {
      const off = this.coord.on("task.result", (payload) => {
        const tid = payload.task_id as string;
        if (!expected.has(tid) || results.has(tid)) return;
        results.set(tid, payload);
        const agent = expected.get(tid)!;
        console.log(`   ← ${pad(agent, 18)} ${fmtEmits(payload)}`);
        if (results.size === expected.size) {
          off();
          resolve();
        }
      });
      // Deterministic fallback: never hang the stage on a missing result.
      // Real agents run actual coding CLIs and can take tens of seconds, so give
      // a much longer grace when any fan-out target is a real agent.
      const realSet = new Set(this.opts.real ?? []);
      const hasReal = event.fanout.some((t) => realSet.has(t.to));
      const maxLatency = Math.max(...this.scenario.fleet.map((m) => m.latency_ms), 1000);
      const timeoutMs = hasReal ? 60_000 : maxLatency + 3000;
      setTimeout(() => {
        off();
        resolve();
      }, timeoutMs);
    });

    // Fan-out: assign to every target simultaneously.
    console.log(`\n   ── fan-out → ${event.fanout.length} nodes ──`);
    for (const target of event.fanout) {
      const taskId = `${baseId}-${target.to}`;
      expected.set(taskId, target.to);
      const member = this.scenario.fleet.find((m) => m.name === target.to)!;
      console.log(`   → ${pad(target.to, 18)} assign (latency ${member.latency_ms}ms)`);
      this.coord.push("task.assign", {
        task_id: taskId,
        from: "orchestrator@sim",
        to: target.to,
        role: member.role,
        instructions: `[SIM] ${event.trigger}${event.lot ? ` for lot ${event.lot}` : ""}`,
        work_key: this.workKey,
        lot: event.lot,
        latency_ms: member.latency_ms,
        emits: target.emits,
      });
    }
    console.log("");
    await done;

    // Fan-in → structured suggestion → human approval gate.
    if (event.suggest) {
      await this.approvalGate(baseId, event);
    }
  }

  private async approvalGate(baseId: string, event: ScenarioEvent): Promise<void> {
    banner(`SUGGEST (fan-in)`);
    for (const [k, v] of Object.entries(event.suggest!)) {
      console.log(`   ${pad(k, 14)} : ${typeof v === "object" ? JSON.stringify(v) : v}`);
    }
    console.log(`\n   ⚠️  This is a SUGGESTION, not a decision. Human approval required.\n`);

    // Real HITL event on the bus (already a first-class channel event).
    this.coord.push("task.approval_requested", {
      task_id: `${baseId}-approval`,
      from: "orchestrator@sim",
      work_key: this.workKey,
      lot: event.lot,
      suggestion: event.suggest,
    });

    if (this.opts.auto) {
      console.log(`▶ auto-approve in 1.5s…`);
      await sleep(1500);
    } else {
      await prompt(`⏎  Press ENTER to APPROVE → physical action (quarantine / LED) `);
    }

    const action = (event.suggest!.action as string) ?? "approved";
    // Approval is a real state transition — this is where a Pi LED/buzzer fires.
    this.coord.push("state.update", {
      [`decision_${event.lot ?? baseId}`]: {
        status: action,
        approved_by: "human",
        suggestion: event.suggest,
        decided_at: new Date().toISOString(),
      },
    });
    this.coord.push("task.result", {
      task_id: `${baseId}-approval`,
      from: "orchestrator@sim",
      status: "done",
      summary: `human approved: ${action}`,
      approved: true,
      action,
    });
    console.log(`   ✅ APPROVED → action "${action}" · state updated · audit logged`);
    console.log(`   🔔 (physical hook: Pi LED/buzzer fires here)`);
  }

  shutdown(): void {
    for (const w of this.workers) w.stop();
    this.coord?.close();
  }
}

/** Convenience entry used by the CLI. */
export async function runSimulation(opts: RunnerOpts): Promise<void> {
  const runner = new SimRunner(opts);
  const cleanup = () => {
    runner.shutdown();
    process.exit(0);
  };
  process.on("SIGINT", cleanup);
  process.on("SIGTERM", cleanup);
  await runner.run();
  // Allow the leave frames to flush before exiting.
  await sleep(300);
  process.exit(0);
}

// ─── helpers ──────────────────────────────────────────────────────────────────

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function prompt(question: string): Promise<void> {
  return new Promise((resolve) => {
    process.stdout.write(question);
    const onData = () => {
      process.stdin.off("data", onData);
      process.stdin.pause();
      resolve();
    };
    process.stdin.resume();
    process.stdin.once("data", onData);
  });
}

function fmtEmits(payload: Record<string, unknown>): string {
  const skip = new Set([
    "task_id", "to", "from", "event", "ts", "status", "summary", "role",
    "work_key", "latency_ms", "artifacts", "attempts", "token_count",
  ]);
  const parts = Object.entries(payload)
    .filter(([k, v]) => {
      if (skip.has(k)) return false;
      if (v == null || v === "") return false;
      if (Array.isArray(v) && v.length === 0) return false;
      return true;
    })
    .map(([k, v]) => {
      let s = typeof v === "object" ? JSON.stringify(v) : String(v);
      s = s.replace(/\s+/g, " ").trim(); // collapse newlines from real-agent output
      if (s.length > 80) s = `${s.slice(0, 77)}…`;
      return `${k}=${s}`;
    });
  return parts.length ? parts.join("  ") : "done";
}

function pad(s: string, n: number): string {
  return s.length >= n ? s : s + " ".repeat(n - s.length);
}

function banner(title: string): void {
  console.log(`\n${"─".repeat(2)} ${title} ${"─".repeat(Math.max(2, 60 - title.length))}`);
}
