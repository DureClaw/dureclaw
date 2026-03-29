import Anthropic from "@anthropic-ai/sdk";

export interface SubTask {
  instructions: string;
  target_agent?: string;   // specific agent name, or undefined for broadcast
  role?: string;           // target role
  depends_on?: string[];   // task IDs that must complete first
  priority?: number;
}

export interface OrchestrationPlan {
  goal: string;
  subtasks: SubTask[];
  reasoning: string;
}

export async function orchestrateGoal(
  goal: string,
  builders: Array<{ name: string; capabilities: string[]; role: string; os: string }>,
  onProgress: (msg: string) => void,
): Promise<OrchestrationPlan> {
  const client = new Anthropic();

  const buildersDesc = builders.map(b =>
    `- ${b.name} [${b.role}] os=${b.os} caps=[${b.capabilities.join(",")}]`
  ).join("\n");

  onProgress("Analyzing goal with Claude...");

  const msg = await client.messages.create({
    model: "claude-haiku-4-5-20251001",
    max_tokens: 2048,
    system: `You are an AI orchestrator for a distributed multi-agent system.
Given a goal and available builders, decompose it into parallel subtasks.
Assign each subtask to the most appropriate builder based on their capabilities.

Rules:
- Prefer parallel tasks where possible (no unnecessary serial dependencies)
- Match tasks to builder capabilities (e.g., audio→audio cap, GPU tasks→nvidia-gpu)
- Keep instructions specific and actionable
- Output ONLY valid JSON, no markdown

Output format:
{
  "reasoning": "brief explanation of decomposition strategy",
  "subtasks": [
    {
      "instructions": "specific task instructions",
      "target_agent": "builder@machine or null for best-fit",
      "role": "builder",
      "depends_on": [],
      "priority": 1
    }
  ]
}`,
    messages: [{
      role: "user",
      content: `Goal: ${goal}\n\nAvailable builders:\n${buildersDesc}`
    }]
  });

  const text = msg.content[0].type === "text" ? msg.content[0].text : "";

  try {
    // Strip any markdown code fences if present
    const cleaned = text.replace(/```json\n?/g, "").replace(/```\n?/g, "").trim();
    const parsed = JSON.parse(cleaned);
    return {
      goal,
      reasoning: parsed.reasoning ?? "",
      subtasks: parsed.subtasks ?? [],
    };
  } catch {
    // Fallback: single task broadcast
    return {
      goal,
      reasoning: "JSON parse failed, falling back to broadcast",
      subtasks: [{ instructions: goal, role: "builder" }],
    };
  }
}
