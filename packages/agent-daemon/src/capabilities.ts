import { spawnSync } from "child_process";
import { platform, arch } from "os";

function has(cmd: string): boolean {
  try {
    const isWin = process.platform === "win32";
    const r = spawnSync(isWin ? "where" : "which", [cmd], { stdio: "pipe" });
    return r.status === 0;
  } catch { return false; }
}

export function detectCapabilities(): string[] {
  const caps: string[] = [];
  caps.push(`os:${platform()}`);
  caps.push(`arch:${arch()}`);
  // AI backends
  if (has("opencode"))  caps.push("opencode");
  if (has("zeroclaw"))  caps.push("zeroclaw");
  if (has("claude"))    caps.push("claude-cli");
  // Runtimes
  if (has("python3") || has("python")) caps.push("python");
  if (has("node"))      caps.push("node");
  if (has("bun"))       caps.push("bun");
  if (has("deno"))      caps.push("deno");
  // DevOps
  if (has("docker"))    caps.push("docker");
  if (has("git"))       caps.push("git");
  if (has("kubectl"))   caps.push("kubectl");
  // Media
  if (has("ffmpeg"))    caps.push("ffmpeg");
  if (has("aplay") || has("afplay")) caps.push("audio");
  // GPU
  if (has("nvidia-smi")) caps.push("nvidia-gpu");
  return caps;
}
