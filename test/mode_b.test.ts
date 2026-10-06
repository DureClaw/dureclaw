/**
 * Mode B — distributed infra package checks.
 *
 * The live-server HTTP checks that used to live here assumed an unauthenticated
 * server already running on :4000. They are superseded by the ExUnit suite in
 * packages/phoenix-server/test (auth, enrollment, work keys, dispatch → result
 * over the channel), which boots the server in-process and runs in CI.
 */
import { describe, it, expect } from "bun:test";

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
