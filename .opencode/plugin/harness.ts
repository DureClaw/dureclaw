/**
 * open-agent-harness plugin (harness.ts)
 *
 * OpenCode plugin providing:
 * - Hook lifecycle handlers (tool.execute.before/after, session.idle, session.stop)
 * - Custom tools: run_hook, read_state, write_state, post_message, read_mailbox
 */

import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { join, resolve } from "node:path";

// ─── Constants ────────────────────────────────────────────────────────────────

const ROOT = resolve(process.cwd());
const OPENCODE_DIR = join(ROOT, ".opencode");
const HOOKS_DIR = join(OPENCODE_DIR, "hooks");
const REPORTS_DIR = join(OPENCODE_DIR, "reports");
const STATE_DIR = join(OPENCODE_DIR, "state");
const MAILBOX_DIR = join(STATE_DIR, "mailbox");
const STATE_FILE = join(STATE_DIR, "state.json");

// Allowed hook scripts
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

// Builder is the only agent allowed to edit source files
const BUILDER_EDITABLE_PATTERNS = [
  /^src\//,
  /^lib\//,
  /^app\//,
  /^pages\//,
  /^components\//,
  /\.ts$/,
  /\.tsx$/,
  /\.js$/,
  /\.jsx$/,
  /\.py$/,
  /\.go$/,
  /package\.json$/,
];

// ─── Utilities ────────────────────────────────────────────────────────────────

function ensureDir(dir: string): void {
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
}

function readJson<T>(path: string, fallback: T): T {
  try {
    return JSON.parse(readFileSync(path, "utf8")) as T;
  } catch {
    return fallback;
  }
}

function writeJson(path: string, data: unknown): void {
  ensureDir(resolve(path, ".."));
  writeFileSync(path, JSON.stringify(data, null, 2) + "\n", "utf8");
}

function timestamp(): string {
  return new Date().toISOString();
}

