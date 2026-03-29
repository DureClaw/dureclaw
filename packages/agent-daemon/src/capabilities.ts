import { spawnSync, execSync } from "child_process";
import { platform, arch } from "os";
import { readFileSync, existsSync } from "fs";

function has(cmd: string): boolean {
  try {
    const isWin = process.platform === "win32";
    const r = spawnSync(isWin ? "where" : "which", [cmd], { stdio: "pipe" });
    return r.status === 0;
  } catch { return false; }
}

function readFileSafe(path: string): string {
  try { return readFileSync(path, "utf8"); } catch { return ""; }
}

function exec(cmd: string): string {
  try { return execSync(cmd, { stdio: "pipe", encoding: "utf8" }).trim(); } catch { return ""; }
}

/** RAM in GB, rounded to nearest common tier (4/8/16/32/64/128) */
function ramGb(): number | null {
  try {
    const os = platform();
    let bytes = 0;
    if (os === "linux") {
      const meminfo = readFileSafe("/proc/meminfo");
      const m = meminfo.match(/MemTotal:\s+(\d+)\s+kB/);
      if (m) bytes = parseInt(m[1]) * 1024;
    } else if (os === "darwin") {
      const out = exec("sysctl -n hw.memsize");
      if (out) bytes = parseInt(out);
    } else if (os === "win32") {
      const out = exec("wmic ComputerSystem get TotalPhysicalMemory /value");
      const m = out.match(/TotalPhysicalMemory=(\d+)/);
      if (m) bytes = parseInt(m[1]);
    }
    if (!bytes) return null;
    return Math.round(bytes / (1024 ** 3));
  } catch { return null; }
}

/** Apple Silicon GPU: macOS + arm64 → Metal GPU available */
function hasAppleGpu(): boolean {
  if (platform() !== "darwin" || arch() !== "arm64") return false;
  // Verify it's actually Apple Silicon (not Rosetta on Intel)
  const brand = exec("sysctl -n machdep.cpu.brand_string");
  return brand.toLowerCase().includes("apple");
}

/**
 * ReSpeaker / USB speakerphone on Linux.
 * Checks /proc/asound/cards for known speakerphone device names.
 * Common devices: ReSpeaker, Jabra, EPOS, Yealink, Poly, PS3 Eye
 */
function hasRpiSpeakerphone(): boolean {
  if (platform() !== "linux") return false;
  const cards = readFileSafe("/proc/asound/cards").toLowerCase();
  const keywords = ["respeaker", "speakerphone", "jabra", "epos", "yealink",
                    "poly", "plantronics", "sennheiser", "logitech", "ps3",
                    "seeed", "wm8960", "googlehome", "microsoftmod"];
  if (keywords.some(k => cards.includes(k))) return true;

  // Also check USB device list for speakerphone VIDs
  const usb = readFileSafe("/sys/bus/usb/devices/usb1/../idVendor")
    || exec("lsusb 2>/dev/null").toLowerCase();
  const usbKeywords = ["respeaker", "jabra", "epos", "yealink", "plantronics", "sennheiser"];
  return usbKeywords.some(k => usb.includes(k));
}

export function detectCapabilities(): string[] {
  const caps: string[] = [];

  caps.push(`os:${platform()}`);
  caps.push(`arch:${arch()}`);

  // RAM tier
  const ram = ramGb();
  if (ram !== null) caps.push(`ram:${ram}g`);

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
  if (hasAppleGpu())     caps.push("apple-gpu");

  // Peripherals
  if (hasRpiSpeakerphone()) caps.push("rpi-speakerphone");

  return caps;
}
