/**
 * spawn compatibility shim — works on both Bun and Node.js (for 32-bit ARM)
 * Bun's spawn API: { cmd, cwd, stdout, stderr, env }
 * Returns: { stdout, stderr, exited, exitCode, kill } — the subset of Bun's Subprocess we use
 */

import { createRequire } from "node:module";

// This file is ESM: a bare require() exists under Bun but not under Node, which
// made the Node fallback throw on every spawn. createRequire works in both.
const requireCompat = createRequire(import.meta.url);

type SpawnOpts = {
  cmd: string[];
  cwd?: string;
  stdout?: "pipe" | "inherit" | "ignore";
  stderr?: "pipe" | "inherit" | "ignore";
  env?: Record<string, string | undefined>;
};

export type SpawnResult = {
  stdout: ReadableStream<Uint8Array> | null;
  stderr: ReadableStream<Uint8Array> | null;
  exited: Promise<number>;
  /** null while running */
  readonly exitCode: number | null;
  kill(): void;
};

const isBun = typeof (globalThis as any).Bun !== "undefined";

export function spawnCompat(opts: SpawnOpts): SpawnResult {
  if (isBun) {
    // Use Bun's native spawn
    const { spawn } = requireCompat("bun");
    return spawn(opts) as SpawnResult;
  }

  // Node.js fallback
  const { spawn } = requireCompat("node:child_process") as typeof import("node:child_process");
  const [cmd, ...args] = opts.cmd;
  const proc = spawn(cmd, args, {
    cwd: opts.cwd,
    env: (opts.env ?? process.env) as NodeJS.ProcessEnv,
    stdio: ["ignore", opts.stdout ?? "pipe", opts.stderr ?? "pipe"],
  });

  const toReadable = (stream: NodeJS.ReadableStream | null): ReadableStream<Uint8Array> | null => {
    if (!stream) return null;
    return new ReadableStream<Uint8Array>({
      start(controller) {
        stream.on("data", (chunk: Buffer) => controller.enqueue(new Uint8Array(chunk)));
        stream.on("end", () => controller.close());
        stream.on("error", (e: Error) => controller.error(e));
      },
    });
  };

  let exitCode: number | null = null;
  const exited = new Promise<number>((resolve) => {
    proc.on("close", (code: number | null) => {
      exitCode = code ?? 1;
      resolve(exitCode);
    });
  });

  // Node fallback used to lack kill()/exitCode: the task watchdog's kill threw
  // (swallowed) and claude-cli detection always failed on Node-only nodes.
  return {
    stdout: toReadable(proc.stdout),
    stderr: toReadable(proc.stderr),
    exited,
    get exitCode() { return exitCode; },
    kill: () => { proc.kill(); },
  };
}
