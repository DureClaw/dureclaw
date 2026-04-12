import { spawnSync, execSync } from "child_process";
import { platform, arch } from "os";
import { readFileSync, existsSync } from "fs";
import { join } from "path";

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

/**
 * Detect the preferred AI model for this agent.
 *
 * Priority:
 *   1. PREFERRED_MODEL env override (explicit)
 *   2. gemini CLI or GEMINI_API_KEY → "gemini-2.5-pro"
 *   3. ollama local → "ollama:${OLLAMA_MODEL}"
 *   4. claude-cli → "claude-sonnet-4-6"
 *   5. opencode → "opencode/auto"
 *   6. fallback → "claude-haiku-4-5"
 *
 * This field is broadcast in presence metadata so the orchestrator can
 * route tasks to the most capable available model — matching the
 * Anthropic Managed Agents "agent registry" pattern.
 */
export function detectPreferredModel(): string {
  if (process.env.PREFERRED_MODEL) return process.env.PREFERRED_MODEL;
  if (process.env.GEMINI_API_KEY || has("gemini")) return "gemini-2.5-pro";
  if (has("ollama")) return `ollama:${process.env.OLLAMA_MODEL ?? "gemma4"}`;
  if (has("claude")) return "claude-sonnet-4-6";
  if (has("opencode")) return "opencode/auto";
  return "claude-haiku-4-5";
}

export function detectCapabilities(): string[] {
  const caps: string[] = [];

  caps.push(`os:${platform()}`);
  caps.push(`arch:${arch()}`);

  // RAM tier
  const ram = ramGb();
  if (ram !== null) caps.push(`ram:${ram}g`);

  // AI backends
  if (has("opencode"))       caps.push("opencode");
  if (has("zeroclaw"))       caps.push("zeroclaw");
  if (has("claude"))         caps.push("claude-cli");    // Claude Code CLI
  if (has("gemini"))         caps.push("gemini");        // Google Gemini CLI
  if (has("codex"))          caps.push("codex");         // OpenAI Codex CLI
  if (has("aider"))          caps.push("aider");         // Aider
  if (has("continue"))       caps.push("continue-cli");  // Continue CLI
  if (has("copilot"))        caps.push("copilot-cli");   // GitHub Copilot CLI
  if (has("ollama"))         caps.push("ollama");         // Ollama local LLM

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

  // Windows-specific
  if (platform() === "win32") {
    caps.push(...detectWindowsCaps());
  }

  return caps;
}

// ─── Windows ─────────────────────────────────────────────────────────────────

/** Installed printers via wmic. Returns ["printer:HP LaserJet", ...] */
function windowsPrinters(): string[] {
  const out = exec("wmic printer get Name /format:list");
  return out
    .split(/\r?\n/)
    .map(l => l.match(/^Name=(.+)/)?.[1]?.trim())
    .filter((n): n is string => !!n)
    .map(n => `printer:${n}`);
}

/** Check if an EXE exists under Program Files (x86 + x64) */
function hasWinApp(relPath: string): boolean {
  const roots = [
    process.env["ProgramFiles"]          ?? "C:\\Program Files",
    process.env["ProgramFiles(x86)"]     ?? "C:\\Program Files (x86)",
    process.env["ProgramW6432"]          ?? "C:\\Program Files",
    process.env["LOCALAPPDATA"]          ? join(process.env["LOCALAPPDATA"], "Programs") : "",
  ].filter(Boolean);
  return roots.some(r => existsSync(join(r, relPath)));
}

function detectWindowsCaps(): string[] {
  const caps: string[] = [];

  // Printers (each printer listed individually so orchestrator can target by name)
  caps.push(...windowsPrinters());

  // Microsoft Office suite
  const officeApps: [string, string][] = [
    ["word",      "Microsoft Office\\root\\Office16\\WINWORD.EXE"],
    ["excel",     "Microsoft Office\\root\\Office16\\EXCEL.EXE"],
    ["powerpoint","Microsoft Office\\root\\Office16\\POWERPNT.EXE"],
    ["outlook",   "Microsoft Office\\root\\Office16\\OUTLOOK.EXE"],
    ["access",    "Microsoft Office\\root\\Office16\\MSACCESS.EXE"],
  ];
  const installedOffice = officeApps.filter(([, path]) => hasWinApp(path)).map(([name]) => name);
  if (installedOffice.length > 0) {
    caps.push("ms-office");
    caps.push(...installedOffice.map(n => `office:${n}`));
  }

  // Developer tools
  if (hasWinApp("Microsoft Visual Studio") || has("devenv")) caps.push("visual-studio");
  if (has("code")) caps.push("vscode");
  if (has("winget"))     caps.push("winget");
  if (has("powershell") || has("pwsh")) caps.push("powershell");
  if (has("wsl"))        caps.push("wsl");

  // Adobe
  if (hasWinApp("Adobe\\Acrobat DC\\Acrobat\\Acrobat.exe") ||
      hasWinApp("Adobe\\Acrobat 11.0\\Acrobat\\Acrobat.exe")) caps.push("adobe-acrobat");
  if (hasWinApp("Adobe\\Adobe Photoshop")) caps.push("photoshop");

  return caps;
}
