// .opencode/plugin/harness.ts
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync
} from "node:fs";
import { join, resolve } from "node:path";
var ROOT = resolve(process.cwd());
var OPENCODE_DIR = join(ROOT, ".opencode");
var HOOKS_DIR = join(OPENCODE_DIR, "hooks");
var REPORTS_DIR = join(OPENCODE_DIR, "reports");
var STATE_DIR = join(OPENCODE_DIR, "state");
var MAILBOX_DIR = join(STATE_DIR, "mailbox");
var STATE_FILE = join(STATE_DIR, "state.json");
var ALLOWED_HOOKS = new Set([
  "00_preflight.sh",
  "01_diff_summary.sh",
  "02_format.sh",
  "03_lint.sh",
  "04_typecheck.sh",
  "05_unit_test.sh",
  "06_integration_test.sh",
  "07_build.sh",
  "08_fail_classifier.py",
  "09_completion_gate.sh"
]);
var BUILDER_EDITABLE_PATTERNS = [
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
  /package\.json$/
];
function ensureDir(dir) {
  if (!existsSync(dir))
    mkdirSync(dir, { recursive: true });
}
function readJson(path, fallback) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return fallback;
  }
}
function writeJson(path, data) {
  ensureDir(resolve(path, ".."));
  writeFileSync(path, JSON.stringify(data, null, 2) + `
`, "utf8");
}
function timestamp() {
  return new Date().toISOString();
}
function runScript(scriptPath, env) {
  const result = spawnSync("bash", [scriptPath], {
    cwd: ROOT,
    env: { ...process.env, ...env },
    encoding: "utf8",
    timeout: 120000
  });
  return {
    exitCode: result.status ?? 1,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? ""
  };
}
function onToolBefore(ctx) {
  const { agentName, toolName, toolInput } = ctx;
  if (!["edit", "write", "multiEdit"].includes(toolName)) {
    return { allow: true };
  }
  const targetPath = toolInput["path"] ?? toolInput["file_path"] ?? "";
  if (targetPath.startsWith(".opencode/")) {
    return { allow: true };
  }
  if (agentName !== "builder") {
    const isSourceFile = BUILDER_EDITABLE_PATTERNS.some((p) => p.test(targetPath));
    if (isSourceFile) {
      return {
        allow: false,
        reason: `[harness] Agent "${agentName}" is not permitted to edit source file "${targetPath}". Only the Builder agent may edit source files.`
      };
    }
  }
  return { allow: true };
}
function onToolAfter(ctx) {
  const { agentName, toolName, toolInput, toolOutput } = ctx;
  if (toolName !== "bash")
    return;
  const cmd = toolInput["command"] ?? "";
  const output = typeof toolOutput === "string" ? toolOutput : JSON.stringify(toolOutput, null, 2);
  ensureDir(REPORTS_DIR);
  const safeCmd = cmd.replace(/[^a-zA-Z0-9_-]/g, "_").slice(0, 40);
  const reportFile = join(REPORTS_DIR, `bash_${agentName}_${safeCmd}_${Date.now()}.md`);
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
function onSessionIdle() {
  const gatePath = join(HOOKS_DIR, "09_completion_gate.sh");
  if (!existsSync(gatePath)) {
    return { gatePassed: false, reportPath: "" };
  }
  const result = runScript(gatePath);
  const reportPath = join(REPORTS_DIR, "completion_gate.md");
  ensureDir(REPORTS_DIR);
  writeFileSync(reportPath, `# Completion Gate Report
- **Time**: ${timestamp()}
- **Exit Code**: ${result.exitCode}

## Output

\`\`\`
${result.stdout}
${result.stderr}
\`\`\`
`, "utf8");
  return {
    gatePassed: result.exitCode === 0,
    reportPath
  };
}
function onSessionStop() {
  const gateResult = onSessionIdle();
  if (!gateResult.gatePassed) {
    ensureDir(MAILBOX_DIR);
    const signalFile = join(MAILBOX_DIR, `restart_signal_${Date.now()}.json`);
    writeJson(signalFile, {
      from: "harness",
      to: "orchestrator",
      type: "gate_failed",
      payload: {
        report_path: gateResult.reportPath,
        message: "Completion gate failed. Continue the loop.",
        timestamp: timestamp()
      }
    });
    return {
      shouldContinue: true,
      signal: `Gate failed. Report: ${gateResult.reportPath}`
    };
  }
  return { shouldContinue: false };
}
function toolRunHook(input) {
  const { hook, env } = input;
  if (!ALLOWED_HOOKS.has(hook)) {
    throw new Error(`Hook "${hook}" is not in the allowed list. Allowed: ${[...ALLOWED_HOOKS].join(", ")}`);
  }
  const hookPath = join(HOOKS_DIR, hook);
  if (!existsSync(hookPath)) {
    throw new Error(`Hook script not found: ${hookPath}`);
  }
  const isPython = hook.endsWith(".py");
  const result = isPython ? spawnSync("python3", [hookPath], {
    cwd: ROOT,
    env: { ...process.env, ...env },
    encoding: "utf8",
    timeout: 120000
  }) : spawnSync("bash", [hookPath], {
    cwd: ROOT,
    env: { ...process.env, ...env },
    encoding: "utf8",
    timeout: 120000
  });
  const exitCode = result.status ?? 1;
  const stdout = result.stdout ?? "";
  const stderr = result.stderr ?? "";
  ensureDir(REPORTS_DIR);
  const hookName = hook.replace(/\.[^.]+$/, "");
  const reportPath = join(REPORTS_DIR, `${hookName}.md`);
  writeFileSync(reportPath, `# Hook Report: ${hook}
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
`, "utf8");
  const statusLabel = exitCode === 0 ? "PASS" : "FAIL";
  const summary = `${statusLabel} (exit ${exitCode}) — report: ${reportPath}`;
  return { exit_code: exitCode, report_path: reportPath, summary, stdout, stderr };
}
function toolReadState(_input) {
  return readJson(STATE_FILE, {
    run_id: null,
    goal: null,
    status: "idle",
    loop_count: 0,
    tasks: [],
    current_task: null,
    last_failure: null,
    updated_at: null
  });
}
function toolWriteState(input) {
  const current = readJson(STATE_FILE, {});
  const next = { ...current, ...input, updated_at: timestamp() };
  ensureDir(STATE_DIR);
  writeJson(STATE_FILE, next);
  return { ok: true, state_path: STATE_FILE };
}
function toolPostMessage(input) {
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
    read: false
  });
  return { ok: true, message_path: messagePath };
}
function toolReadMailbox(input) {
  const { agent, mark_read = true } = input;
  ensureDir(MAILBOX_DIR);
  let files = [];
  try {
    files = readdirSync(MAILBOX_DIR);
  } catch {
    return { messages: [], count: 0 };
  }
  const messages = [];
  for (const file of files.filter((f) => f.startsWith(`${agent}_`))) {
    const msgPath = join(MAILBOX_DIR, file);
    try {
      const msg = readJson(msgPath, {});
      if (!msg.read || !mark_read) {
        messages.push(msg);
        if (mark_read) {
          writeJson(msgPath, { ...msg, read: true, read_at: timestamp() });
        }
      }
    } catch {}
  }
  return { messages, count: messages.length };
}
export {
  toolWriteState,
  toolRunHook,
  toolReadState,
  toolReadMailbox,
  toolPostMessage,
  onToolBefore,
  onToolAfter,
  onSessionStop,
  onSessionIdle
};
