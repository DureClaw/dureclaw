/**
 * reflective_executor.ts — Claude SDK / CLI Autonomous Agent Patterns
 *
 * Supports three execution backends (auto-detected by priority):
 *   1. claude -p  (Claude Code CLI — uses existing OAuth, no API key needed)
 *   2. Anthropic SDK  (ANTHROPIC_API_KEY env var)
 *   3. OpenAI SDK  (OPENAI_API_KEY env var, e.g. GPT-4o)
 *
 * Architecture:
 *   Phoenix Channel (coordination)
 *       ↓ task.assign
 *   ReflectiveExecutor  [auto-picks backend]
 *       ↓ attempt 1..N
 *   [claude -p | Anthropic SDK | OpenAI SDK]
 *       ↓ [BLOCKED] detected
 *   UnstuckHandler (4 escape strategies)
 *       ↓ still blocked after all strategies
 *   task.blocked → Phoenix → orchestrator escalation
 *
 * Key safeguards (from real-world multi-agent lessons):
 *   - Hard max_attempts to prevent Amnesia Loop ($235+ token blowouts)
 *   - History length cap to avoid context saturation
 *   - Progress reporting every 10s back to Phoenix Channel
 */

import Anthropic from "@anthropic-ai/sdk";
import { spawn } from "bun";

// ─── Types ────────────────────────────────────────────────────────────────────

export interface AgentState {
  task: string;
  role: string;
  context: Record<string, unknown>;
  attempts: number;
  history: string[];        // summary of each attempt (capped at 500 chars each)
  lastError: string | null;
  isStuck: boolean;
  solved: boolean;
  tokenCount: number;       // running total for cost guard
}

export interface ReflectiveResult {
  output: string;
  solved: boolean;
  attempts: number;
  escalated: boolean;
  tokenCount: number;
}

export type ProgressCallback = (message: string, output_tail: string) => void;

// ─── Config ───────────────────────────────────────────────────────────────────

/** Absolute maximum API attempts to prevent Amnesia Loop */
const MAX_ATTEMPTS = 5;

/** Max tokens across all attempts before forcing escalation */
const MAX_TOKEN_BUDGET = 80_000;

/** Max chars to keep per history entry (prevent context saturation) */
const MAX_HISTORY_ENTRY_CHARS = 500;

/** Max history entries to include in next prompt */
const MAX_HISTORY_ENTRIES = 3;

/** Role-specific system prompts for analysis agents */
const ROLE_SYSTEM_PROMPTS: Record<string, string> = {
  "code-expert": `You are a code analysis expert specializing in ML/AI repositories.
Analyze code structure, notebook quality, and agenda alignment.
- Use [SOLVED] when analysis is complete with evidence
- Use [BLOCKED: <specific reason>] when you cannot proceed
- Use [ESCALATE: <reason>] only for unresolvable blockers requiring human input
Output your findings as structured markdown. Be specific about file:line references.`,

  "mfg-expert": `You are a manufacturing AI domain expert.
Analyze repositories for manufacturing domain applicability, standards compliance, and edge deployment readiness.
- Use [SOLVED] when analysis is complete
- Use [BLOCKED: <reason>] for specific obstacles
- Use [ESCALATE: <reason>] for human-required decisions
Reference ISO standards, IEC specs, and manufacturing AI best practices.`,

  "curriculum-expert": `You are an educational curriculum expert specializing in technical ML courses.
Assess learning objectives, Bloom's taxonomy coverage, prerequisite sequencing, and pedagogical quality.
- Use [SOLVED] when assessment is complete
- Use [BLOCKED: <reason>] for missing materials or context
- Use [ESCALATE: <reason>] for fundamental curriculum design issues`,

  "visual-feedback": `You are a visual quality and accessibility expert for technical notebooks.
Evaluate figure quality, color accessibility, layout consistency, and learning effectiveness of visuals.
- Use [SOLVED] when visual assessment is complete
- Use [BLOCKED: <reason>] for missing rendered outputs
- Use [ESCALATE: <reason>] for manual visual review requirements`,

  "executor": `You are a notebook execution specialist.
Execute Jupyter notebooks, verify outputs, check model convergence, and identify runtime errors.
- Use [SOLVED] when all notebooks are executed and verified
- Use [BLOCKED: <reason>] for environment issues or missing dependencies
- Use [ESCALATE: <reason>] for environment setup requiring human intervention`,

  "learner-simulator": `You are simulating a learner with intermediate Python skills but no ML background.
Identify confusion points, missing prerequisites, jargon, and likely drop-off moments.
- Use [SOLVED] when learner experience assessment is complete
- Use [BLOCKED: <reason>] for content too advanced to simulate
- Use [ESCALATE: <reason>] for required learner testing`,

  "orchestrator": `You are the Orchestrator coordinating a multi-agent analysis pipeline.
Decompose goals, dispatch Phase 1/2 agents, merge results, and synthesize final reports.
- Use [SOLVED] when all phases are complete and results merged
- Use [BLOCKED: <reason>] for coordination failures
- Use [ESCALATE: <reason>] for unresolvable agent conflicts`,

  "default": `You are an autonomous agent in the open-agent-harness system.
Complete your assigned task efficiently and autonomously.
- Use [SOLVED] when task is complete
- Use [BLOCKED: <reason>] when you cannot proceed
- Use [ESCALATE: <reason>] when human intervention is required`,
};

