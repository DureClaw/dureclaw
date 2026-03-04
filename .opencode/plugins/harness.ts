/**
 * open-agent-harness plugin (harness.ts)
 *
 * OpenCode plugin providing:
 * - Hook lifecycle handlers (tool.execute.after)
 * - Custom tools: run_hook, read_state, write_state, post_message, read_mailbox
 *
 * Plugin format: named export conforming to Plugin type from @opencode-ai/plugin
 */

import { type Plugin, tool } from "@opencode-ai/plugin";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

// ─── Allowed hook scripts ──────────────────────────────────────────────────────

const ALLOWED_HOOKS = new Set([
  "00_preflight.sh",
  "01_diff_summary.sh",
  "02_format.sh",
  "03_lint.sh",
  "04_typecheck.sh",
  "05_unit_test.sh",
  "06_integration_test.sh",
  "07_build.sh",
  "08_fail_classifier.py",
  "09_completion_gate.sh",
]);

// ─── Plugin ────────────────────────────────────────────────────────────────────

export const HarnessPlugin: Plugin = async (ctx) => {
  const ROOT = ctx.directory;
  const OPENCODE_DIR = join(ROOT, ".opencode");
  const HOOKS_DIR = join(OPENCODE_DIR, "hooks");
  const REPORTS_DIR = join(OPENCODE_DIR, "reports");
  const STATE_DIR = join(OPENCODE_DIR, "state");
  const MAILBOX_DIR = join(STATE_DIR, "mailbox");
  const STATE_FILE = join(STATE_DIR, "state.json");

  // ── Utilities ────────────────────────────────────────────────────────────

  function ensureDir(dir: string): void {
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  }

  function readJson<T>(filePath: string, fallback: T): T {
    try {
      return JSON.parse(readFileSync(filePath, "utf8")) as T;
    } catch {
      return fallback;
    }
  }

  function writeJson(filePath: string, data: unknown): void {
    ensureDir(join(filePath, ".."));
    writeFileSync(filePath, JSON.stringify(data, null, 2) + "\n", "utf8");
  }

  function ts(): string {
    return new Date().toISOString();
  }

  function saveReport(name: string, content: string): string {
    ensureDir(REPORTS_DIR);
    const reportPath = join(REPORTS_DIR, name);
    writeFileSync(reportPath, content, "utf8");
    return reportPath;
  }

  function execHook(
    hook: string,
    env?: Record<string, string>
  ): { exitCode: number; stdout: string; stderr: string } {
    const hookPath = join(HOOKS_DIR, hook);
    const isPython = hook.endsWith(".py");
    const result = spawnSync(isPython ? "python3" : "bash", [hookPath], {
      cwd: ROOT,
      env: { ...process.env, ...env },
      encoding: "utf8",
      timeout: 120_000,
    });
    return {
      exitCode: result.status ?? 1,
      stdout: result.stdout ?? "",
      stderr: result.stderr ?? "",
    };
  }

  // ── Return Hooks object ──────────────────────────────────────────────────

  return {
    // Auto-save bash command results to .opencode/reports/
    "tool.execute.after": async (input, output) => {
      if (input.tool !== "bash") return;

      const cmd = (input.args?.command as string) ?? "";
      const safeCmd = cmd.replace(/[^a-zA-Z0-9_-]/g, "_").slice(0, 40);
      const content = [
        `# Bash Report`,
        `- **Time**: ${ts()}`,
        `- **Command**: \`${cmd}\``,
        ``,
        `## Output`,
        ``,
        "```",
        output.output,
        "```",
        "",
      ].join("\n");
      saveReport(`bash_${safeCmd}_${Date.now()}.md`, content);
    },

    // ── Custom tools ────────────────────────────────────────────────────────

    tool: {
      run_hook: tool({
        description:
          "Run a harness hook script (e.g. 03_lint.sh) and return the result.",
        args: {
          hook: tool.schema
            .string()
            .describe(
              "Hook filename to run. One of: " + [...ALLOWED_HOOKS].join(", ")
            ),
        },
        async execute(args) {
          if (!ALLOWED_HOOKS.has(args.hook)) {
            return `Error: Hook "${args.hook}" is not allowed. Allowed hooks: ${[...ALLOWED_HOOKS].join(", ")}`;
          }
          const hookPath = join(HOOKS_DIR, args.hook);
          if (!existsSync(hookPath)) {
            return `Error: Hook script not found at ${hookPath}`;
          }

          const result = execHook(args.hook);
          const hookName = args.hook.replace(/\.[^.]+$/, "");
          const reportPath = saveReport(
            `${hookName}.md`,
            [
              `# Hook: ${args.hook}`,
              `- **Time**: ${ts()}`,
              `- **Exit Code**: ${result.exitCode}`,
              `- **Status**: ${result.exitCode === 0 ? "✅ PASS" : "❌ FAIL"}`,
              ``,
              `## stdout`,
              ``,
              "```",
              result.stdout,
              "```",
              ``,
              `## stderr`,
              ``,
              "```",
              result.stderr,
              "```",
              "",
            ].join("\n")
          );

          const status = result.exitCode === 0 ? "PASS" : "FAIL";
          return [
            `${status} (exit ${result.exitCode})`,
            `Report saved: ${reportPath}`,
            ``,
            result.stdout,
            result.stderr,
          ]
            .join("\n")
            .trim();
        },
      }),

      read_state: tool({
        description: "Read the current harness state.json file.",
        args: {},
        async execute() {
          const state = readJson(STATE_FILE, {
            run_id: null,
            goal: null,
            status: "idle",
            loop_count: 0,
            tasks: [],
            current_task: null,
            last_failure: null,
            updated_at: null,
          });
          return JSON.stringify(state, null, 2);
        },
      }),

      write_state: tool({
        description:
          "Merge updates into harness state.json (shallow merge). Pass JSON string of fields to update.",
        args: {
          updates: tool.schema
            .string()
            .describe('JSON object string of state fields to update, e.g. {"status":"running","loop_count":1}'),
        },
        async execute(args) {
          let updates: Record<string, unknown>;
          try {
            updates = JSON.parse(args.updates) as Record<string, unknown>;
          } catch {
            return `Error: updates must be valid JSON. Got: ${args.updates}`;
          }
          const current = readJson<Record<string, unknown>>(STATE_FILE, {});
          const next = { ...current, ...updates, updated_at: ts() };
          ensureDir(STATE_DIR);
          writeJson(STATE_FILE, next);
          return `State updated at ${STATE_FILE}`;
        },
      }),

      post_message: tool({
        description: "Post a message to an agent's mailbox.",
        args: {
          to: tool.schema.string().describe("Target agent name (e.g. builder)"),
          from: tool.schema.string().describe("Sender agent name (e.g. orchestrator)"),
          type: tool.schema.string().describe("Message type (e.g. build_task)"),
          payload: tool.schema
            .string()
            .describe("JSON string payload for the message"),
        },
        async execute(args) {
          ensureDir(MAILBOX_DIR);
          let payload: unknown;
          try {
            payload = JSON.parse(args.payload);
          } catch {
            payload = args.payload;
          }
          const filename = `${args.to}_${args.type}_${Date.now()}.json`;
          const msgPath = join(MAILBOX_DIR, filename);
          writeJson(msgPath, {
            from: args.from,
            to: args.to,
            type: args.type,
            payload,
            timestamp: ts(),
            read: false,
          });
          return `Message posted to ${args.to}: ${msgPath}`;
        },
      }),

      read_mailbox: tool({
        description:
          "Read unread messages for an agent from the mailbox. Messages are marked as read after retrieval.",
        args: {
          agent: tool.schema.string().describe("Agent name to read messages for"),
        },
        async execute(args) {
          ensureDir(MAILBOX_DIR);
          let files: string[] = [];
          try {
            files = readdirSync(MAILBOX_DIR);
          } catch {
            return JSON.stringify({ count: 0, messages: [] }, null, 2);
          }

          const messages: unknown[] = [];
          for (const file of files.filter((f) =>
            f.startsWith(`${args.agent}_`)
          )) {
            const msgPath = join(MAILBOX_DIR, file);
            try {
              const msg = readJson<Record<string, unknown>>(msgPath, {});
              if (!msg.read) {
                messages.push(msg);
                writeJson(msgPath, { ...msg, read: true, read_at: ts() });
              }
            } catch {
              // skip malformed
            }
          }

          return JSON.stringify({ count: messages.length, messages }, null, 2);
        },
      }),
    },
  };
};
