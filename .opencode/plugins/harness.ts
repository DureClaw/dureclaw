/**
 * open-agent-harness plugin (harness.ts)
 *
 * OpenCode plugin providing:
 * - Hook lifecycle handlers (tool.execute.after, chat.message)
 * - Custom tools: run_hook, read_state, write_state, post_message, read_mailbox
 * - Discord notifications: set DISCORD_WEBHOOK_URL env var to enable
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

// ─── Discord colors ────────────────────────────────────────────────────────────

const DISCORD_COLORS = {
  orchestrator: 0x5865f2, // blurple
  planner: 0xfee75c,      // yellow
  builder: 0x57f287,      // green
  verifier: 0xeb459e,     // pink
  reviewer: 0xed4245,     // red
  hook_pass: 0x57f287,    // green
  hook_fail: 0xed4245,    // red
  default: 0x99aab5,      // grey
} as const;

// ─── Plugin ────────────────────────────────────────────────────────────────────

export const HarnessPlugin: Plugin = async (ctx) => {
  const ROOT = ctx.directory;
  const OPENCODE_DIR = join(ROOT, ".opencode");
  const HOOKS_DIR = join(OPENCODE_DIR, "hooks");
  const REPORTS_DIR = join(OPENCODE_DIR, "reports");
  const STATE_DIR = join(OPENCODE_DIR, "state");
  const MAILBOX_DIR = join(STATE_DIR, "mailbox");
  const STATE_FILE = join(STATE_DIR, "state.json");

  const WEBHOOK_URL = process.env.DISCORD_WEBHOOK_URL ?? "";

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

  // ── Discord ──────────────────────────────────────────────────────────────

  /**
   * Post an embed to Discord via webhook.
   * Silently skips if DISCORD_WEBHOOK_URL is not set.
   */
  async function discordPost(payload: {
    title: string;
    description?: string;
    color?: number;
    fields?: Array<{ name: string; value: string; inline?: boolean }>;
    footer?: string;
  }): Promise<void> {
    if (!WEBHOOK_URL) return;

    try {
      const embed: Record<string, unknown> = {
        title: payload.title,
        color: payload.color ?? DISCORD_COLORS.default,
        timestamp: new Date().toISOString(),
      };
      if (payload.description) embed.description = payload.description;
      if (payload.fields?.length) embed.fields = payload.fields;
      if (payload.footer) embed.footer = { text: payload.footer };

      await fetch(WEBHOOK_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ embeds: [embed] }),
      });
    } catch {
      // Never let Discord errors interrupt the agent workflow
    }
  }

  /**
   * Extract plain text from message parts.
   * Truncates to maxLen to keep Discord embeds readable.
   */
  function extractText(parts: unknown[], maxLen = 800): string {
    if (!Array.isArray(parts)) return "";

    const chunks: string[] = [];
    for (const part of parts) {
      if (
        part &&
        typeof part === "object" &&
        "type" in part &&
        (part as { type: string }).type === "text" &&
        "text" in part
      ) {
        chunks.push(String((part as { text: unknown }).text));
      }
    }
    const full = chunks.join("\n").trim();
    if (full.length <= maxLen) return full;
    return full.slice(0, maxLen - 3) + "...";
  }

  // ── Return Hooks object ──────────────────────────────────────────────────

  return {
    // Mirror agent chat messages to Discord
    "chat.message": async (input, output) => {
      const agent = input.agent ?? "unknown";
      const text = extractText(output.parts);
      if (!text) return;

      const colorKey = agent.toLowerCase() as keyof typeof DISCORD_COLORS;
      const color = DISCORD_COLORS[colorKey] ?? DISCORD_COLORS.default;

      // Agent icon map
      const icons: Record<string, string> = {
        orchestrator: "🎯",
        planner: "📋",
        builder: "🔨",
        verifier: "🧪",
        reviewer: "👀",
      };
      const icon = icons[agent.toLowerCase()] ?? "🤖";

      await discordPost({
        title: `${icon} ${agent}`,
        description: text,
        color,
        footer: `open-agent-harness • session ${input.sessionID.slice(0, 8)}`,
      });
    },

    // Auto-save bash command results to .opencode/reports/
    // Also notify Discord when a hook script is run
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

      // Notify Discord when a hook script runs
      const hookMatch = cmd.match(/\.opencode\/hooks\/([\w.]+)/);
      if (hookMatch) {
        const hookName = hookMatch[1];
        const outputText = (output.output ?? "").slice(0, 600);
        const passed =
          !outputText.includes("FAIL") && !outputText.includes("Error");

        await discordPost({
          title: `${passed ? "✅" : "❌"} Hook: ${hookName}`,
          description: outputText ? `\`\`\`\n${outputText}\n\`\`\`` : undefined,
          color: passed ? DISCORD_COLORS.hook_pass : DISCORD_COLORS.hook_fail,
          footer: "open-agent-harness",
        });
      }
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
          const status = result.exitCode === 0 ? "PASS" : "FAIL";

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

          // Discord notification
          await discordPost({
            title: `${result.exitCode === 0 ? "✅" : "❌"} Hook: ${args.hook}`,
            description:
              result.stdout.slice(0, 600) || result.stderr.slice(0, 600) || undefined,
            color:
              result.exitCode === 0
                ? DISCORD_COLORS.hook_pass
                : DISCORD_COLORS.hook_fail,
            fields: [
              { name: "Exit Code", value: String(result.exitCode), inline: true },
              { name: "Status", value: status, inline: true },
            ],
            footer: `Report: ${reportPath}`,
          });

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
            .describe(
              'JSON object string of state fields to update, e.g. {"status":"running","loop_count":1}'
            ),
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

          // Notify Discord on status changes
          if (updates.status || updates.goal || updates.loop_count !== undefined) {
            const goal = (next.goal as string) ?? "";
            const status = (next.status as string) ?? "";
            const loop = next.loop_count ?? 0;
            await discordPost({
              title: `📊 State Updated`,
              color: DISCORD_COLORS.orchestrator,
              fields: [
                ...(goal ? [{ name: "Goal", value: goal, inline: false }] : []),
                { name: "Status", value: status, inline: true },
                { name: "Loop", value: String(loop), inline: true },
              ],
              footer: "open-agent-harness",
            });
          }

          return `State updated at ${STATE_FILE}`;
        },
      }),

      post_message: tool({
        description: "Post a message to an agent's mailbox.",
        args: {
          to: tool.schema.string().describe("Target agent name (e.g. builder)"),
          from: tool.schema
            .string()
            .describe("Sender agent name (e.g. orchestrator)"),
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
          agent: tool.schema
            .string()
            .describe("Agent name to read messages for"),
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

      discord_notify: tool({
        description:
          "Post a custom notification to Discord. Requires DISCORD_WEBHOOK_URL env var.",
        args: {
          title: tool.schema.string().describe("Notification title"),
          message: tool.schema.string().describe("Notification body text"),
          level: tool.schema
            .enum(["info", "success", "warning", "error"])
            .optional()
            .describe("Severity level (default: info)"),
        },
        async execute(args) {
          if (!WEBHOOK_URL) {
            return "Discord webhook not configured. Set DISCORD_WEBHOOK_URL env var.";
          }
          const colorMap = {
            info: DISCORD_COLORS.default,
            success: DISCORD_COLORS.hook_pass,
            warning: 0xffa500,
            error: DISCORD_COLORS.hook_fail,
          };
          const level = (args.level ?? "info") as keyof typeof colorMap;
          await discordPost({
            title: args.title,
            description: args.message,
            color: colorMap[level],
            footer: "open-agent-harness",
          });
          return `Discord notification sent: ${args.title}`;
        },
      }),
    },
  };
};