/** Escape strategies when stuck — applied in order */
const UNSTUCK_STRATEGIES = [
  "문제를 3개의 더 작은 하위 문제로 분해하고 각각 해결하라 (Decompose into 3 sub-problems)",
  "완전히 다른 접근법을 사용하라. 현재 방법 대신 가장 단순한 방법부터 시작하라 (Try completely different approach, start with simplest)",
  "최소한 작동하는 부분만 구현하고 나머지는 TODO로 명시하라 (Implement minimum working version, mark rest as TODO)",
  "제약 조건을 완화하라. 단순화된 버전으로 분석하고 한계를 명시하라 (Relax constraints, analyze simplified version with stated limitations)",
];

// ─── Backend detection ────────────────────────────────────────────────────────

type Backend = "claude-cli" | "anthropic-sdk" | "openai-sdk";

let _detectedBackend: Backend | null = null;

async function detectBackend(): Promise<Backend> {
  if (_detectedBackend) return _detectedBackend;

  // Priority 1: claude CLI (uses existing OAuth — no API key needed)
  const claudeBin = process.env.CLAUDE_BIN ?? "claude";
  try {
    const proc = spawn({ cmd: [claudeBin, "--version"], stdout: "pipe", stderr: "pipe" });
    await proc.exited;
    if (proc.exitCode === 0) {
      console.log(`[executor] backend: claude-cli (${claudeBin})`);
      _detectedBackend = "claude-cli";
      return "claude-cli";
    }
  } catch { /* claude not installed */ }

  // Priority 2: Anthropic SDK
  if (process.env.ANTHROPIC_API_KEY) {
    console.log("[executor] backend: anthropic-sdk");
    _detectedBackend = "anthropic-sdk";
    return "anthropic-sdk";
  }

  // Priority 3: OpenAI SDK
  if (process.env.OPENAI_API_KEY) {
    console.log("[executor] backend: openai-sdk");
    _detectedBackend = "openai-sdk";
    return "openai-sdk";
  }

  throw new Error(
    "No LLM backend available.\n" +
    "Options:\n" +
    "  1. claude CLI:   install Claude Code (already authenticated via OAuth)\n" +
    "  2. Anthropic SDK: set ANTHROPIC_API_KEY=sk-ant-...\n" +
    "  3. OpenAI SDK:    set OPENAI_API_KEY=sk-..."
  );
}

// ─── Anthropic SDK client ─────────────────────────────────────────────────────

let _anthropicClient: Anthropic | null = null;

function getAnthropicClient(): Anthropic {
  if (!_anthropicClient) {
    _anthropicClient = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
  }
  return _anthropicClient;
}

// ─── claude -p CLI backend ────────────────────────────────────────────────────

interface CliResult {
  text: string;
  tokenCount: number;
}

/**
 * Run `claude -p <prompt>` and return the text output.
 * Uses --output-format stream-json for incremental progress.
 */