function runScript(scriptPath: string, env?: Record<string, string>): {
  exitCode: number;
  stdout: string;
  stderr: string;
} {
  const result = spawnSync("bash", [scriptPath], {
    cwd: ROOT,
    env: { ...process.env, ...env },
    encoding: "utf8",
    timeout: 120_000, // 2 min timeout
  });
  return {
    exitCode: result.status ?? 1,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

// ─── Hook: tool.execute.before ─────────────────────────────────────────────

/**
 * Gate: only Builder agent may edit source files.
 * Returns { allow: false, reason } to block the tool call.
 */
export function onToolBefore(ctx: {
  agentName: string;
  toolName: string;
  toolInput: Record<string, unknown>;
}): { allow: boolean; reason?: string } {
  const { agentName, toolName, toolInput } = ctx;

  // Only gate write/edit operations
  if (!["edit", "write", "multiEdit"].includes(toolName)) {
    return { allow: true };
  }

  const targetPath =
    (toolInput["path"] as string) ??
    (toolInput["file_path"] as string) ??
    "";

  // .opencode/ writes are always allowed
  if (targetPath.startsWith(".opencode/")) {
    return { allow: true };
  }

  // Only builder may write source files
  if (agentName !== "builder") {
    const isSourceFile = BUILDER_EDITABLE_PATTERNS.some((p) =>
      p.test(targetPath)
    );
    if (isSourceFile) {
      return {
        allow: false,
        reason: `[harness] Agent "${agentName}" is not permitted to edit source file "${targetPath}". Only the Builder agent may edit source files.`,
      };
    }
  }

  return { allow: true };
}

// ─── Hook: tool.execute.after ──────────────────────────────────────────────

/**
 * Auto-save bash execution results to reports/.
 */
export function onToolAfter(ctx: {
  agentName: string;
  toolName: string;
  toolInput: Record<string, unknown>;
  toolOutput: unknown;
}): void {
  const { agentName, toolName, toolInput, toolOutput } = ctx;

  if (toolName !== "bash") return;

  const cmd = (toolInput["command"] as string) ?? "";
  const output =
    typeof toolOutput === "string"
      ? toolOutput
      : JSON.stringify(toolOutput, null, 2);

  // Save to reports/
  ensureDir(REPORTS_DIR);
  const safeCmd = cmd.replace(/[^a-zA-Z0-9_-]/g, "_").slice(0, 40);
  const reportFile = join(
    REPORTS_DIR,
    `bash_${agentName}_${safeCmd}_${Date.now()}.md`
  );

  const content = `# Bash Report
- **Agent**: ${agentName}
- **Time**: ${timestamp()}
- **Command**: \`${cmd}\`

## Output

\`\`\`
${output}
\`\`\`
`;
  writeFileSync(reportFile, content, "utf8");
}

// ─── Hook: session.idle ─────────────────────────────────────────────────────

/**
 * When the session goes idle, run the completion gate.
 * Returns the gate result for the session to act on.
 */
export function onSessionIdle(): {
  gatePassed: boolean;
  reportPath: string;
} {
  const gatePath = join(HOOKS_DIR, "09_completion_gate.sh");
  if (!existsSync(gatePath)) {
    return { gatePassed: false, reportPath: "" };
  }

  const result = runScript(gatePath);
  const reportPath = join(REPORTS_DIR, "completion_gate.md");

  ensureDir(REPORTS_DIR);
  writeFileSync(
    reportPath,
    `# Completion Gate Report
- **Time**: ${timestamp()}
- **Exit Code**: ${result.exitCode}

## Output

\`\`\`
${result.stdout}
${result.stderr}
\`\`\`
`,
    "utf8"
  );

  return {
    gatePassed: result.exitCode === 0,
    reportPath,
  };
}

// ─── Hook: experimental.session.stop ───────────────────────────────────────

/**
 * Before stopping the session, check the gate.
 * If gate fails, signal the orchestrator to continue.
 */
export function onSessionStop(): {
  shouldContinue: boolean;
  signal?: string;
} {
  const gateResult = onSessionIdle();

  if (!gateResult.gatePassed) {
    // Write a restart signal to the mailbox
    ensureDir(MAILBOX_DIR);
    const signalFile = join(MAILBOX_DIR, `restart_signal_${Date.now()}.json`);
    writeJson(signalFile, {
      from: "harness",
      to: "orchestrator",
      type: "gate_failed",
      payload: {
        report_path: gateResult.reportPath,
        message: "Completion gate failed. Continue the loop.",
        timestamp: timestamp(),
      },
    });

    return {
      shouldContinue: true,
      signal: `Gate failed. Report: ${gateResult.reportPath}`,
    };
  }

  return { shouldContinue: false };
}

// ─── Custom Tool: run_hook ──────────────────────────────────────────────────

/**
 * Agents call this tool to run a specific hook script.
 *
 * Input: { hook: "03_lint.sh", env?: {...} }
 * Output: { exit_code, report_path, summary }
 */
export function toolRunHook(input: {
  hook: string;
  env?: Record<string, string>;
}): {
  exit_code: number;
  report_path: string;
  summary: string;
  stdout: string;
  stderr: string;
} {
  const { hook, env } = input;

  if (!ALLOWED_HOOKS.has(hook)) {
    throw new Error(
      `Hook "${hook}" is not in the allowed list. Allowed: ${[...ALLOWED_HOOKS].join(", ")}`
    );
  }

  const hookPath = join(HOOKS_DIR, hook);
  if (!existsSync(hookPath)) {
    throw new Error(`Hook script not found: ${hookPath}`);
  }

  // Python scripts use python3
  const isPython = hook.endsWith(".py");
  const result = isPython
    ? spawnSync("python3", [hookPath], {
        cwd: ROOT,
        env: { ...process.env, ...env },
        encoding: "utf8",
        timeout: 120_000,
      })
    : spawnSync("bash", [hookPath], {
        cwd: ROOT,
        env: { ...process.env, ...env },
        encoding: "utf8",
        timeout: 120_000,
      });

  const exitCode = result.status ?? 1;
  const stdout = result.stdout ?? "";
  const stderr = result.stderr ?? "";

  // Save report
  ensureDir(REPORTS_DIR);
  const hookName = hook.replace(/\.[^.]+$/, "");
  const reportPath = join(REPORTS_DIR, `${hookName}.md`);
  writeFileSync(
    reportPath,
    `# Hook Report: ${hook}
- **Time**: ${timestamp()}
- **Exit Code**: ${exitCode}
- **Status**: ${exitCode === 0 ? "✅ PASS" : "❌ FAIL"}

## stdout

\`\`\`
${stdout}
\`\`\`

## stderr

\`\`\`
${stderr}
\`\`\`
`,
    "utf8"
  );

  const statusLabel = exitCode === 0 ? "PASS" : "FAIL";
  const summary = `${statusLabel} (exit ${exitCode}) — report: ${reportPath}`;

  return { exit_code: exitCode, report_path: reportPath, summary, stdout, stderr };
}

// ─── Custom Tool: read_state ────────────────────────────────────────────────

/**
 * Read the current state.json.
 */
export function toolReadState(_input: Record<string, never>): unknown {
  return readJson(STATE_FILE, {
    run_id: null,
    goal: null,
    status: "idle",
    loop_count: 0,
    tasks: [],
    current_task: null,
    last_failure: null,
    updated_at: null,
  });
}

// ─── Custom Tool: write_state ────────────────────────────────────────────────

/**
 * Merge updates into state.json (shallow merge).
 */
export function toolWriteState(input: Record<string, unknown>): {
  ok: boolean;
  state_path: string;
} {
  const current = readJson<Record<string, unknown>>(STATE_FILE, {});
  const next = { ...current, ...input, updated_at: timestamp() };
  ensureDir(STATE_DIR);
  writeJson(STATE_FILE, next);
  return { ok: true, state_path: STATE_FILE };
}

// ─── Custom Tool: post_message ──────────────────────────────────────────────

/**
 * Post a message to an agent's mailbox.
 *
 * Input: { to: "builder", from: "orchestrator", type: "build_task", payload: {...} }
 */
export function toolPostMessage(input: {
  to: string;
  from: string;
  type: string;
  payload: unknown;
}): { ok: boolean; message_path: string } {
  const { to, from, type, payload } = input;

  ensureDir(MAILBOX_DIR);
  const filename = `${to}_${type}_${Date.now()}.json`;
  const messagePath = join(MAILBOX_DIR, filename);

  writeJson(messagePath, {
    from,
    to,
    type,
    payload,
    timestamp: timestamp(),
    read: false,
  });

  return { ok: true, message_path: messagePath };
}

// ─── Custom Tool: read_mailbox ───────────────────────────────────────────────

/**
 * Read unread messages for an agent from the mailbox.
 * Marks messages as read after retrieval.
 *
 * Input: { agent: "orchestrator", mark_read?: true }
 */
export function toolReadMailbox(input: {
  agent: string;
  mark_read?: boolean;
}): { messages: unknown[]; count: number } {
  const { agent, mark_read = true } = input;

  ensureDir(MAILBOX_DIR);

  let files: string[] = [];
  try {
    files = readdirSync(MAILBOX_DIR);
  } catch {
    return { messages: [], count: 0 };
  }

  const messages: unknown[] = [];

  for (const file of files.filter((f) => f.startsWith(`${agent}_`))) {
    const msgPath = join(MAILBOX_DIR, file);
    try {
      const msg = readJson<Record<string, unknown>>(msgPath, {});
      if (!msg.read || !mark_read) {
        messages.push(msg);
        if (mark_read) {
          writeJson(msgPath, { ...msg, read: true, read_at: timestamp() });
        }
      }
    } catch {
      // Skip malformed message files
    }
  }

  return { messages, count: messages.length };
}
