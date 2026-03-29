/**
 * spawn compatibility shim — works on both Bun and Node.js (for 32-bit ARM)
 * Bun's spawn API: { cmd, cwd, stdout, stderr, env }
 * Returns: { stdout: ReadableStream, stderr: ReadableStream, exited: Promise<number> }
 */

type SpawnOpts = {
  cmd: string[];
  cwd?: string;
  stdout?: "pipe" | "inherit" | "ignore";
  stderr?: "pipe" | "inherit" | "ignore";
  env?: Record<string, string>;
};

type SpawnResult = {
  stdout: ReadableStream<Uint8Array> | null;
  stderr: ReadableStream<Uint8Array> | null;
  exited: Promise<number>;
};

const isBun = typeof (globalThis as any).Bun !== "undefined";

export function spawnCompat(opts: SpawnOpts): SpawnResult {
  if (isBun) {
    // Use Bun's native spawn
    const { spawn } = require("bun");
    return spawn(opts) as SpawnResult;
  }

  // Node.js fallback
  const { spawn } = require("child_process") as typeof import("child_process");
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

  const exited = new Promise<number>((resolve) => {
    proc.on("close", (code: number | null) => resolve(code ?? 1));
  });

  return {
    stdout: toReadable(proc.stdout),
    stderr: toReadable(proc.stderr),
    exited,
  };
}
