/**
 * E2E smoke — 실제로 떠 있는 서버 + 노드에 작업을 지시하고 결과를 확인한다.
 * CI(.github/workflows/e2e.yml)에서 OS 별로 서버·노드를 띄운 뒤 호출한다.
 *
 *   bun test/e2e/smoke.ts --server http://127.0.0.1:4000 [--token SECRET] \
 *     --agent builder@ci --cmd "[SHELL] echo hi" --expect hi [--timeout 120]
 *
 *   --ensure-wk-only   서버 health 대기 + Work Key 보장만 하고 끝낸다
 *   --expect-wk        Work Key 를 만들지 않고, 이미 있어야 함을 검사한다(Mac 앱 자동 생성 확인)
 *   --absent           에이전트가 presence 에서 사라졌는지만 확인한다(제거 검증)
 */
import { parseArgs } from "node:util";

const { values: a } = parseArgs({
  options: {
    server: { type: "string", default: "http://127.0.0.1:4000" },
    token: { type: "string", default: "" },
    agent: { type: "string", default: "" },
    cmd: { type: "string", default: "" },
    expect: { type: "string", default: "" },
    timeout: { type: "string", default: "120" },
    "ensure-wk-only": { type: "boolean", default: false },
    "expect-wk": { type: "boolean", default: false },
    absent: { type: "boolean", default: false },
  },
});

const base = a.server!.replace(/\/$/, "");
const deadline = Date.now() + Number(a.timeout) * 1000;
const headers: Record<string, string> = { "content-type": "application/json" };
if (a.token) headers.authorization = `Bearer ${a.token}`;

const log = (...m: unknown[]) => console.log("[smoke]", ...m);
function fail(msg: string): never {
  console.error(`[smoke] FAIL: ${msg}`);
  process.exit(1);
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function call(method: string, path: string, body?: unknown) {
  const res = await fetch(base + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const text = await res.text();
  let json: any = null;
  try { json = JSON.parse(text); } catch { /* non-JSON */ }
  return { status: res.status, json, text };
}

async function until<T>(what: string, fn: () => Promise<T | undefined>): Promise<T> {
  while (Date.now() < deadline) {
    try {
      const v = await fn();
      if (v !== undefined) return v;
    } catch { /* not ready yet */ }
    await sleep(1500);
  }
  return fail(`timed out waiting for ${what}`);
}

// 1. server up
const health = await until("server health", async () => {
  const r = await call("GET", "/api/health");
  return r.status === 200 && r.json?.ok ? r.json : undefined;
});
log(`server ok (v${health.version})`);

// 2. work key
let wk: string;
if (a["expect-wk"]) {
  wk = await until("auto-created work key", async () => {
    const r = await call("GET", "/api/work-keys/latest");
    return r.status === 200 ? (r.json.work_key as string) : undefined;
  });
  log(`work key already present (auto-created): ${wk}`);
} else {
  const latest = await call("GET", "/api/work-keys/latest");
  if (latest.status === 200) {
    wk = latest.json.work_key;
  } else {
    const r = await call("POST", "/api/work-keys", { goal: "e2e smoke" });
    if (r.status >= 300) fail(`create work key → ${r.status} ${r.text}`);
    wk = r.json.work_key;
  }
  log(`work key: ${wk}`);
}
if (a["ensure-wk-only"]) process.exit(0);

const presence = async () => {
  const r = await call("GET", "/api/presence");
  if (r.status !== 200) throw new Error(`presence ${r.status}`);
  return (r.json.agents as any[]).map((x) => x.name as string);
};

// 3a. removal check
if (a.absent) {
  await until(`${a.agent} to leave presence`, async () => ((await presence()).includes(a.agent!) ? undefined : true));
  log(`${a.agent} is gone from presence ✓`);
  process.exit(0);
}

// 3. agent online
await until(`${a.agent} in presence`, async () => ((await presence()).includes(a.agent!) ? true : undefined));
log(`${a.agent} online`);

// 4. dispatch → result
const taskId = `e2e-${Date.now()}`;
const d = await call("POST", "/api/task", { task_id: taskId, to: a.agent, work_key: wk, instructions: a.cmd });
if (d.status !== 201) fail(`dispatch → ${d.status} ${d.text}`);
log(`dispatched ${taskId}: ${a.cmd}`);

const result = await until(`result of ${taskId}`, async () => {
  const r = await call("GET", `/api/task/${taskId}`);
  return r.status === 200 ? r.json : undefined;
});
const output = String(result.output ?? "");
log(`result: status=${result.status} exit=${result.exit_code} from=${result.from}`);
log(`output: ${output.trim().slice(0, 500)}`);

if (result.status !== "done") fail(`status ${result.status}`);
if (result.from !== a.agent) fail(`result came from ${result.from}, expected ${a.agent}`);
if (a.expect && !output.includes(a.expect)) fail(`output does not contain "${a.expect}"`);
log("PASS ✓");