async function runClaudeCli(
  userPrompt: string,
  systemPrompt: string,
  role: string,
  onProgress?: ProgressCallback,
): Promise<CliResult> {
  const claudeBin = process.env.CLAUDE_BIN ?? "claude";
  const model = selectModel(role);

  const args = [
    "-p", userPrompt,
    "--append-system-prompt", systemPrompt,
    "--output-format", "stream-json",
    "--verbose",                       // required for stream-json
    "--model", model,
    "--dangerously-skip-permissions",  // non-interactive mode
  ];

  const proc = spawn({
    cmd: [claudeBin, ...args],
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env },
  });

  let fullText = "";
  let tokenCount = 0;
  let lastProgress = Date.now();
  let lineBuffer = "";

  const reader = proc.stdout.getReader();
  const decoder = new TextDecoder();

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      lineBuffer += decoder.decode(value);

      // Process complete lines
      const lines = lineBuffer.split("\n");
      lineBuffer = lines.pop() ?? ""; // keep incomplete last line

      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        try {
          const event = JSON.parse(trimmed) as Record<string, unknown>;
          const type = event.type as string;

          if (type === "assistant") {
            // Accumulate text from assistant message content blocks
            const msg = event.message as { content?: Array<{ type: string; text?: string }> };
            for (const block of msg?.content ?? []) {
              if (block.type === "text" && block.text) {
                fullText += block.text;
              }
            }
          } else if (type === "result") {
            // Final event: extract usage tokens
            // Note: result.result is typically empty in stream-json mode.
            // The actual text is accumulated from assistant events above.
            const usage = event.usage as { input_tokens?: number; output_tokens?: number } | undefined;
            tokenCount = (usage?.input_tokens ?? 0) + (usage?.output_tokens ?? 0);
          }
        } catch { /* non-JSON line, skip */ }
      }

      // Progress callback every 10s
      if (Date.now() - lastProgress > 10_000) {
        lastProgress = Date.now();
        onProgress?.("Working...", fullText.slice(-300));
      }
    }
  } catch { /* stream closed */ }

  await proc.exited;

  return { text: fullText, tokenCount };
}

// ─── OpenAI SDK backend ───────────────────────────────────────────────────────

async function runOpenAI(
  userPrompt: string,
  systemPrompt: string,
  role: string,
): Promise<CliResult> {
  // Lazy import — only if OPENAI_API_KEY is set
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let OpenAI: any;
  try {
    const mod = await import("openai");
    OpenAI = mod.default;
  } catch {
    throw new Error("openai package not installed. Run: bun add openai");
  }

  const client = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
  const oaiModel = role === "orchestrator" ? "gpt-4o" : "gpt-4o-mini";

  const response = await client.chat.completions.create({
    model: oaiModel,
    messages: [
      { role: "system", content: systemPrompt },
      { role: "user", content: userPrompt },
    ],
    max_tokens: 4096,
  });

  const text = response.choices[0]?.message?.content ?? "";
  const tokenCount = (response.usage?.prompt_tokens ?? 0) + (response.usage?.completion_tokens ?? 0);
  return { text, tokenCount };
}

// ─── Unified LLM call (backend-agnostic) ─────────────────────────────────────

/**
 * Call the appropriate LLM backend and return text + token count.
 * Backend priority: claude-cli → anthropic-sdk → openai-sdk
 */
async function callLLM(
  userPrompt: string,
  systemPrompt: string,
  role: string,
  onProgress?: ProgressCallback,
): Promise<CliResult> {
  const backend = await detectBackend();

  switch (backend) {
    case "claude-cli":
      return runClaudeCli(userPrompt, systemPrompt, role, onProgress);

    case "anthropic-sdk": {
      const client = getAnthropicClient();
      const response = await client.messages.create({
        model: selectModel(role),
        max_tokens: 4096,
        thinking: { type: "enabled", budget_tokens: 2048 },
        system: systemPrompt,
        messages: [{ role: "user", content: userPrompt }],
      });
      const textBlocks = response.content.filter(b => b.type === "text");
      const text = textBlocks.map(b => (b as { text: string }).text).join("\n");
      const tokenCount = (response.usage?.input_tokens ?? 0) + (response.usage?.output_tokens ?? 0);
      return { text, tokenCount };
    }

    case "openai-sdk":
      return runOpenAI(userPrompt, systemPrompt, role);
  }
}

// ─── Core: Reflective Agent ────────────────────────────────────────────────────

/**
 * Execute a task using the auto-detected LLM backend with self-reflection.
 *
 * Backend priority (no config needed):
 *   1. claude -p  (if Claude Code is installed — uses existing OAuth)
 *   2. Anthropic SDK  (if ANTHROPIC_API_KEY is set)
 *   3. OpenAI SDK  (if OPENAI_API_KEY is set)
 *
 * Each attempt includes the history of previous failures so Claude can
 * adopt a different strategy. Stops at MAX_ATTEMPTS or MAX_TOKEN_BUDGET.
 */
