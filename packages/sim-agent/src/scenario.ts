/**
 * Declarative, deterministic scenario format for the DureClaw simulator.
 *
 * A scenario describes a virtual fleet and a sequence of events. The runner
 * spins up one virtual worker per fleet member (real bus presence), then drives
 * each event: fan-out `task.assign` to targets, fan-in `task.result`, and an
 * optional structured `suggest` surfaced as a human-in-the-loop approval gate.
 *
 * Scenarios are deterministic on purpose: the same file produces the same
 * on-stage output every time (suggest = cached golden response).
 */

import { readFileSync, existsSync } from "node:fs";
import { resolve, dirname, join, isAbsolute } from "node:path";
import { fileURLToPath } from "node:url";
import { parse as parseYaml } from "yaml";

export interface FleetMember {
  /** Agent name, e.g. "executor@pi-cam". */
  name: string;
  role: string;
  /** Simulated work duration before the result is returned. */
  latency_ms: number;
  /** Declared capabilities (shown in presence, used for routing realism). */
  caps: string[];
  /** Optional model tag shown in presence. */
  preferred_model?: string;
}

export interface FanoutTarget {
  /** Target agent name — must match a fleet member's `name`. */
  to: string;
  /** Structured fields the worker echoes back in its task.result. */
  emits: Record<string, unknown>;
}

export interface ScenarioEvent {
  /** Human label for the trigger, e.g. "defect_injected". */
  trigger: string;
  /** Optional domain context (lot id, work order, …) carried through. */
  lot?: string;
  /** Workers to fan the task out to, simultaneously. */
  fanout: FanoutTarget[];
  /** Cached golden suggestion surfaced as the approval gate after fan-in. */
  suggest?: Record<string, unknown>;
}

export interface Scenario {
  name: string;
  fleet: FleetMember[];
  events: ScenarioEvent[];
}

const __dirname = dirname(fileURLToPath(import.meta.url));
/** Directory holding the bundled scenario files. */
export const BUNDLED_SCENARIOS_DIR = resolve(__dirname, "..", "scenarios");

/**
 * Resolve a scenario reference to a file path.
 * Accepts an absolute/relative path, or a bare name like "factory-defect"
 * (with or without the .yaml extension) resolved against the bundled dir.
 */
export function resolveScenarioPath(ref: string): string {
  const candidates: string[] = [];
  if (isAbsolute(ref)) {
    candidates.push(ref);
  } else {
    candidates.push(resolve(process.cwd(), ref));
    candidates.push(join(BUNDLED_SCENARIOS_DIR, ref));
    if (!ref.endsWith(".yaml") && !ref.endsWith(".yml")) {
      candidates.push(join(BUNDLED_SCENARIOS_DIR, `${ref}.yaml`));
      candidates.push(resolve(process.cwd(), `${ref}.yaml`));
    }
  }
  const found = candidates.find((c) => existsSync(c));
  if (!found) {
    throw new Error(
      `scenario not found: "${ref}"\n  looked in:\n${candidates.map((c) => `    - ${c}`).join("\n")}`,
    );
  }
  return found;
}

/** Load and validate a scenario from a name or path. */
export function loadScenario(ref: string): Scenario {
  const path = resolveScenarioPath(ref);
  const raw = readFileSync(path, "utf8");
  const doc = (raw.trimStart().startsWith("{") ? JSON.parse(raw) : parseYaml(raw)) as Partial<Scenario>;

  if (!doc || typeof doc !== "object") {
    throw new Error(`scenario ${path}: not a mapping`);
  }
  if (!Array.isArray(doc.fleet) || doc.fleet.length === 0) {
    throw new Error(`scenario ${path}: missing non-empty "fleet"`);
  }
  if (!Array.isArray(doc.events) || doc.events.length === 0) {
    throw new Error(`scenario ${path}: missing non-empty "events"`);
  }

  const names = new Set(doc.fleet.map((m) => m.name));
  for (const ev of doc.events) {
    for (const t of ev.fanout ?? []) {
      if (!names.has(t.to)) {
        throw new Error(`scenario ${path}: fanout target "${t.to}" is not in the fleet`);
      }
    }
  }

  return {
    name: doc.name ?? path.split("/").pop()!.replace(/\.ya?ml$/, ""),
    fleet: doc.fleet.map((m) => ({
      ...m,
      latency_ms: m.latency_ms ?? 300,
      caps: m.caps ?? [],
    })),
    events: doc.events,
  };
}
