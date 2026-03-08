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
    meta = %{
      "goal"        => Map.get(conn.body_params, "goal"),
      "project_dir" => Map.get(conn.body_params, "project_dir"),
      "context"     => Map.get(conn.body_params, "context", %{})
    }
    work_key = StateStore.generate_work_key(meta)
    send_json(conn, 201, %{work_key: work_key})
  end

  # ── POST /api/task ───────────────────────────────────────────────────────────
  # Dispatch a task to connected agents via Phoenix Channel broadcast.
  # Body: {"instructions": "...", "role": "builder", "to": "agent@machine"}
  # Returns: {"task_id": "http-...", "work_key": "LN-..."}

  post "/api/task" do
    params = conn.body_params
    # Prefer explicit work_key from body; fall back to latest; create if none
    wk =
      Map.get(params, "work_key") ||
      StateStore.latest_work_key() ||
      StateStore.generate_work_key()
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
<title>OAH Control — 에이전트 하네스</title>
<link rel="preconnect" href="https://fonts.googleapis.com"/>
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;700&family=Syne:wght@700;800&display=swap" rel="stylesheet"/>
<style>
:root{--bg:#fff;--bg2:#f8fafc;--bg3:#f1f5f9;--border:#e2e8f0;--border2:#cbd5e1;--text:#1e293b;--text2:#475569;--text3:#94a3b8;--cyan:#0284c7;--green:#059669;--orange:#ea580c;--purple:#7c3aed;--red:#dc2626;--amber:#d97706}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:'JetBrains Mono',monospace;font-size:13px;line-height:1.5}
.c{max-width:1400px;margin:0 auto;padding:0 24px}
nav{position:sticky;top:0;z-index:100;background:rgba(255,255,255,.95);border-bottom:1px solid var(--border);backdrop-filter:blur(12px)}
.ni{display:flex;align-items:center;justify-content:space-between;height:52px}
.logo{font-family:'Syne',sans-serif;font-weight:800;font-size:15px;color:var(--text);text-decoration:none}
.logo span{color:var(--cyan)}
.nr{display:flex;align-items:center;gap:12px}
.ns{display:flex;align-items:center;gap:7px;font-size:11px;color:var(--text3)}
.sd{width:7px;height:7px;border-radius:50%;background:var(--border2);flex-shrink:0}
.sd.on{background:var(--green);box-shadow:0 0 6px var(--green);animation:pulse 2s infinite}
.sd.off{background:var(--red)}
#cl{color:var(--text2)}
.nav-btn{font-family:'JetBrains Mono',monospace;font-size:10px;font-weight:700;letter-spacing:1px;padding:4px 12px;border-radius:4px;border:1px solid;cursor:pointer;transition:all .15s}
.nav-btn.cyan{background:rgba(2,132,199,.08);border-color:rgba(2,132,199,.3);color:var(--cyan)}
.nav-btn.cyan:hover{background:rgba(2,132,199,.15)}
.nav-btn.green{background:rgba(5,150,105,.08);border-color:rgba(5,150,105,.3);color:var(--green)}
.nav-btn.green:hover{background:rgba(5,150,105,.15)}

/* modal */
.modal-bg{position:fixed;inset:0;background:rgba(15,23,42,.35);z-index:500;display:flex;align-items:center;justify-content:center;backdrop-filter:blur(2px)}
.modal{background:var(--bg);border:1px solid var(--border2);border-radius:10px;width:520px;max-width:95vw;box-shadow:0 20px 60px rgba(0,0,0,.12)}
.modal-h{display:flex;align-items:center;justify-content:space-between;padding:16px 20px;border-bottom:1px solid var(--border)}
.modal-title{font-family:'Syne',sans-serif;font-size:14px;font-weight:800;color:var(--text)}
.modal-body{padding:20px;display:flex;flex-direction:column;gap:14px}
.modal-foot{padding:12px 20px;border-top:1px solid var(--border);display:flex;justify-content:flex-end;gap:8px;background:var(--bg2)}
.form-group{display:flex;flex-direction:column;gap:5px}
.form-label{font-size:10px;color:var(--text3);letter-spacing:.5px;text-transform:uppercase}
.form-input{font-family:'JetBrains Mono',monospace;font-size:12px;padding:8px 12px;border:1px solid var(--border2);border-radius:5px;background:var(--bg2);color:var(--text);outline:none;transition:border-color .15s}
.form-input:focus{border-color:var(--cyan);background:var(--bg)}
.form-hint{font-size:10px;color:var(--text3)}

/* project info banner */
.proj-banner{background:rgba(2,132,199,.04);border:1px solid rgba(2,132,199,.2);border-radius:6px;padding:10px 14px;margin-bottom:0}
.proj-goal{font-size:12px;color:var(--text);font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.proj-dir{font-size:10px;color:var(--cyan);margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}

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

/* dispatch panel */
.dp-body{padding:16px;display:flex;flex-direction:column;gap:12px}
.dp-row{display:flex;gap:8px;align-items:flex-start}
.dp-label{font-size:10px;color:var(--text3);letter-spacing:.5px;margin-bottom:4px;text-transform:uppercase}
.dp-agents{display:flex;flex-wrap:wrap;gap:6px}
.agent-chip{display:flex;align-items:center;gap:5px;padding:4px 10px;border:1px solid var(--border2);border-radius:4px;cursor:pointer;font-size:11px;color:var(--text2);background:var(--bg2);transition:all .15s;user-select:none}
.agent-chip:hover{border-color:var(--border2);background:var(--bg3)}
.agent-chip.sel{border-color:var(--cyan);background:rgba(2,132,199,.06);color:var(--cyan)}
.agent-chip .chip-dot{width:6px;height:6px;border-radius:50%;background:var(--border2)}
.agent-chip.sel .chip-dot{background:var(--cyan)}
.dp-ta{width:100%;min-height:80px;padding:10px 12px;font-family:'JetBrains Mono',monospace;font-size:12px;color:var(--text);background:var(--bg2);border:1px solid var(--border2);border-radius:6px;resize:vertical;outline:none;transition:border-color .15s}
.dp-ta:focus{border-color:var(--cyan);background:var(--bg)}
.dp-actions{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.btn{font-family:'JetBrains Mono',monospace;font-size:11px;font-weight:700;letter-spacing:.5px;padding:7px 16px;border-radius:5px;border:1px solid;cursor:pointer;transition:all .15s}
.btn-send{background:var(--cyan);border-color:var(--cyan);color:#fff}
.btn-send:hover{background:#0369a1}
.btn-send:disabled{opacity:.4;cursor:not-allowed}
.btn-all{background:rgba(5,150,105,.08);border-color:rgba(5,150,105,.3);color:var(--green)}
.btn-all:hover{background:rgba(5,150,105,.15)}
.btn-wk{background:rgba(124,58,237,.08);border-color:rgba(124,58,237,.3);color:var(--purple)}
.btn-wk:hover{background:rgba(124,58,237,.15)}
.btn-clear{background:none;border-color:var(--border2);color:var(--text3)}
.btn-clear:hover{color:var(--red);border-color:var(--red)}
.dp-status{font-size:11px;color:var(--text3);margin-left:4px}
.dp-status.ok{color:var(--green)}
.dp-status.err{color:var(--red)}

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
  <a href="/" class="logo">oah<span>://</span><span style="font-size:11px;font-weight:400;color:var(--text3);"> control</span></a>
  <div class="nr">
    <button class="nav-btn green" onclick="openWkModal()">+ New Work Key</button>
    <div class="ns"><div class="sd" id="sd"></div><span id="cl">연결 중...</span></div>
  </div>
</div></div></nav>

<!-- WORK KEY MODAL -->
<div class="modal-bg" id="wk-modal" style="display:none" onclick="if(event.target===this)closeWkModal()">
  <div class="modal">
    <div class="modal-h">
      <span class="modal-title">새 프로젝트 Work Key</span>
      <button class="ph-close" onclick="closeWkModal()">✕</button>
    </div>
    <div class="modal-body">
      <div class="form-group">
        <label class="form-label">프로젝트 목표 (Goal)</label>
        <input class="form-input" id="wk-goal" placeholder="예) FastAPI 쇼핑몰 서버 구현" autocomplete="off"/>
        <span class="form-hint">에이전트들이 공유하는 이번 세션의 목표</span>
      </div>
      <div class="form-group">
        <label class="form-label">NAS / 프로젝트 디렉토리</label>
        <input class="form-input" id="wk-dir" placeholder="/Volumes/homes/kilosnetwork/nas-dev/nas_workspace/project4" autocomplete="off"/>
        <span class="form-hint">에이전트들이 작업할 PROJECT_DIR (서버가 join 시 자동 전달)</span>
      </div>
      <div class="form-group">
        <label class="form-label">공유 컨텍스트 (JSON, 선택)</label>
        <input class="form-input" id="wk-ctx" placeholder='{"stack":"fastapi","python":"3.12"}' autocomplete="off"/>
        <span class="form-hint">에이전트들이 읽을 수 있는 공유 메타데이터</span>
      </div>
    </div>
    <div class="modal-foot">
      <button class="btn btn-clear" onclick="closeWkModal()">취소</button>
      <button class="btn btn-send" onclick="createWorkKey()">Work Key 생성</button>
    </div>
  </div>
</div>

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

    <!-- DISPATCH PANEL -->
    <div class="panel">
      <div class="ph">
        <div class="ph-left"><span class="pt">태스크 디스패치</span><span class="pb" id="dp-wk-badge">—</span></div>
        <div style="display:flex;gap:8px">
          <button class="btn btn-all" onclick="selectAllBuilders()">모든 builder</button>
          <button class="btn btn-wk" onclick="openWkModal()">+ Work Key</button>
        </div>
      </div>
      <div id="proj-banner" style="display:none;padding:10px 16px;border-bottom:1px solid var(--border)">
        <div class="proj-banner">
          <div class="proj-goal" id="proj-goal-text"></div>
          <div class="proj-dir" id="proj-dir-text"></div>
        </div>
      </div>
      <div class="dp-body">
        <div>
          <div class="dp-label">수신 에이전트 (복수 선택 가능)</div>
          <div class="dp-agents" id="dp-agents"><span style="font-size:11px;color:var(--text3)">에이전트 없음</span></div>
        </div>
        <div>
          <div class="dp-label">Instructions</div>
          <textarea class="dp-ta" id="dp-instr" placeholder="에이전트에게 내릴 작업 지시를 입력하세요...&#10;예) src/cart.py를 작성하라. FastAPI APIRouter, JWT 인증 필요, GET /cart, POST /cart/items..."></textarea>
        </div>
        <div class="dp-actions">
          <button class="btn btn-send" id="dp-send" onclick="dispatch()">▶ 전송</button>
          <button class="btn btn-clear" onclick="clearDispatch()">지우기</button>
          <span class="dp-status" id="dp-status"></span>
        </div>
      </div>
    </div>

    <!-- AGENT DETAIL (click to show) -->
    <div class="panel" id="adp" style="display:none">
      <div class="ph">
        <div class="ph-left"><span class="pt">에이전트 상세</span><span class="pb" id="adp-name">—</span></div>
        <div style="display:flex;gap:8px;align-items:center">
          <button class="btn btn-send" style="padding:3px 10px;font-size:10px" onclick="dispatchToSelected()">▶ 이 에이전트에게 전송</button>
          <button class="ph-close" onclick="closeAgentDetail()" title="닫기">✕</button>
        </div>
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
let agentState={};
let allAgents=[];
let dispatchTargets=new Set(); // selected agent names for dispatch

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
    renderDispatchAgents(allAgents);
    renderWks(w.work_keys||[]);
    id('s4').textContent=new Date().toLocaleTimeString('ko',{hour:'2-digit',minute:'2-digit',second:'2-digit'});
    if(selWk)loadState(selWk);
    if(selAgent)refreshAgentDetail(selAgent);
  }catch(err){
    if(connected){connected=false;addLog('system','연결 끊김');}
    setConn('off','연결 실패');
    allAgents=[];
    renderAgents([]);
    renderDispatchAgents([]);
  }
}

// ── Dispatch panel ────────────────────────────────────────────────────────────

function renderDispatchAgents(agents){
  const el=id('dp-agents');
  if(!agents.length){el.innerHTML='<span style="font-size:11px;color:var(--text3)">에이전트 없음</span>';return;}
  el.innerHTML=agents.map(a=>{
    const name=a.name||'?';
    const role=(a.role||'builder').toLowerCase();
    const isSel=dispatchTargets.has(name);
    return`<div class="agent-chip${isSel?' sel':''}" onclick="toggleTarget('${e(name)}')" data-dname="${e(name)}">
      <div class="chip-dot"></div>${e(name)} <span class="rc ${role}" style="margin-left:2px">${role}</span>
    </div>`;
  }).join('');
  id('dp-wk-badge').textContent=selWk||'—';
}

function toggleTarget(name){
  if(dispatchTargets.has(name))dispatchTargets.delete(name);
  else dispatchTargets.add(name);
  document.querySelectorAll('[data-dname]').forEach(el=>{
    const sel=dispatchTargets.has(el.dataset.dname);
    el.classList.toggle('sel',sel);
    el.querySelector('.chip-dot').style.background=sel?'var(--cyan)':'var(--border2)';
  });
}

function selectAllBuilders(){
  dispatchTargets.clear();
  allAgents.filter(a=>(a.role||'').toLowerCase()==='builder').forEach(a=>dispatchTargets.add(a.name));
  renderDispatchAgents(allAgents);
}

async function dispatch(){
  const instr=id('dp-instr').value.trim();
  if(!instr){id('dp-status').textContent='Instructions를 입력하세요';id('dp-status').className='dp-status err';return;}
  if(!dispatchTargets.size){id('dp-status').textContent='에이전트를 선택하세요';id('dp-status').className='dp-status err';return;}

  const btn=id('dp-send');
  btn.disabled=true;
  id('dp-status').textContent='전송 중...';id('dp-status').className='dp-status';

  const wk=selWk||(await fetch('/api/work-keys/latest').then(r=>r.json()).then(d=>d.work_key).catch(()=>null));
  const targets=[...dispatchTargets];
  let ok=0,fail=0;

  await Promise.all(targets.map(async to=>{
    const agent=allAgents.find(a=>a.name===to);
    const role=(agent?.role||'builder').toLowerCase();
    try{
      const res=await fetch('/api/task',{method:'POST',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({work_key:wk,to,role,instructions:instr})});
      if(res.ok){ok++;addLog('task.assign',`→ ${to}: ${instr.slice(0,50)}`,null);}
      else fail++;
    }catch{fail++;}
  }));

  btn.disabled=false;
  if(fail===0){
    id('dp-status').textContent=`✓ ${ok}개 에이전트에 전송 완료`;
    id('dp-status').className='dp-status ok';
    setTimeout(()=>{id('dp-status').textContent='';},4000);
  }else{
    id('dp-status').textContent=`${ok}개 성공, ${fail}개 실패`;
    id('dp-status').className='dp-status err';
  }
}

function dispatchToSelected(){
  if(selAgent){dispatchTargets.clear();dispatchTargets.add(selAgent);renderDispatchAgents(allAgents);}
  document.querySelector('.dp-ta')?.focus();
}

function clearDispatch(){
  id('dp-instr').value='';
  dispatchTargets.clear();
  renderDispatchAgents(allAgents);
  id('dp-status').textContent='';
}

// ── Work Key modal ────────────────────────────────────────────────────────────
function openWkModal(){
  id('wk-modal').style.display='flex';
  id('wk-goal').focus();
}
function closeWkModal(){
  id('wk-modal').style.display='none';
  id('wk-goal').value='';id('wk-dir').value='';id('wk-ctx').value='';
}
async function createWorkKey(){
  const goal=id('wk-goal').value.trim();
  const project_dir=id('wk-dir').value.trim();
  const ctxRaw=id('wk-ctx').value.trim();
  let context={};
  if(ctxRaw){try{context=JSON.parse(ctxRaw);}catch{alert('컨텍스트 JSON 형식 오류');return;}}
  try{
    const res=await fetch('/api/work-keys',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({goal:goal||null,project_dir:project_dir||null,context})});
    const d=await res.json();
    selWk=d.work_key;
    closeWkModal();
    addLog('system',`Work Key 생성: ${d.work_key}${goal?' — '+goal:''}`);
    wsJoinNewWorkKey(d.work_key);
    poll();
  }catch{addLog('system','Work Key 생성 실패');}
}

// ── Agent list ────────────────────────────────────────────────────────────────

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
                  :isDone?`<div class="a-task" style="color:var(--green)">✓ ${e((st.instructions||'').slice(0,35)+'…')}</div>`:'';
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
      ${(taskOutput[name]||agentLogs.length)?`<div class="adet-row">
        <div class="adet-k">${taskOutput[name]?'실시간 출력':'최근 이벤트'}</div>
        <div class="adet-v">${taskOutput[name]
          ?`<pre id="adp-live-out" style="font-size:10px;color:var(--text2);background:var(--bg3);border:1px solid var(--border2);border-radius:4px;padding:8px 10px;max-height:160px;overflow-y:auto;white-space:pre-wrap;word-break:break-all;line-height:1.5;margin:0">${e(taskOutput[name])}</pre>`
          :`<div style="font-size:10px;color:var(--text3);line-height:1.8">${agentLogs.map(l=>`<span style="color:var(--text3)">${e(l.t)}</span> <span class="lv ${l.ev.replace(/\./g,'-')}" style="font-size:10px">${e(l.ev)}</span> ${e(l.msg.slice(0,50))}`).join('<br>')}</div>`
        }</div>
      </div>`:''}
      <div class="adet-row">
        <div class="adet-k">로그 필터</div>
        <div class="adet-v"><button onclick="setLogFilter('${e(name)}')" style="background:var(--bg3);border:1px solid var(--border2);color:var(--cyan);font-family:inherit;font-size:10px;padding:3px 10px;border-radius:3px;cursor:pointer;letter-spacing:.5px">이 에이전트만 보기</button></div>
      </div>
    </div>`;
}

// ── Log ───────────────────────────────────────────────────────────────────────

function setLogFilter(name){
  logFilter=name;id('log-filter-bar').style.display='';
  id('log-filter-label').textContent=name;id('log-clear-filter').style.display='';
  renderFilteredLog();
}
function clearLogFilter(){
  logFilter=null;id('log-filter-bar').style.display='none';id('log-clear-filter').style.display='none';
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

let wkMeta={}; // wk -> {goal, project_dir}

function renderWks(wks){
  id('wc').textContent=wks.length;id('s2').textContent=wks.length;
  const el=id('wl');
  if(!wks.length){el.innerHTML='<div class="empty"><div class="ei">🔑</div>없음</div>';return;}
  if(!selWk&&wks.length)selWk=wks[wks.length-1];
  el.innerHTML=wks.slice().reverse().map(wk=>{
    const m=wkMeta[wk]||{};
    return`<div class="wki fi${wk===selWk?' sel':''}" onclick="pickWk('${e(wk)}')">
      <div class="wkk">${e(wk)}</div>
      <div class="wkm">${m.goal?e(m.goal.slice(0,40)):'클릭해서 상태 확인'}</div>
      ${m.project_dir?`<div style="font-size:9px;color:var(--cyan);margin-top:2px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${e(m.project_dir)}</div>`:''}
    </div>`;
  }).join('');
  id('dp-wk-badge').textContent=selWk||'—';
  if(selWk&&wks.includes(selWk))loadState(selWk);
  else if(wks.length)loadState(wks[wks.length-1]);
}

function pickWk(wk){
  selWk=wk;
  document.querySelectorAll('.wki').forEach(el=>el.classList.toggle('sel',el.querySelector('.wkk').textContent===wk));
  id('dp-wk-badge').textContent=wk;
  loadState(wk);
}

async function loadState(wk){
  try{
    const res=await fetch(`/api/state/${encodeURIComponent(wk)}`,{signal:AbortSignal.timeout(3000)});
    if(!res.ok)return;
    const data=await res.json();
    const state=data.state||data||{};
    id('sp').style.display='';id('swk').textContent=wk;

    // cache metadata and update project banner
    const goal=state.goal||state['goal']||null;
    const projDir=state.project_dir||state['project_dir']||null;
    wkMeta[wk]={goal,project_dir:projDir};

    const banner=id('proj-banner');
    if(goal||projDir){
      banner.style.display='';
      id('proj-goal-text').textContent=goal?`🎯 ${goal}`:'—';
      id('proj-dir-text').textContent=projDir?`📁 ${projDir}`:'';
    } else {
      banner.style.display='none';
    }

    // filter out internal fields for display
    const hidden=new Set(['work_key','created_at','updated_at','loop_count','tasks','shared_context']);
    const entries=Object.entries(state).filter(([k])=>!hidden.has(k));
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
  if(selAgent&&(agentName===selAgent||msg.includes(selAgent)))refreshAgentDetail(selAgent);
}

// ── WebSocket (Phoenix Channel observer) ─────────────────────────────────────
// Connects to the Phoenix Channel as a read-only observer.
// • Joins all existing work key channels on connect
// • Auto-joins new channels when created (via createWorkKey)
// • Exponential backoff reconnect (1s → 30s)
// • Tracks task.progress output per agent for live tail

let wsRef=1;
let wsJoinRef=null;
let wsJoinedTopics=new Set(); // topics we've joined in this WS session
let wsReconnectDelay=1000;
let wsHbTimer=null;
const taskOutput={}; // agent → latest output tail

function wsSend(arr){try{if(ws?.readyState===1)ws.send(JSON.stringify(arr));}catch{}}

function wsJoinTopic(topic){
  if(wsJoinedTopics.has(topic))return;
  wsJoinedTopics.add(topic);
  const jref=String(wsRef++);
  wsJoinRef=jref;
  wsSend([jref,jref,topic,'phx_join',{role:'observer',agent_name:'dashboard@browser'}]);
}

function connectWs(){
  const proto=location.protocol==='https:'?'wss':'ws';
  ws=new WebSocket(`${proto}://${location.host}/socket/websocket?vsn=2.0.0&agent_name=dashboard@browser&role=observer`);

  ws.onopen=()=>{
    wsReconnectDelay=1000;
    wsJoinedTopics.clear();
    if(wsHbTimer)clearInterval(wsHbTimer);
    wsHbTimer=setInterval(()=>wsSend([null,String(wsRef++),'phoenix','heartbeat',{}]),30000);

    // Join all current work key channels
    fetch('/api/work-keys').then(r=>r.json()).then(d=>{
      (d.work_keys||[]).forEach(wk=>wsJoinTopic('work:'+wk));
    }).catch(()=>{});
  };

  ws.onmessage=evt=>{
    try{
      const [,, topic, ev, payload]=JSON.parse(evt.data);

      // Ignore protocol internals
      if(ev==='phx_reply'){
        // Successful join — if topic is a new WK, update UI
        if(payload?.status==='ok'&&topic.startsWith('work:')){
          const wk=topic.replace('work:','');
          if(!document.querySelector(`.wkk[data-wk="${wk}"]`))poll();
        }
        return;
      }
      if(ev==='phx_error'||ev==='phx_close'||ev==='presence_state'||ev==='presence_diff'||topic==='phoenix')return;

      const from=payload?.from||payload?.agent||null;
      const taskId=payload?.task_id||'';
      let msg='';

      if(ev==='task.assign'){
        const to=payload?.to||'broadcast';
        const instr=(payload?.instructions||'').slice(0,80);
        msg=`→ ${to}: ${instr}`;
        if(to&&to!=='broadcast'){
          agentState[to]=agentState[to]||{};
          Object.assign(agentState[to],{
            task_id:taskId,
            instructions:payload?.instructions||'',
            status:'working',
            started:new Date().toISOString(),
            completed:null,
            exit_code:null
          });
          taskOutput[to]='';
          renderAgents(allAgents);
        }
      } else if(ev==='task.result'){
        const agentFrom=payload?.from||'?';
        const exitCode=payload?.exit_code??'?';
        msg=`${agentFrom}: exit=${exitCode} — ${taskId}`;
        tasks++;id('s3').textContent=tasks;
        if(agentFrom&&agentState[agentFrom]){
          Object.assign(agentState[agentFrom],{
            status: exitCode===0||exitCode==='0'?'done':'error',
            exit_code: exitCode,
            completed: new Date().toISOString()
          });
          taskOutput[agentFrom]='';
          renderAgents(allAgents);
        }
      } else if(ev==='task.progress'){
        const tail=payload?.output_tail||'';
        if(tail&&from){
          taskOutput[from]=tail;
          // Append to agent detail if open
          const outEl=id('adp-live-out');
          if(outEl&&selAgent===from){
            outEl.textContent=tail;outEl.scrollTop=outEl.scrollHeight;
          }
        }
        msg=`${from||'?'}: ${payload?.message||'working...'}`;
      } else if(ev==='task.blocked'){
        const agentFrom=payload?.from||'?';
        msg=`${agentFrom}: ${payload?.error||payload?.reason||taskId}`;
        if(agentFrom&&agentState[agentFrom]){
          agentState[agentFrom].status='blocked';
          renderAgents(allAgents);
        }
      } else if(ev==='agent.hello'){
        const a=payload?.agent||'?';
        msg=`${a} (${payload?.role||'?'}) @ ${payload?.machine||'?'}`;
        // Immediately add to agent list without waiting for next poll
        const existing=allAgents.find(x=>x.name===a);
        if(!existing){
          allAgents=[...allAgents,{
            name:a,role:payload?.role||'builder',
            machine:payload?.machine||'',
            work_key:payload?.work_key||selWk||'',
            online_since:new Date().toISOString()
          }];
          renderAgents(allAgents);renderDispatchAgents(allAgents);
        }
      } else if(ev==='agent.bye'){
        const a=payload?.agent||'?';
        msg=`${a} 퇴장`;
        allAgents=allAgents.filter(x=>x.name!==a);
        renderAgents(allAgents);renderDispatchAgents(allAgents);
      } else {
        msg=payload?.message||taskId||JSON.stringify(payload).slice(0,80);
      }

      addLog(ev,msg,from);
    }catch{}
  };

  ws.onclose=()=>{
    if(wsHbTimer){clearInterval(wsHbTimer);wsHbTimer=null;}
    wsJoinedTopics.clear();
    console.log('[ws] reconnecting in',wsReconnectDelay,'ms');
    setTimeout(connectWs,wsReconnectDelay);
    wsReconnectDelay=Math.min(wsReconnectDelay*2,30000);
    if(connected){connected=false;addLog('system','WebSocket 재연결 중...');}
  };

  ws.onerror=()=>ws?.close();
}

// Called after creating a new work key so the dashboard joins that channel too
function wsJoinNewWorkKey(wk){wsJoinTopic('work:'+wk);}

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
