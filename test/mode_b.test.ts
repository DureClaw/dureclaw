/**
 * Mode B — Distributed infra integration tests
 * Requires Phoenix server running on localhost:4000
 */
import { describe, it, expect, beforeAll } from "bun:test";

const BASE = "http://localhost:4000";

async function get(path: string) {
  const res = await fetch(`${BASE}${path}`);
  return { status: res.status, body: await res.json() };
}

describe("Mode B — Phoenix server", () => {
  it("health check responds OK", async () => {
    const { status, body } = await get("/api/health");
    expect(status).toBe(200);
    expect((body as any).ok).toBe(true);
  });

  it("work-keys endpoint returns array", async () => {
    const { status, body } = await get("/api/work-keys");
    expect(status).toBe(200);
    expect(Array.isArray((body as any).work_keys)).toBe(true);
  });

  it("presence endpoint returns agents array", async () => {
    const { status, body } = await get("/api/presence");
    expect(status).toBe(200);
    expect(Array.isArray((body as any).agents)).toBe(true);
  });

  it("POST /api/task creates task and returns task_id", async () => {
    const res = await fetch(`${BASE}/api/task`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        instructions: "test task from mode_b.test.ts",
        role: "builder",
      }),
    });
    expect(res.status).toBe(201);
    const body = (await res.json()) as any;
    expect(typeof body.task_id).toBe("string");
    expect(typeof body.work_key).toBe("string");
  });

  it("POST /api/task/:id/result stores result", async () => {
    const taskId = `test-${Date.now()}`;
    const res = await fetch(`${BASE}/api/task/${taskId}/result`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ status: "done", output: "unit test result" }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.ok).toBe(true);
    expect(body.task_id).toBe(taskId);
  });
});

describe("Mode B — oah-mcp package", () => {
  it("oah-mcp entry point exists", async () => {
    const { existsSync } = await import("node:fs");
    const { join } = await import("node:path");
    expect(existsSync(join(import.meta.dir, "../packages/oah-mcp/src/index.ts"))).toBe(true);
  });

  it("agent-daemon entry point exists", async () => {
    const { existsSync } = await import("node:fs");
    const { join } = await import("node:path");
    expect(existsSync(join(import.meta.dir, "../packages/agent-daemon/src/index.ts"))).toBe(true);
  });

  it("phoenix-server mix.exs exists", async () => {
    const { existsSync } = await import("node:fs");
    const { join } = await import("node:path");
    expect(existsSync(join(import.meta.dir, "../packages/phoenix-server/mix.exs"))).toBe(true);
  });
});