export async function reflectiveAgent(
  task: string,
  role: string,
  context: Record<string, unknown> = {},
  onProgress?: ProgressCallback,
  maxAttempts = MAX_ATTEMPTS,
): Promise<ReflectiveResult> {
  const state: AgentState = {
    task,
    role,
    context,
    attempts: 0,
    history: [],
    lastError: null,
    isStuck: false,
    solved: false,
    tokenCount: 0,
  };

  const systemPrompt = ROLE_SYSTEM_PROMPTS[role] ?? ROLE_SYSTEM_PROMPTS["default"];
  const contextStr = Object.keys(context).length > 0
    ? `\n\nContext:\n${JSON.stringify(context, null, 2)}`
    : "";

  while (state.attempts < maxAttempts && !state.solved) {
    state.attempts++;

    // Guard: token budget
    if (state.tokenCount >= MAX_TOKEN_BUDGET) {
      console.warn(`[reflective] token budget exceeded (${state.tokenCount}/${MAX_TOKEN_BUDGET})`);
      return {
        output: `[BLOCKED: token budget exceeded after ${state.attempts} attempts]`,
        solved: false,
        attempts: state.attempts,
        escalated: false,
        tokenCount: state.tokenCount,
      };
    }

    // Build reflection context from previous failures
    let reflectionContext = "";
    if (state.history.length > 0) {
      const recentHistory = state.history.slice(-MAX_HISTORY_ENTRIES);
      reflectionContext = `
이전 시도들 (Previous attempts):
${recentHistory.map((h, i) => `시도 ${state.attempts - recentHistory.length + i}: ${h}`).join("\n")}

위 시도들이 불완전했습니다. 다른 접근법을 사용하세요.
(Previous attempts were incomplete. Use a different approach.)
`;
    }

    const userMessage = `${reflectionContext}
현재 과제 (Current task): ${task}${contextStr}

완료 시 [SOLVED] 태그를 포함하세요.
막히면 [BLOCKED: 구체적인 이유]를 출력하세요.
사람 개입이 필요하면 [ESCALATE: 이유]를 출력하세요.`;

    onProgress?.(`Attempt ${state.attempts}/${maxAttempts}`, `Starting ${role} analysis...`);
    console.log(`[reflective] attempt ${state.attempts}/${maxAttempts} for ${role}`);

    try {
      const { text: result, tokenCount: tokens } = await callLLM(
        userMessage, systemPrompt, role, onProgress,
      );
      state.tokenCount += tokens;

      // Trim and store history entry
      state.history.push(result.slice(0, MAX_HISTORY_ENTRY_CHARS));

      onProgress?.(`Attempt ${state.attempts} complete`, result.slice(-300));

      if (result.includes("[SOLVED]")) {
        state.solved = true;
        return { output: result, solved: true, attempts: state.attempts, escalated: false, tokenCount: state.tokenCount };
      }

      if (result.includes("[ESCALATE")) {
        console.log(`[reflective] escalation requested at attempt ${state.attempts}`);
        return { output: result, solved: false, attempts: state.attempts, escalated: true, tokenCount: state.tokenCount };
      }

      if (result.includes("[BLOCKED")) {
        state.lastError = result;
        state.isStuck = true;
        console.log(`[reflective] blocked at attempt ${state.attempts}: ${result.slice(0, 100)}`);
        // Continue loop to retry with different approach
      }

    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      console.error(`[reflective] API error at attempt ${state.attempts}: ${errMsg}`);
      state.history.push(`API Error: ${errMsg.slice(0, 200)}`);
      state.lastError = errMsg;
    }
  }

  // All attempts exhausted — try unstuck strategies
  if (state.isStuck || state.attempts >= maxAttempts) {
    return handleStuck(state, onProgress);
  }

  return {
    output: state.history[state.history.length - 1] ?? "[No output]",
    solved: false,
    attempts: state.attempts,
    escalated: false,
    tokenCount: state.tokenCount,
  };
}

// ─── Stuck Handler ─────────────────────────────────────────────────────────────

/**
 * When the reflective agent is stuck, rotate through 4 escape strategies.
 * Each strategy gives Claude a different frame to approach the problem.
 */
