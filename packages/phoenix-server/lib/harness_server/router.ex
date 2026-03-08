defmodule HarnessServer.Router do
  @moduledoc "REST API router for the harness state server."

  use Plug.Router

  alias HarnessServer.{Presence, StateStore}

  plug Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason

  plug :match
  plug :dispatch

  # ── GET /api/health ─────────────────────────────────────────────────────────

  get "/api/health" do
    work_keys = StateStore.list_work_keys()

    send_json(conn, 200, %{
      ok: true,
      work_keys: length(work_keys)
    })
  end

  # ── GET /api/presence ───────────────────────────────────────────────────────

  get "/api/presence" do
    # Aggregate presence from all work: topics via PubSub
    # Presence.list requires a topic; for a global view, we scan ETS
    work_keys = StateStore.list_work_keys()

    agents =
      work_keys
      |> Enum.flat_map(fn wk ->
        topic = "work:#{wk}"

        Presence.list(topic)
        |> Enum.map(fn {agent_name, %{metas: [meta | _]}} ->
          Map.merge(meta, %{name: agent_name})
        end)
      end)
      |> Enum.uniq_by(& &1.name)

    send_json(conn, 200, %{agents: agents})
  end

  # ── GET /api/work-keys ──────────────────────────────────────────────────────

  get "/api/work-keys" do
    keys = StateStore.list_work_keys()
    send_json(conn, 200, %{work_keys: keys, count: length(keys)})
  end

  # ── GET /api/work-keys/latest ───────────────────────────────────────────────

  get "/api/work-keys/latest" do
    case StateStore.latest_work_key() do
      nil -> send_json(conn, 404, %{error: "no work keys yet"})
      wk  -> send_json(conn, 200, %{work_key: wk})
    end
  end

  # ── POST /api/work-keys ─────────────────────────────────────────────────────

  post "/api/work-keys" do
    work_key = StateStore.generate_work_key()
    send_json(conn, 201, %{work_key: work_key})
  end

  # ── POST /api/task ───────────────────────────────────────────────────────────
  # Dispatch a task to connected agents via Phoenix Channel broadcast.
  # Body: {"instructions": "...", "role": "builder", "to": "agent@machine"}
  # Returns: {"task_id": "http-...", "work_key": "LN-..."}

  post "/api/task" do
    params = conn.body_params
    wk = StateStore.latest_work_key() || StateStore.generate_work_key()
    task_id = "http-#{System.system_time(:millisecond)}"

    payload = %{
      "task_id"      => task_id,
      "from"         => "http@controller",
      "role"         => Map.get(params, "role", "builder"),
      "to"           => Map.get(params, "to"),
      "instructions" => Map.get(params, "instructions", ""),
    }

    HarnessServer.Endpoint.broadcast("work:#{wk}", "task.assign", payload)

    # Also enqueue to mailbox so OpenCode plugins can poll via REST
    if to = Map.get(params, "to") do
      StateStore.enqueue_mailbox(to, payload)
    end

    send_json(conn, 201, %{task_id: task_id, work_key: wk})
  end

  # ── POST /api/task/:task_id/result ──────────────────────────────────────────
  # OpenCode harness plugin calls this to submit task result.
  # Body: {"status":"done","summary":"...","artifacts":["file.ts"],"from":"agent1@machine"}

  post "/api/task/:task_id/result" do
    result =
      conn.body_params
      |> Map.put("task_id", task_id)
      |> Map.put("event", "task.result")
      |> Map.put("ts", DateTime.utc_now() |> DateTime.to_iso8601())

    StateStore.store_task_result(task_id, result)

    wk = StateStore.latest_work_key()
    if wk, do: HarnessServer.Endpoint.broadcast("work:#{wk}", "task.result", result)

    send_json(conn, 200, %{ok: true, task_id: task_id})
  end

  # ── GET /api/task/:task_id ───────────────────────────────────────────────────
  # Poll for task result. Returns 202 while pending, 200 when done.

  get "/api/task/:task_id" do
    case StateStore.get_task_result(task_id) do
      {:ok, result} -> send_json(conn, 200, result)
      :not_found    -> send_json(conn, 202, %{status: "pending", task_id: task_id})
    end
  end

  # ── GET /api/state/:work_key ────────────────────────────────────────────────

  get "/api/state/:work_key" do
    state = StateStore.get(work_key)
    send_json(conn, 200, state)
  end

  # ── PATCH /api/state/:work_key ──────────────────────────────────────────────

  patch "/api/state/:work_key" do
    updates = conn.body_params
    state = StateStore.update(work_key, updates)
    send_json(conn, 200, state)
  end

  # ── GET /api/mailbox/:agent ─────────────────────────────────────────────────

  get "/api/mailbox/:agent" do
    msgs = StateStore.pop_mailbox(agent)
    send_json(conn, 200, %{messages: msgs, count: length(msgs)})
  end

  # ── POST /api/mailbox/:agent ────────────────────────────────────────────────

  post "/api/mailbox/:agent" do
    msg = conn.body_params
    StateStore.enqueue_mailbox(agent, msg)
    send_json(conn, 201, %{ok: true, queued: true})
  end

  # ── GET / ─ Observer Dashboard ──────────────────────────────────────────────

  get "/" do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, dashboard_html())
  end

  get "/dashboard" do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, dashboard_html())
  end

  # ── Fallback ────────────────────────────────────────────────────────────────

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  # rubric: embedded dashboard HTML served at GET /
  # Uses relative /api/* URLs so it always hits the same server.
  defp dashboard_html do
    ~S"""
<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1.0"/>
<title>OAH Dashboard — 에이전트 현황</title>
<link rel="preconnect" href="https://fonts.googleapis.com"/>
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;700&family=Syne:wght@700;800&display=swap" rel="stylesheet"/>
<style>
:root{--bg:#fff;--bg2:#f8fafc;--bg3:#f1f5f9;--border:#e2e8f0;--border2:#cbd5e1;--text:#1e293b;--text2:#475569;--text3:#94a3b8;--cyan:#0284c7;--green:#059669;--orange:#ea580c;--purple:#7c3aed;--red:#dc2626;--amber:#d97706}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:'JetBrains Mono',monospace;font-size:13px;line-height:1.5}
.c{max-width:1280px;margin:0 auto;padding:0 24px}
nav{position:sticky;top:0;z-index:100;background:rgba(255,255,255,.95);border-bottom:1px solid var(--border);backdrop-filter:blur(12px)}
.ni{display:flex;align-items:center;justify-content:space-between;height:52px}
.logo{font-family:'Syne',sans-serif;font-weight:800;font-size:15px;color:var(--text);text-decoration:none}
.logo span{color:var(--cyan)}
.nr{display:flex;align-items:center;gap:16px}
.ns{display:flex;align-items:center;gap:7px;font-size:11px;color:var(--text3)}
.sd{width:7px;height:7px;border-radius:50%;background:var(--border2);flex-shrink:0}
.sd.on{background:var(--green);box-shadow:0 0 6px var(--green);animation:pulse 2s infinite}
.sd.off{background:var(--red)}
#cl{color:var(--text2)}

/* layout */
.dg{display:grid;grid-template-columns:260px 1fr;gap:16px;padding:20px 0 40px;align-items:start}
.sb{display:flex;flex-direction:column;gap:12px;position:sticky;top:68px}
.ma{display:flex;flex-direction:column;gap:12px}

/* panel */
.panel{background:var(--bg);border:1px solid var(--border);border-radius:8px;overflow:hidden}
.ph{display:flex;align-items:center;justify-content:space-between;padding:11px 16px;border-bottom:1px solid var(--border);background:var(--bg2)}
.ph-left{display:flex;align-items:center;gap:10px}
.pt{font-family:'Syne',sans-serif;font-size:10px;font-weight:700;letter-spacing:2px;color:var(--text3);text-transform:uppercase}
.pb{background:var(--bg3);border:1px solid var(--border2);color:var(--text2);font-size:10px;padding:1px 7px;border-radius:10px}
.ph-close{background:none;border:none;color:var(--text3);cursor:pointer;font-size:14px;padding:0 2px;line-height:1}
.ph-close:hover{color:var(--red)}
.pbd{padding:12px}

/* stats row */
.sr{display:grid;grid-template-columns:repeat(4,1fr);gap:10px}
.sc{background:var(--bg2);border:1px solid var(--border);border-radius:8px;padding:14px 16px}
.sn{font-family:'Syne',sans-serif;font-size:26px;font-weight:800;color:var(--text);line-height:1}
.sn.g{color:var(--green)}.sn.c{color:var(--cyan)}.sn.o{color:var(--orange)}
.sl{font-size:10px;color:var(--text3);margin-top:4px;letter-spacing:1px;text-transform:uppercase}

/* agent card */
.ac{display:flex;align-items:center;gap:10px;padding:10px 12px;border:1px solid var(--border);border-radius:6px;background:var(--bg2);margin-bottom:6px;cursor:pointer;transition:border-color .15s,background .15s}
.ac:last-child{margin-bottom:0}
.ac.on{border-left:3px solid var(--green)}
.ac:hover{background:var(--bg3);border-color:var(--border2)}
.ac.sel{background:rgba(2,132,199,.04);border-color:var(--cyan);border-left-width:3px}
.ac.busy{border-left-color:var(--orange)}
.ac.sel.busy{border-left-color:var(--orange)}
.ad{width:8px;height:8px;border-radius:50%;flex-shrink:0}
.ad.g{background:var(--green);box-shadow:0 0 5px var(--green);animation:pulse 2s infinite}
.ad.c{background:var(--cyan);box-shadow:0 0 5px var(--cyan);animation:pulse 2s infinite}
.ad.o{background:var(--orange);box-shadow:0 0 5px var(--orange);animation:pulse 2s infinite}
.ad.p{background:var(--purple);box-shadow:0 0 5px var(--purple);animation:pulse 2s infinite}
.ad.gr{background:var(--border2)}
.ai{flex:1;min-width:0}
.an{font-size:12px;color:var(--text);font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.am{font-size:10px;color:var(--text3);margin-top:1px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.a-task{font-size:9px;color:var(--orange);margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.rc{font-size:9px;font-weight:700;letter-spacing:.5px;padding:2px 6px;border-radius:2px;white-space:nowrap;flex-shrink:0}
.rc.orchestrator{background:rgba(2,132,199,.1);color:var(--cyan)}
.rc.builder{background:rgba(5,150,105,.1);color:var(--green)}
.rc.verifier{background:rgba(124,58,237,.1);color:var(--purple)}
.rc.reviewer{background:rgba(234,88,12,.1);color:var(--orange)}
.rc.integrator{background:rgba(217,119,6,.1);color:var(--amber)}

/* agent detail */
.adet{padding:0}
.adet-hero{display:flex;align-items:center;gap:16px;padding:16px 20px;border-bottom:1px solid var(--border);background:var(--bg2)}
.adet-dot{width:12px;height:12px;border-radius:50%;flex-shrink:0}
.adet-name{font-family:'Syne',sans-serif;font-size:16px;font-weight:800;color:var(--text)}
.adet-role{margin-top:3px}
.adet-body{padding:0}
.adet-row{display:grid;grid-template-columns:120px 1fr;gap:6px 16px;padding:10px 20px;border-bottom:1px solid var(--border);font-size:11px;align-items:baseline}
.adet-row:last-child{border-bottom:none}
.adet-k{color:var(--text3);letter-spacing:.5px}
.adet-v{color:var(--text);word-break:break-word}
.adet-v.g{color:var(--green)}.adet-v.o{color:var(--orange)}.adet-v.c{color:var(--cyan)}
.task-box{background:var(--bg3);border:1px solid var(--border2);border-radius:4px;padding:8px 10px;font-size:11px;color:var(--text2);line-height:1.5;margin-top:4px;white-space:pre-wrap;word-break:break-word;max-height:120px;overflow-y:auto}
.task-box.active{border-color:rgba(234,88,12,.3);background:rgba(234,88,12,.03)}
.task-box.done{border-color:rgba(5,150,105,.3);background:rgba(5,150,105,.03)}

/* wk items */
.wki{padding:10px 12px;border:1px solid var(--border);border-radius:6px;background:var(--bg2);margin-bottom:6px;cursor:pointer;transition:border-color .15s,background .15s}
.wki:last-child{margin-bottom:0}
.wki:hover{border-color:var(--border2);background:var(--bg3)}
.wki.sel{border-color:var(--cyan);background:rgba(2,132,199,.03)}
.wkk{font-size:12px;color:var(--cyan)}
.wkm{font-size:10px;color:var(--text3);margin-top:3px}

/* wk state panel */
.stb{padding:16px}
.skv{display:grid;grid-template-columns:130px 1fr;gap:6px 16px}
.sk{font-size:11px;color:var(--text3)}
.sv{font-size:11px;color:var(--text);word-break:break-all}
.sv.g{color:var(--green)}.sv.c{color:var(--cyan)}

/* event log */
.lb{padding:0;max-height:300px;overflow-y:auto}
.log-filter{padding:8px 16px;border-bottom:1px solid var(--border);font-size:10px;color:var(--text3);background:var(--bg2)}
.log-filter span{color:var(--cyan)}
.le{display:grid;grid-template-columns:60px 120px 1fr;gap:10px;align-items:baseline;padding:7px 16px;border-bottom:1px solid var(--border);font-size:11px}
.le:last-child{border-bottom:none}
.le:hover{background:var(--bg2)}
.lt{color:var(--text3);font-size:10px}
.lv{font-weight:500}
.lv.task-assign{color:var(--orange)}.lv.task-result{color:var(--green)}.lv.task-progress{color:var(--cyan)}.lv.task-blocked{color:var(--red)}.lv.agent-hello{color:var(--green)}.lv.agent-bye{color:var(--text3)}.lv.state-update{color:var(--purple)}.lv.system{color:var(--text3)}
.lm{color:var(--text2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}

.empty{padding:28px 16px;text-align:center;color:var(--text3);font-size:12px}
.ei{font-size:24px;margin-bottom:6px;opacity:.4}
.rb{position:fixed;bottom:0;left:0;right:0;height:2px;background:var(--border);z-index:200}
.rp{height:100%;background:var(--cyan)}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
@keyframes fi{from{opacity:0;transform:translateY(4px)}to{opacity:1;transform:translateY(0)}}
.fi{animation:fi .2s ease both}
@media(max-width:960px){.dg{grid-template-columns:1fr}.sb{position:static}.sr{grid-template-columns:repeat(2,1fr)}}
</style>
</head>
<body>
<nav><div class="c"><div class="ni">
  <a href="/" class="logo">oah<span>://</span><span style="font-size:11px;font-weight:400;color:var(--text3);"> dashboard</span></a>
  <div class="nr">
    <div class="ns"><div class="sd" id="sd"></div><span id="cl">연결 중...</span></div>
  </div>
</div></div></nav>

<div class="c"><div class="dg">

  <!-- SIDEBAR -->
  <div class="sb">
    <div class="panel">
      <div class="ph"><span class="pt">에이전트</span><span class="pb" id="ac">0</span></div>
      <div class="pbd" id="al"><div class="empty"><div class="ei">🤖</div>연결 중...</div></div>
    </div>
    <div class="panel">
      <div class="ph"><span class="pt">Work Keys</span><span class="pb" id="wc">0</span></div>
      <div class="pbd" id="wl"><div class="empty"><div class="ei">🔑</div>없음</div></div>
    </div>
  </div>

  <!-- MAIN -->
  <div class="ma">
    <!-- STATS -->
    <div class="sr">
      <div class="sc"><div class="sn g" id="s1">0</div><div class="sl">온라인 에이전트</div></div>
      <div class="sc"><div class="sn c" id="s2">0</div><div class="sl">Work Keys</div></div>
      <div class="sc"><div class="sn o" id="s3">0</div><div class="sl">완료 태스크</div></div>
      <div class="sc"><div class="sn" id="s4">—</div><div class="sl">마지막 업데이트</div></div>
    </div>

    <!-- AGENT DETAIL (click to show) -->
    <div class="panel" id="adp" style="display:none">
      <div class="ph">
        <div class="ph-left"><span class="pt">에이전트 상세</span><span class="pb" id="adp-name">—</span></div>
        <button class="ph-close" onclick="closeAgentDetail()" title="닫기">✕</button>
      </div>
      <div class="adet" id="adp-body"></div>
    </div>

    <!-- WK STATE -->
    <div class="panel" id="sp" style="display:none">
      <div class="ph"><span class="pt">Work Key 상태</span><span class="pb" id="swk">—</span></div>
      <div class="stb" id="sb2"></div>
    </div>

    <!-- EVENT LOG -->
    <div class="panel">
      <div class="ph">
        <div class="ph-left"><span class="pt">이벤트 로그</span><span class="pb" id="lc">0</span></div>
        <button class="ph-close" id="log-clear-filter" onclick="clearLogFilter()" title="필터 해제" style="display:none;font-size:10px;letter-spacing:.5px;color:var(--orange)">필터 해제</button>
      </div>
      <div id="log-filter-bar" style="display:none" class="log-filter">필터: <span id="log-filter-label"></span></div>
      <div class="lb" id="lb"><div class="empty" id="le"><div class="ei">📋</div>대기 중...</div></div>
    </div>
  </div>

</div></div>
<div class="rb"><div class="rp" id="rp" style="width:0%"></div></div>

<script>
const POLL=3000;
let selWk=null, selAgent=null, logFilter=null;
let log=[], tasks=0, connected=false, ref=1, ws=null;
// per-agent state tracking
let agentState={}; // name -> {task_id, instructions, status, started, completed}
let allAgents=[];

const rc={orchestrator:'c',builder:'g',verifier:'p',reviewer:'o',integrator:'o'};
const e=s=>String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
const id=s=>document.getElementById(s);

function setConn(state,label){
  id('sd').className='sd '+(state==='on'?'on':state==='off'?'off':'');
  id('cl').textContent=label;
}

function elapsed(iso){
  if(!iso)return'—';
  const s=Math.floor((Date.now()-new Date(iso))/1000);
  if(s<60)return s+'초';
  if(s<3600)return Math.floor(s/60)+'분 '+s%60+'초';
  return Math.floor(s/3600)+'시간 '+Math.floor((s%3600)/60)+'분';
}

async function poll(){
  try{
    const [pr,wr]=await Promise.all([
      fetch('/api/presence',{signal:AbortSignal.timeout(4000)}),
      fetch('/api/work-keys',{signal:AbortSignal.timeout(4000)})
    ]);
    if(!pr.ok||!wr.ok)throw new Error();
    const p=await pr.json(), w=await wr.json();
    if(!connected){connected=true;setConn('on','연결됨');addLog('system','서버 연결 성공');}
    allAgents=(p.agents||[]).filter(a=>(a.role||'').toLowerCase()!=='observer');
    renderAgents(allAgents);
    renderWks(w.work_keys||[]);
    id('s4').textContent=new Date().toLocaleTimeString('ko',{hour:'2-digit',minute:'2-digit',second:'2-digit'});
    if(selWk)loadState(selWk);
    if(selAgent)refreshAgentDetail(selAgent);
  }catch(err){
    if(connected){connected=false;addLog('system','연결 끊김');}
    setConn('off','연결 실패');
    allAgents=[];
    renderAgents([]);
  }
}

function agentDotCls(role){return rc[role]||'gr';}

function renderAgents(agents){
  id('ac').textContent=agents.length;id('s1').textContent=agents.length;
  const el=id('al');
  if(!agents.length){el.innerHTML='<div class="empty"><div class="ei">🤖</div>온라인 없음</div>';return;}
  el.innerHTML=agents.map(a=>{
    const name=a.name||'?';
    const role=(a.role||'builder').toLowerCase();
    const dc=agentDotCls(role);
    const st=agentState[name]||{};
    const isBusy=st.status==='working';
    const isDone=st.status==='done';
    const isSelected=selAgent===name;
    const taskLine=isBusy?`<div class="a-task">⚡ ${e((st.instructions||'').slice(0,40)+'…')}</div>`
                  :isDone?`<div class="a-task" style="color:var(--green)">✓ 완료: ${e((st.instructions||'').slice(0,35)+'…')}</div>`:'';
    return`<div class="ac on fi${isSelected?' sel':''}${isBusy?' busy':''}" onclick="selectAgent('${e(name)}')" data-name="${e(name)}">
      <div class="ad ${dc}"></div>
      <div class="ai">
        <div class="an">${e(name)}</div>
        <div class="am">${e(a.machine||a.hostname||'')}</div>
        ${taskLine}
      </div>
      <span class="rc ${role}">${role}</span>
    </div>`;
  }).join('');
}

function selectAgent(name){
  selAgent=name;
  // update selection highlight
  document.querySelectorAll('.ac').forEach(el=>el.classList.toggle('sel',el.dataset.name===name));
  refreshAgentDetail(name);
}

function closeAgentDetail(){
  selAgent=null;
  document.querySelectorAll('.ac').forEach(el=>el.classList.remove('sel'));
  id('adp').style.display='none';
  clearLogFilter();
}

function refreshAgentDetail(name){
  const agent=allAgents.find(a=>(a.name||'?')===name);
  if(!agent){id('adp').style.display='none';return;}
  const st=agentState[name]||{};
  const role=(agent.role||'builder').toLowerCase();
  const dc=agentDotCls(role);
  const colorMap={g:'var(--green)',c:'var(--cyan)',o:'var(--orange)',p:'var(--purple)',gr:'var(--border2)'};
  const dotColor=colorMap[dc]||'var(--border2)';

  id('adp').style.display='';
  id('adp-name').textContent=name;

  // status badge
  const statusHtml=st.status==='working'
    ?`<span style="color:var(--orange);font-size:10px;font-weight:700">⚡ 작업 중</span>`
    :st.status==='done'
    ?`<span style="color:var(--green);font-size:10px;font-weight:700">✓ 완료</span>`
    :`<span style="color:var(--text3);font-size:10px">대기 중</span>`;

  const onlineSince=agent.online_since||agent.joined_at||null;
  const taskInstr=st.instructions||'—';
  const taskBoxCls=st.status==='working'?'task-box active':st.status==='done'?'task-box done':'task-box';
  const agentLogs=log.filter(l=>l.agent===name||l.msg.includes(name)).slice(0,8);

  id('adp-body').innerHTML=`
    <div class="adet-hero">
      <div class="adet-dot" style="background:${dotColor};box-shadow:0 0 8px ${dotColor}"></div>
      <div>
        <div class="adet-name">${e(name)}</div>
        <div class="adet-role"><span class="rc ${role}">${role}</span> &nbsp; ${statusHtml}</div>
      </div>
    </div>
    <div class="adet-body">
      <div class="adet-row"><div class="adet-k">머신</div><div class="adet-v">${e(agent.machine||agent.hostname||'—')}</div></div>
      <div class="adet-row"><div class="adet-k">Work Key</div><div class="adet-v c">${e(agent.work_key||selWk||'—')}</div></div>
      <div class="adet-row"><div class="adet-k">온라인 시간</div><div class="adet-v">${onlineSince?elapsed(onlineSince):'—'}</div></div>
      ${st.task_id?`<div class="adet-row"><div class="adet-k">Task ID</div><div class="adet-v">${e(st.task_id)}</div></div>`:''}
      ${st.started?`<div class="adet-row"><div class="adet-k">시작</div><div class="adet-v">${e(new Date(st.started).toLocaleTimeString('ko'))}</div></div>`:''}
      ${st.completed?`<div class="adet-row"><div class="adet-k">완료</div><div class="adet-v g">${e(new Date(st.completed).toLocaleTimeString('ko'))}</div></div>`:''}
      ${st.exit_code!=null?`<div class="adet-row"><div class="adet-k">종료 코드</div><div class="adet-v ${st.exit_code===0?'g':''}">exit ${st.exit_code}</div></div>`:''}
      <div class="adet-row">
        <div class="adet-k">현재 태스크</div>
        <div class="adet-v"><div class="${taskBoxCls}">${e(taskInstr)}</div></div>
      </div>
      ${agentLogs.length?`<div class="adet-row">
        <div class="adet-k">최근 이벤트</div>
        <div class="adet-v" style="font-size:10px;color:var(--text3);line-height:1.8">${agentLogs.map(l=>`<span style="color:var(--text3)">${e(l.t)}</span> <span class="lv ${l.ev.replace(/\./g,'-')}" style="font-size:10px">${e(l.ev)}</span> ${e(l.msg.slice(0,50))}`).join('<br>')}</div>
      </div>`:''}
      <div class="adet-row">
        <div class="adet-k">로그 필터</div>
        <div class="adet-v"><button onclick="setLogFilter('${e(name)}')" style="background:var(--bg3);border:1px solid var(--border2);color:var(--cyan);font-family:inherit;font-size:10px;padding:3px 10px;border-radius:3px;cursor:pointer;letter-spacing:.5px">이 에이전트만 보기</button></div>
      </div>
    </div>`;
}

// log filter
function setLogFilter(name){
  logFilter=name;
  id('log-filter-bar').style.display='';
  id('log-filter-label').textContent=name;
  id('log-clear-filter').style.display='';
  renderFilteredLog();
}
function clearLogFilter(){
  logFilter=null;
  id('log-filter-bar').style.display='none';
  id('log-clear-filter').style.display='none';
  renderFilteredLog();
}
function renderFilteredLog(){
  const lb=id('lb');
  const filtered=logFilter?log.filter(l=>l.agent===logFilter||l.msg.includes(logFilter)):log;
  if(!filtered.length){lb.innerHTML='<div class="empty" id="le"><div class="ei">📋</div>이벤트 없음</div>';return;}
  lb.innerHTML=filtered.map(l=>{
    const cls=l.ev.replace(/\./g,'-').replace(/_/g,'-');
    return`<div class="le"><span class="lt">${e(l.t)}</span><span class="lv ${cls}">${e(l.ev)}</span><span class="lm">${e(l.msg)}</span></div>`;
  }).join('');
  id('lc').textContent=filtered.length+(logFilter?` / ${log.length}`:'');
}

function renderWks(wks){
  id('wc').textContent=wks.length;id('s2').textContent=wks.length;
  const el=id('wl');
  if(!wks.length){el.innerHTML='<div class="empty"><div class="ei">🔑</div>없음</div>';return;}
  if(!selWk&&wks.length)selWk=wks[0];
  el.innerHTML=wks.map(wk=>`<div class="wki fi${wk===selWk?' sel':''}" onclick="pickWk('${e(wk)}')">
    <div class="wkk">${e(wk)}</div><div class="wkm">클릭해서 상태 확인</div></div>`).join('');
  if(selWk&&wks.includes(selWk))loadState(selWk);
  else if(wks.length)loadState(wks[0]);
}

function pickWk(wk){
  selWk=wk;
  document.querySelectorAll('.wki').forEach(el=>el.classList.toggle('sel',el.querySelector('.wkk').textContent===wk));
  loadState(wk);
}

async function loadState(wk){
  try{
    const res=await fetch(`/api/state/${encodeURIComponent(wk)}`,{signal:AbortSignal.timeout(3000)});
    if(!res.ok)return;
    const data=await res.json();
    const state=data.state||data||{};
    id('sp').style.display='';id('swk').textContent=wk;
    const entries=Object.entries(state);
    id('sb2').innerHTML=entries.length?`<div class="skv">${entries.map(([k,v])=>{
      const vs=typeof v==='object'?JSON.stringify(v):String(v);
      const cls=v==='done'||v==='completed'?'g':v==='active'||v==='running'?'c':'';
      return`<div class="sk">${e(k)}</div><div class="sv ${cls}">${e(vs)}</div>`;
    }).join('')}</div>`:'<div class="empty">상태 없음</div>';
  }catch{}
}

function addLog(ev, msg, agentName){
  const t=new Date().toLocaleTimeString('ko',{hour:'2-digit',minute:'2-digit',second:'2-digit'});
  const entry={t, ev, msg, agent:agentName||null};
  log.unshift(entry);
  if(log.length>500)log.pop();

  const lb=id('lb');
  const le=id('le');if(le)le.remove();

  if(!logFilter||entry.agent===logFilter||msg.includes(logFilter)){
    const cls=ev.replace(/\./g,'-').replace(/_/g,'-');
    const d=document.createElement('div');
    d.className='le fi';
    d.innerHTML=`<span class="lt">${t}</span><span class="lv ${cls}">${e(ev)}</span><span class="lm">${e(msg)}</span>`;
    lb.prepend(d);
    if(lb.children.length>200)lb.lastElementChild?.remove();
  }

  id('lc').textContent=logFilter?(log.filter(l=>l.agent===logFilter||l.msg.includes(logFilter)).length+' / '+log.length):log.length;

  // update agent detail if open
  if(selAgent&&(agentName===selAgent||msg.includes(selAgent)))refreshAgentDetail(selAgent);
}

// WebSocket — Phoenix Channel (same origin)
function connectWs(){
  const proto=location.protocol==='https:'?'wss':'ws';
  ws=new WebSocket(`${proto}://${location.host}/socket/websocket?vsn=2.0.0`);
  ws.onopen=()=>{
    setInterval(()=>ws.send(JSON.stringify([null,String(ref++),'phoenix','heartbeat',{}])),30000);
    fetch('/api/work-keys/latest').then(r=>r.json()).then(d=>{
      if(d.work_key)ws.send(JSON.stringify(['1',String(ref++),'work:'+d.work_key,'phx_join',{role:'observer',agent:'dashboard'}]));
    }).catch(()=>{});
  };
  ws.onmessage=evt=>{
    try{
      const [,,topic,ev,payload]=JSON.parse(evt.data);
      if(ev==='phx_reply'||ev==='heartbeat'||ev==='phx_close')return;

      const from=payload?.from||payload?.agent||null;
      const taskId=payload?.task_id||'';
      let msg='';

      if(ev==='task.assign'){
        const to=payload?.to||'?';
        const instr=(payload?.instructions||'').slice(0,60);
        msg=`→ ${to}: ${instr}`;
        // track assignment
        if(to){
          agentState[to]=agentState[to]||{};
          Object.assign(agentState[to],{task_id:taskId,instructions:payload?.instructions||'',status:'working',started:new Date().toISOString(),completed:null,exit_code:null});
          renderAgents(allAgents);
        }
      } else if(ev==='task.result'){
        const agentFrom=payload?.from||'?';
        msg=`${agentFrom}: exit=${payload?.exit_code??'?'} ${taskId}`;
        tasks++;id('s3').textContent=tasks;
        if(agentFrom&&agentState[agentFrom]){
          agentState[agentFrom].status='done';
          agentState[agentFrom].exit_code=payload?.exit_code??0;
          agentState[agentFrom].completed=new Date().toISOString();
          renderAgents(allAgents);
        }
      } else if(ev==='task.progress'){
        msg=`${from||'?'}: ${payload?.message||taskId}`;
      } else if(ev==='task.blocked'){
        msg=`${from||'?'}: ${payload?.reason||taskId}`;
        if(from&&agentState[from]){agentState[from].status='blocked';renderAgents(allAgents);}
      } else if(ev==='agent.hello'){
        msg=`${payload?.agent||'?'} (${payload?.role||'?'}) @ ${payload?.machine||'?'}`;
      } else if(ev==='agent.bye'){
        msg=`${payload?.agent||'?'} 퇴장`;
      } else {
        msg=payload?.message||taskId||JSON.stringify(payload).slice(0,80);
      }

      addLog(ev, msg, from);
    }catch{}
  };
  ws.onclose=()=>setTimeout(connectWs,5000);
  ws.onerror=()=>ws.close();
}

// progress bar
let pct=0;
setInterval(()=>{pct=pct>=100?0:pct+100/(POLL/50);id('rp').style.width=pct+'%';},50);

poll();
setInterval(poll,POLL);
connectWs();
</script>
</body>
</html>
"""
  end
end
