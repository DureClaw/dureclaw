/**
 * Mode A — Local harness smoke tests
 * Tests that core hooks and plugin structure are intact.
 */
import { describe, it, expect } from "bun:test";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { $ } from "bun";

const ROOT = join(import.meta.dir, "..");

describe("Mode A — Local harness", () => {
  it("plugin file exists", () => {
    expect(existsSync(join(ROOT, ".opencode/plugins/harness.ts"))).toBe(true);
  });

  it("all 10 hooks exist", () => {
    const hooks = [
      "_lib.sh",
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
    ];
    for (const h of hooks) {
      expect(existsSync(join(ROOT, ".opencode/hooks", h))).toBe(true);
    }
  });

  it("all 5 agent definitions exist", () => {
    const agents = [
      "orchestrator.md",
      "planner.md",
      "builder.md",
      "verifier.md",
      "reviewer.md",
    ];
    for (const a of agents) {
      expect(existsSync(join(ROOT, ".opencode/agents", a))).toBe(true);
    }
  });

  it("preflight hook exits 0", async () => {
    const result = await $`bash .opencode/hooks/00_preflight.sh`.cwd(ROOT).quiet().nothrow();
    expect(result.exitCode).toBe(0);
  });

  it("typecheck passes", async () => {
    const result = await $`bun run typecheck`.cwd(ROOT).quiet().nothrow();
    expect(result.exitCode).toBe(0);
  });
});