async function handleStuck(
  state: AgentState,
  onProgress?: ProgressCallback,
): Promise<ReflectiveResult> {
  const systemPrompt = ROLE_SYSTEM_PROMPTS[state.role] ?? ROLE_SYSTEM_PROMPTS["default"];

  console.log(`[unstuck] trying ${UNSTUCK_STRATEGIES.length} escape strategies`);

  for (let i = 0; i < UNSTUCK_STRATEGIES.length; i++) {
    const strategy = UNSTUCK_STRATEGIES[i];

    // Guard: token budget
    if (state.tokenCount >= MAX_TOKEN_BUDGET) {
      break;
    }

    onProgress?.(`Unstuck strategy ${i + 1}/${UNSTUCK_STRATEGIES.length}`, strategy);
    console.log(`[unstuck] strategy ${i + 1}: ${strategy.slice(0, 60)}`);

    const recentHistory = state.history.slice(-MAX_HISTORY_ENTRIES);
    const userMessage = `
원래 과제: ${state.task}

이전에 ${state.attempts}번 시도했지만 실패:
${recentHistory.join("\n")}

마지막 오류: ${state.lastError ?? "unknown"}

탈출 전략: ${strategy}

이 전략을 적용해 과제를 해결하라.
해결되면 [SOLVED]를 포함하라.
이 전략도 불가능하면 [SKIP]을 붙여라.`;

    try {
      const { text: result, tokenCount: tokens } = await callLLM(
        userMessage, systemPrompt, state.role, onProgress,
      );
      state.tokenCount += tokens;

      if (result.includes("[SOLVED]")) {
        console.log(`[unstuck] solved with strategy ${i + 1}`);
        return { output: result, solved: true, attempts: state.attempts + i + 1, escalated: false, tokenCount: state.tokenCount };
      }

      if (result.includes("[ESCALATE")) {
        return { output: result, solved: false, attempts: state.attempts + i + 1, escalated: true, tokenCount: state.tokenCount };
      }

      // [SKIP] or still blocked → try next strategy
      state.history.push(result.slice(0, MAX_HISTORY_ENTRY_CHARS));

    } catch (err) {
      console.error(`[unstuck] strategy ${i + 1} API error: ${err}`);
    }
  }

  // All strategies exhausted
  const escalateMsg = `[ESCALATE] 자동 해결 불가. 사람 개입 필요.
Task: ${state.task}
Attempts: ${state.attempts}
Last error: ${state.lastError}
Strategies tried: ${UNSTUCK_STRATEGIES.length}`;

  console.log(`[unstuck] all strategies exhausted — escalating`);
  return { output: escalateMsg, solved: false, attempts: state.attempts, escalated: true, tokenCount: state.tokenCount };
}

// ─── Model Selection ───────────────────────────────────────────────────────────

/**
 * Select Claude model based on agent role.
 * Orchestrator / synthesis uses Opus; subagents use Sonnet for cost efficiency.
 */
function selectModel(role: string): string {
  const opusRoles = ["orchestrator", "code-expert"];
  return opusRoles.includes(role) ? "claude-opus-4-6" : "claude-sonnet-4-6";
}

// ─── Phase Orchestration ──────────────────────────────────────────────────────

export interface PhaseResult {
  agentRole: string;
  output: string;
  solved: boolean;
  escalated: boolean;
  tokenCount: number;
}

/**
 * Run Phase 1 agents in parallel using Claude SDK directly.
 * Used by orchestrator when Phase 1 agents are on the same machine.
 * For distributed (multi-machine) mode, use Phoenix Channel task.assign instead.
 */
export async function runPhase1Parallel(
  task: string,
  context: Record<string, unknown>,
  onProgress?: ProgressCallback,
): Promise<PhaseResult[]> {
  console.log("[phase1] starting parallel analysis (code-expert, mfg-expert, curriculum-expert)");

  const phase1Roles = ["code-expert", "mfg-expert", "curriculum-expert"];

  const results = await Promise.all(
    phase1Roles.map(async (role) => {
      const result = await reflectiveAgent(task, role, context, onProgress);
      return { agentRole: role, ...result };
    }),
  );

  const escalated = results.filter(r => r.escalated);
  if (escalated.length > 0) {
    console.warn(`[phase1] ${escalated.length} agents escalated: ${escalated.map(r => r.role).join(", ")}`);
  }

  const totalTokens = results.reduce((sum, r) => sum + r.tokenCount, 0);
  console.log(`[phase1] complete — total tokens: ${totalTokens} (~$${(totalTokens * 0.000015).toFixed(2)})`);

  return results;
}

