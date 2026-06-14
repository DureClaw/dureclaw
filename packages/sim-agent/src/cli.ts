#!/usr/bin/env bun
/**
 * `dureclaw` CLI — subcommand dispatcher.
 *
 * Currently routes the `sim` subcommand. Kept deliberately small and extensible
 * so future top-level commands (status, dispatch, …) can hang off the same entry.
 *
 *   dureclaw sim --scenario factory-defect [--server ws://localhost:4000] [--auto]
 */

import { runSimulation } from "./runner.ts";
import { BUNDLED_SCENARIOS_DIR } from "./scenario.ts";
import { readdirSync, existsSync } from "node:fs";

const VERSION = "0.4.0";

function parseFlags(argv: string[]): { flags: Record<string, string | boolean>; rest: string[] } {
  const flags: Record<string, string | boolean> = {};
  const rest: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    if (a.startsWith("--")) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith("--")) {
        flags[key] = next;
        i++;
      } else {
        flags[key] = true;
      }
    } else {
      rest.push(a);
    }
  }
  return { flags, rest };
}

function listScenarios(): string[] {
  if (!existsSync(BUNDLED_SCENARIOS_DIR)) return [];
  return readdirSync(BUNDLED_SCENARIOS_DIR)
    .filter((f) => f.endsWith(".yaml") || f.endsWith(".yml"))
    .map((f) => f.replace(/\.ya?ml$/, ""));
}

function simHelp(): void {
  console.log(`dureclaw sim — run a virtual fleet against the real Phoenix bus

Usage:
  dureclaw sim --scenario <name|path> [options]

Options:
  --scenario <ref>   scenario name (bundled) or path to a .yaml/.json file
  --server <url>     Phoenix server (default: ws://localhost:4000 or $STATE_SERVER)
  --work-key <wk>    join an existing Work Key instead of creating one
  --token <secret>   OAH_SECRET bearer token (default: $OAH_SECRET)
  --auto             non-interactive: auto-trigger and auto-approve (CI/backup)
  --real <names>     comma-separated fleet members that are REAL agents already
                     on the bus (not simulated) — e.g. --real executor@pi-cam

Bundled scenarios:
${listScenarios().map((s) => `  - ${s}`).join("\n") || "  (none)"}

Examples:
  dureclaw sim --scenario factory-defect
  dureclaw sim --scenario factory-defect --auto
  dureclaw sim --scenario ./scenarios/factory-defect.yaml --server ws://100.x.y.z:4000`);
}

async function main(): Promise<void> {
  const [, , cmd, ...argv] = process.argv;
  const { flags, rest } = parseFlags(argv);

  if (!cmd || cmd === "help" || flags.help) {
    if (cmd === "sim") return simHelp();
    console.log(`dureclaw v${VERSION}

Usage: dureclaw <command> [options]

Commands:
  sim     run a virtual fleet simulation against the Phoenix bus
  help    show this help

Run "dureclaw sim --help" for simulation options.`);
    return;
  }

  switch (cmd) {
    case "sim": {
      if (flags.help) return simHelp();
      const scenario = (flags.scenario as string) ?? rest[0];
      if (!scenario) {
        console.error(`error: --scenario is required\n`);
        simHelp();
        process.exit(1);
      }
      await runSimulation({
        scenario,
        server: (flags.server as string) ?? process.env.STATE_SERVER ?? "ws://localhost:4000",
        workKey: (flags["work-key"] as string) ?? process.env.WORK_KEY,
        token: (flags.token as string) ?? process.env.OAH_SECRET,
        auto: flags.auto === true || flags.auto === "true",
        real: typeof flags.real === "string" ? flags.real.split(",").map((s) => s.trim()).filter(Boolean) : undefined,
      });
      break;
    }
    default:
      console.error(`unknown command: ${cmd}\n`);
      process.exit(1);
  }
}

main().catch((err) => {
  console.error(`\n❌ ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
