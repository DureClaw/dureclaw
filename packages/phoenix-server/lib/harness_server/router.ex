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
.c{max-width:1200px;margin:0 auto;padding:0 24px}
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
.dg{display:grid;grid-template-columns:280px 1fr;gap:16px;padding:20px 0 40px;min-height:calc(100vh - 52px)}
.sb{display:flex;flex-direction:column;gap:16px;grid-row:1/3}
.panel{background:var(--bg);border:1px solid var(--border);border-radius:8px;overflow:hidden}
.ph{display:flex;align-items:center;justify-content:space-between;padding:12px 16px;border-bottom:1px solid var(--border);background:var(--bg2)}
.pt{font-family:'Syne',sans-serif;font-size:11px;font-weight:700;letter-spacing:2px;color:var(--text3);text-transform:uppercase}
.pb{background:var(--bg3);border:1px solid var(--border2);color:var(--text2);font-size:10px;padding:1px 7px;border-radius:10px}
.pbd{padding:12px}
.ac{display:flex;align-items:center;gap:10px;padding:10px 12px;border:1px solid var(--border);border-radius:6px;background:var(--bg2);margin-bottom:6px;transition:border-color .2s}
.ac:last-child{margin-bottom:0}
.ac.on{border-left:3px solid var(--green)}
.ad{width:8px;height:8px;border-radius:50%;flex-shrink:0}
.ad.g{background:var(--green);box-shadow:0 0 5px var(--green);animation:pulse 2s infinite}
.ad.c{background:var(--cyan);box-shadow:0 0 5px var(--cyan);animation:pulse 2s infinite}
.ad.o{background:var(--orange);box-shadow:0 0 5px var(--orange);animation:pulse 2s infinite}
.ad.p{background:var(--purple);box-shadow:0 0 5px var(--purple);animation:pulse 2s infinite}
.ad.gr{background:var(--border2)}
.ai{flex:1;min-width:0}
.an{font-size:12px;color:var(--text);font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.am{font-size:10px;color:var(--text3);margin-top:1px}
.rc{font-size:9px;font-weight:700;letter-spacing:.5px;padding:2px 6px;border-radius:2px;white-space:nowrap}
.rc.orchestrator{background:rgba(2,132,199,.1);color:var(--cyan)}
.rc.builder{background:rgba(5,150,105,.1);color:var(--green)}
.rc.verifier{background:rgba(124,58,237,.1);color:var(--purple)}
.rc.reviewer{background:rgba(234,88,12,.1);color:var(--orange)}
.rc.integrator{background:rgba(217,119,6,.1);color:var(--amber)}
.wki{padding:10px 12px;border:1px solid var(--border);border-radius:6px;background:var(--bg2);margin-bottom:6px;cursor:pointer;transition:border-color .15s,background .15s}
.wki:last-child{margin-bottom:0}
.wki:hover{border-color:var(--border2);background:var(--bg3)}
.wki.sel{border-color:var(--cyan);background:rgba(2,132,199,.03)}
.wkk{font-size:12px;color:var(--cyan)}
.wkm{font-size:10px;color:var(--text3);margin-top:3px}
.ma{display:flex;flex-direction:column;gap:16px}
.sr{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}
.sc{background:var(--bg2);border:1px solid var(--border);border-radius:8px;padding:16px}
.sn{font-family:'Syne',sans-serif;font-size:28px;font-weight:800;color:var(--text);line-height:1}
.sn.g{color:var(--green)}.sn.c{color:var(--cyan)}.sn.o{color:var(--orange)}
.sl{font-size:10px;color:var(--text3);margin-top:4px;letter-spacing:1px;text-transform:uppercase}
.lb{padding:0;max-height:340px;overflow-y:auto}
.le{display:grid;grid-template-columns:64px 130px 1fr;gap:12px;align-items:baseline;padding:8px 16px;border-bottom:1px solid var(--border);font-size:11px}
.le:last-child{border-bottom:none}
.le:hover{background:var(--bg2)}
.lt{color:var(--text3);font-size:10px}
.lv{font-weight:500}
.lv.task-assign{color:var(--orange)}.lv.task-result{color:var(--green)}.lv.task-progress{color:var(--cyan)}.lv.task-blocked{color:var(--red)}.lv.agent-hello{color:var(--green)}.lv.agent-bye{color:var(--text3)}.lv.state-update{color:var(--purple)}.lv.system{color:var(--text3)}
.lm{color:var(--text2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.stb{padding:16px}
.skv{display:grid;grid-template-columns:140px 1fr;gap:8px 16px}
.sk{font-size:11px;color:var(--text3)}
.sv{font-size:11px;color:var(--text);word-break:break-all}
.sv.g{color:var(--green)}.sv.c{color:var(--cyan)}
.empty{padding:32px 16px;text-align:center;color:var(--text3);font-size:12px}
.ei{font-size:28px;margin-bottom:8px;opacity:.4}
.rb{position:fixed;bottom:0;left:0;right:0;height:2px;background:var(--border);z-index:200}
.rp{height:100%;background:var(--cyan)}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
@keyframes fi{from{opacity:0;transform:translateY(4px)}to{opacity:1;transform:translateY(0)}}
.fi{animation:fi .2s ease both}
@media(max-width:900px){.dg{grid-template-columns:1fr}.sb{grid-row:auto}.sr{grid-template-columns:repeat(2,1fr)}}
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
  <div class="sb">
    <div class="panel">
      <div class="ph"><span class="pt">온라인 에이전트</span><span class="pb" id="ac">0</span></div>
      <div class="pbd" id="al"><div class="empty"><div class="ei">🤖</div>연결 중...</div></div>
    </div>
    <div class="panel">
      <div class="ph"><span class="pt">Work Keys</span><span class="pb" id="wc">0</span></div>
      <div class="pbd" id="wl"><div class="empty"><div class="ei">🔑</div>없음</div></div>
    </div>
  </div>
  <div class="ma">
    <div class="sr">
      <div class="sc"><div class="sn g" id="s1">0</div><div class="sl">온라인 에이전트</div></div>
      <div class="sc"><div class="sn c" id="s2">0</div><div class="sl">Work Keys</div></div>
      <div class="sc"><div class="sn o" id="s3">0</div><div class="sl">완료 태스크</div></div>
      <div class="sc"><div class="sn" id="s4">—</div><div class="sl">업데이트</div></div>
    </div>
    <div class="panel" id="sp" style="display:none">
      <div class="ph"><span class="pt">Work Key 상태</span><span class="pb" id="swk">—</span></div>
      <div class="stb" id="sb2"></div>
    </div>
    <div class="panel" style="flex:1">
      <div class="ph"><span class="pt">이벤트 로그</span><span class="pb" id="lc">0</span></div>
      <div class="lb" id="lb"><div class="empty" id="le"><div class="ei">📋</div>대기 중...</div></div>
    </div>
  </div>
</div></div>
<div class="rb"><div class="rp" id="rp" style="width:0%"></div></div>

<script>
const POLL=3000;
let selWk=null,log=[],tasks=0,connected=false,ref=1,ws=null;
const rc={orchestrator:'c',builder:'g',verifier:'p',reviewer:'o',integrator:'o'};
const e=s=>String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
const qs=s=>document.querySelector(s);
const id=s=>document.getElementById(s);

function setConn(state,label){
  id('sd').className='sd '+(state==='on'?'on':state==='off'?'off':'');
  id('cl').textContent=label;
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
    renderAgents(p.agents||[]);
    renderWks(w.work_keys||[]);
    id('s4').textContent=new Date().toLocaleTimeString('ko',{hour:'2-digit',minute:'2-digit',second:'2-digit'});
    if(selWk)loadState(selWk);
  }catch(err){
    if(connected){connected=false;addLog('system','연결 끊김');}
    setConn('off','연결 실패');
    renderAgents([]);
  }
}

function renderAgents(agents){
  agents=agents.filter(a=>(a.role||'').toLowerCase()!=='observer');
  id('ac').textContent=agents.length;id('s1').textContent=agents.length;
  const el=id('al');
  if(!agents.length){el.innerHTML='<div class="empty"><div class="ei">🤖</div>온라인 없음</div>';return;}
  el.innerHTML=agents.map(a=>{
    const role=(a.role||'builder').toLowerCase();
    const dc=rc[role]||'gr';
    return`<div class="ac on fi"><div class="ad ${dc}"></div><div class="ai"><div class="an">${e(a.name||'?')}</div><div class="am">${e(a.machine||a.hostname||'')}</div></div><span class="rc ${role}">${role}</span></div>`;
  }).join('');
}

function renderWks(wks){
  id('wc').textContent=wks.length;id('s2').textContent=wks.length;
  const el=id('wl');
  if(!wks.length){el.innerHTML='<div class="empty"><div class="ei">🔑</div>없음</div>';return;}
  if(!selWk&&wks.length)selWk=wks[0];
  el.innerHTML=wks.map(wk=>`<div class="wki fi ${wk===selWk?'sel':''}" onclick="pickWk('${e(wk)}')">`+
    `<div class="wkk">${e(wk)}</div><div class="wkm">클릭해서 상태 확인</div></div>`).join('');
  if(selWk&&wks.includes(selWk))loadState(selWk);
  else if(wks.length)loadState(wks[0]);
}

function pickWk(wk){selWk=wk;document.querySelectorAll('.wki').forEach(el=>el.classList.toggle('sel',el.querySelector('.wkk').textContent===wk));loadState(wk);}

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

function addLog(ev,msg){
  const t=new Date().toLocaleTimeString('ko',{hour:'2-digit',minute:'2-digit',second:'2-digit'});
  log.unshift({t,ev,msg});if(log.length>200)log.pop();
  const lb=id('lb');const le=id('le');if(le)le.remove();
  const cls=ev.replace(/\./g,'-').replace(/_/g,'-');
  const d=document.createElement('div');
  d.className='le fi';
  d.innerHTML=`<span class="lt">${t}</span><span class="lv ${cls}">${e(ev)}</span><span class="lm">${e(msg)}</span>`;
  lb.prepend(d);
  id('lc').textContent=log.length;
  if(lb.children.length>200)lb.lastElementChild?.remove();
}

// WebSocket — Phoenix Channel (same origin)
function connectWs(){
  const proto=location.protocol==='https:'?'wss':'ws';
  ws=new WebSocket(`${proto}://${location.host}/socket/websocket?vsn=2.0.0`);
  ws.onopen=()=>{
    // heartbeat only — no channel join to avoid polluting work keys / presence
    setInterval(()=>ws.send(JSON.stringify([null,String(ref++),'phoenix','heartbeat',{}])),30000);
    // join latest real work key if available
    fetch('/api/work-keys/latest').then(r=>r.json()).then(d=>{
      if(d.work_key){
        ws.send(JSON.stringify(['1',String(ref++),'work:'+d.work_key,'phx_join',{role:'observer',agent:'dashboard'}]));
      }
    }).catch(()=>{});
  };
  ws.onmessage=evt=>{
    try{
      const [,,topic,ev,payload]=JSON.parse(evt.data);
      if(ev==='phx_reply'||ev==='heartbeat'||ev==='phx_close')return;
      const msg=payload?.message||payload?.task_id||payload?.agent||JSON.stringify(payload).slice(0,80);
      addLog(ev,`[${topic}] ${msg}`);
      if(ev==='task.result'){tasks++;id('s3').textContent=tasks;}
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