/**
 * Run Phase 2 agents in parallel, injecting Phase 1 results as context.
 */
export async function runPhase2Parallel(
  task: string,
  phase1Results: PhaseResult[],
  onProgress?: ProgressCallback,
): Promise<PhaseResult[]> {
  console.log("[phase2] starting parallel evaluation (visual-feedback, executor, learner-simulator)");

  // Build shared context from Phase 1 results
  const phase1Context: Record<string, unknown> = {};
  for (const r of phase1Results) {
    phase1Context[r.agentRole.replace("-", "_")] = r.output.slice(0, 3000);
  }

  const phase2Roles = ["visual-feedback", "executor", "learner-simulator"];

  const results = await Promise.all(
    phase2Roles.map(async (role) => {
      const context = { phase1_results: phase1Context };
      const result = await reflectiveAgent(task, role, context, onProgress);
      return { agentRole: role, ...result };
    }),
  );

  const totalTokens = results.reduce((sum, r) => sum + r.tokenCount, 0);
  console.log(`[phase2] complete — total tokens: ${totalTokens} (~$${(totalTokens * 0.000015).toFixed(2)})`);

  return results;
}

/**
 * Full autonomous pipeline: Supervisor → Phase 1 (parallel) → Phase 2 (parallel) → Synthesis
 *
 * For distributed mode across machines, call this on the orchestrator node only.
 * Phase 1/2 agents on remote nodes are coordinated via Phoenix Channel task.assign.
 */
export async function autonomousPipeline(
  goal: string,
  context: Record<string, unknown> = {},
  onProgress?: ProgressCallback,
  maxIterations = 3,
): Promise<{
  goal: string;
  phase1: PhaseResult[];
  phase2: PhaseResult[];
  synthesis: string;
  success: boolean;
  totalTokens: number;
  iterations: number;
}> {
  let iteration = 0;
  let phase1: PhaseResult[] = [];
  let phase2: PhaseResult[] = [];

  while (iteration < maxIterations) {
    iteration++;
    console.log(`\n[pipeline] iteration ${iteration}/${maxIterations}`);
    onProgress?.(`Pipeline iteration ${iteration}/${maxIterations}`, "Starting...");

    // Phase 1: Parallel analysis
    phase1 = await runPhase1Parallel(goal, context, onProgress);

    // Phase 2: Parallel evaluation with Phase 1 context
    phase2 = await runPhase2Parallel(goal, phase1, onProgress);

    // Check if all non-escalated agents succeeded
    const allResults = [...phase1, ...phase2];
    const escalated = allResults.filter(r => r.escalated);
    const solved = allResults.filter(r => r.solved);

    console.log(`[pipeline] iteration ${iteration}: solved=${solved.length}/${allResults.length}, escalated=${escalated.length}`);

    // If majority solved and no critical escalations, break
    if (solved.length >= allResults.length * 0.7 && escalated.length === 0) {
      break;
    }

    if (escalated.length > 0) {
      console.warn(`[pipeline] escalations detected — stopping iteration`);
      break;
    }
  }

  // Synthesis: merge all results
  const synthesisResult = await reflectiveAgent(
    `Synthesize the following analysis results for goal: ${goal}

Phase 1 (Analysis):
${phase1.map(r => `## ${r.agentRole}\n${r.output.slice(0, 2000)}`).join("\n\n")}

Phase 2 (Evaluation):
${phase2.map(r => `## ${r.agentRole}\n${r.output.slice(0, 2000)}`).join("\n\n")}

Produce a final synthesis report that:
1. Summarizes key findings from all 6 agents
2. Identifies critical gaps and recommendations
3. Ranks issues by priority (P0/P1/P2)
4. Provides a go/no-go recommendation for the content`,
    "orchestrator",
    {},
    onProgress,
    3, // fewer retries for synthesis
  );

  const allResults = [...phase1, ...phase2];
  const totalTokens = allResults.reduce((sum, r) => sum + r.tokenCount, 0) + synthesisResult.tokenCount;

  console.log(`\n[pipeline] complete — ${iteration} iterations, ${totalTokens} total tokens (~$${(totalTokens * 0.000015).toFixed(2)})`);

  return {
    goal,
    phase1,
    phase2,
    synthesis: synthesisResult.output,
    success: !allResults.some(r => r.escalated),
    totalTokens,
    iterations: iteration,
  };
}
