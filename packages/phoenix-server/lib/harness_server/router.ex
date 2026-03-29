defmodule HarnessServer.Router do
  @moduledoc "REST API router for the harness state server."

  use Plug.Router

  alias HarnessServer.{Presence, StateStore}

  plug Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason

  plug :match
  plug :dispatch

  # ── GET /setup ──────────────────────────────────────────────────────────────
  # One-liner agent installer. Auto-detects OS (bash vs PowerShell).
  # Usage:
  #   bash <(curl -fsSL http://oah.local:4000/setup)
  #   bash <(curl -fsSL http://oah.local:4000/setup?role=executor)
  #   iwr http://oah.local:4000/setup.ps1 | iex  (Windows)

  get "/setup" do
    role = conn.query_params["role"] || "builder"
    server_host = get_server_host(conn)

    script = """
    #!/usr/bin/env bash
    set -euo pipefail
    PHOENIX="${PHOENIX:-ws://#{server_host}:4000}"
    ROLE="${ROLE:-#{role}}"
    curl -fsSL http://#{server_host}:4000/setup-agent.sh | PHOENIX="$PHOENIX" ROLE="$ROLE" bash
    """

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, script)
  end

  # Windows one-liner:
  #   curl -fsSL http://SERVER:4000/go -o go.cmd && go.cmd && del go.cmd
  get "/go" do
    server_host = get_server_host(conn)
    role = conn.query_params["role"] || ""

    role_line = if role != "", do: "set AGENT_ROLE=#{role}\r\n", else: ""

    script = "@echo off\r\n" <>
             "set STATE_SERVER=ws://#{server_host}:4000\r\n" <>
             role_line <>
             "echo [oah] Downloading agent...\r\n" <>
             "curl -fsSL \"http://#{server_host}:4000/dist/oah-agent-windows.exe\" -o \"%TEMP%\\oah-agent.exe\"\r\n" <>
             "echo [oah] Starting...\r\n" <>
             "\"%TEMP%\\oah-agent.exe\"\r\n"

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, script)
  end

  get "/setup.ps1" do
    role = conn.query_params["role"] || "builder"
    server_host = get_server_host(conn)

    script = """
    $Phoenix = if ($env:PHOENIX) { $env:PHOENIX } else { "ws://#{server_host}:4000" }
    $Role    = if ($env:ROLE)    { $env:ROLE }    else { "#{role}" }
    Invoke-WebRequest "http://#{server_host}:4000/setup-agent.ps1" -OutFile "$env:TEMP\\oah-setup.ps1"
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    & "$env:TEMP\\oah-setup.ps1" -Phoenix $Phoenix -Role $Role
    """

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, script)
  end

  get "/setup-agent.sh" do
    script_path = Path.join([:code.priv_dir(:harness_server), "scripts", "setup-agent.sh"])

    case File.read(script_path) do
      {:ok, content} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, content)

      {:error, _} ->
        send_json(conn, 404, %{error: "setup-agent.sh not found"})
    end
  end

  get "/setup-agent.ps1" do
    script_path = Path.join([:code.priv_dir(:harness_server), "scripts", "setup-agent.ps1"])

    case File.read(script_path) do
      {:ok, content} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, content)

      {:error, _} ->
        send_json(conn, 404, %{error: "setup-agent.ps1 not found"})
    end
  end

  get "/dist/oah-agent-windows.exe" do
    exe_path = Path.join([:code.priv_dir(:harness_server), "dist", "oah-agent-windows.exe"])

    case File.read(exe_path) do
      {:ok, content} ->
        conn
        |> put_resp_header("content-disposition", "attachment; filename=\"oah-agent.exe\"")
        |> put_resp_content_type("application/octet-stream")
        |> send_resp(200, content)

      {:error, _} ->
        send_json(conn, 404, %{error: "binary not found — run: bun build"})
    end
  end

  # ── GET /api/health ─────────────────────────────────────────────────────────

  get "/api/health" do
    work_keys = StateStore.list_work_keys()

    send_json(conn, 200, %{
      ok: true,
      version: "0.2.0",
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

  # ── DELETE /api/presence/:agent_name ────────────────────────────────────────
  # Force-disconnect a stale agent from presence (useful for ghost cleanup).
  # Uses the socket ID convention: "agent:{agent_name}"

  delete "/api/presence/:agent_name" do
    socket_id = "agent:#{agent_name}"
    HarnessServer.Endpoint.broadcast(socket_id, "disconnect", %{})
    send_json(conn, 200, %{ok: true, disconnected: agent_name})
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

  # ── POST /api/task/:task_id/cancel ──────────────────────────────────────────
  # Cancel a running task. Body: {"work_key": "LN-..."}

  post "/api/task/:task_id/cancel" do
    wk = Map.get(conn.body_params, "work_key") || StateStore.latest_work_key()
    if wk do
      HarnessServer.Endpoint.broadcast("work:#{wk}", "task.cancel", %{"task_id" => task_id})
      send_json(conn, 200, %{ok: true, task_id: task_id, work_key: wk})
    else
      send_json(conn, 400, %{error: "work_key required"})
    end
  end

  # ── GET /api/task/:task_id ───────────────────────────────────────────────────
  # Poll for task result. Returns 202 while pending, 200 when done.

  get "/api/task/:task_id" do
    case StateStore.get_task_result(task_id) do
      {:ok, [single]} -> send_json(conn, 200, single)
      {:ok, results}  -> send_json(conn, 200, %{task_id: task_id, results: results, count: length(results)})
      :not_found      -> send_json(conn, 202, %{status: "pending", task_id: task_id})
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

  defp get_server_host(conn) do
    # Use the Host header so the script uses the same address the client connected with
    case Plug.Conn.get_req_header(conn, "host") do
      [host | _] -> host |> String.split(":") |> List.first()
      [] -> "oah.local"
    end
  end

  # rubric: embedded dashboard HTML served at GET /
  # Uses relative /api/* URLs so it always hits the same server.
  # Features: task dispatch, WK create/edit/state, task history,
  #           agent detail + mailbox, event log, real-time WS.
  defp dashboard_html do
    ~S"""
<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1.0"/>
<title>OAH Control</title>
<link rel="preconnect" href="https://fonts.googleapis.com"/>
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;700&family=Syne:wght@700;800&display=swap" rel="stylesheet"/>
<style>
:root{--bg:#0f172a;--bg2:#1e293b;--bg3:#263045;--border:#2d3f5a;--border2:#3d5270;--text:#e2e8f0;--text2:#94a3b8;--text3:#64748b;--cyan:#38bdf8;--green:#34d399;--orange:#fb923c;--purple:#a78bfa;--red:#f87171;--amber:#fbbf24;--yellow:#facc15}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%}
body{background:var(--bg);color:var(--text);font-family:'JetBrains Mono',monospace;font-size:12px;line-height:1.5;display:flex;flex-direction:column}
/* nav */
nav{flex-shrink:0;background:var(--bg2);border-bottom:1px solid var(--border);display:flex;align-items:center;justify-content:space-between;padding:0 20px;height:48px;position:sticky;top:0;z-index:100}
.logo{font-family:'Syne',sans-serif;font-weight:800;font-size:14px;color:var(--text);text-decoration:none;display:flex;align-items:center;gap:6px}
.logo .dot{width:8px;height:8px;border-radius:50%;background:var(--cyan);box-shadow:0 0 8px var(--cyan)}
.nav-r{display:flex;align-items:center;gap:10px}
.badge-conn{display:flex;align-items:center;gap:5px;font-size:10px;padding:3px 10px;border-radius:20px;border:1px solid var(--border2);color:var(--text2)}
.badge-conn .dot{width:6px;height:6px;border-radius:50%;background:var(--border2)}
.badge-conn.on .dot{background:var(--green);box-shadow:0 0 6px var(--green);animation:pulse 2s infinite}
.badge-conn.off .dot{background:var(--red)}
/* layout */
.app{display:flex;flex:1;overflow:hidden}
.sb{width:260px;flex-shrink:0;border-right:1px solid var(--border);display:flex;flex-direction:column;overflow:hidden}
.sb-section{display:flex;flex-direction:column;overflow:hidden}
.sb-section.wk-section{flex:0 0 auto;max-height:50%}
.sb-section.ag-section{flex:1;min-height:0;border-top:1px solid var(--border)}
.sb-h{display:flex;align-items:center;justify-content:space-between;padding:8px 12px;background:var(--bg2);flex-shrink:0;border-bottom:1px solid var(--border)}
.sb-ht{font-size:9px;font-weight:700;letter-spacing:2px;color:var(--text3);text-transform:uppercase}
.sb-list{overflow-y:auto;flex:1}
/* WK item */
.wki{padding:10px 12px;border-bottom:1px solid var(--border);cursor:pointer;transition:background .1s;display:flex;flex-direction:column;gap:2px}
.wki:hover{background:var(--bg3)}
.wki.sel{background:rgba(56,189,248,.06);border-left:2px solid var(--cyan)}
.wki-key{font-size:11px;color:var(--cyan);font-weight:500}
.wki-goal{font-size:10px;color:var(--text2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.wki-dir{font-size:9px;color:var(--text3);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:1px}
.wki-meta{display:flex;align-items:center;gap:6px;margin-top:3px}
.wki-status{font-size:9px;padding:1px 5px;border-radius:2px;font-weight:700;letter-spacing:.5px}
.wki-status.created{background:rgba(100,116,139,.15);color:var(--text3)}
.wki-status.running{background:rgba(251,146,60,.15);color:var(--orange)}
.wki-status.done{background:rgba(52,211,153,.15);color:var(--green)}
.wki-edit{background:none;border:none;color:var(--text3);cursor:pointer;font-size:11px;padding:1px 3px;opacity:0;transition:opacity .15s;margin-left:auto}
.wki:hover .wki-edit{opacity:1}
.wki-edit:hover{color:var(--cyan)}
/* agent item */
.agi{padding:10px 12px;border-bottom:1px solid var(--border);cursor:pointer;transition:background .1s;display:flex;align-items:center;gap:8px}
.agi:hover{background:var(--bg3)}
.agi.sel{background:rgba(56,189,248,.06);border-left:2px solid var(--cyan)}
.agi-dot{width:7px;height:7px;border-radius:50%;flex-shrink:0}
.agi-dot.g{background:var(--green);box-shadow:0 0 5px var(--green);animation:pulse 2s infinite}
.agi-dot.c{background:var(--cyan);box-shadow:0 0 5px var(--cyan);animation:pulse 2s infinite}
.agi-dot.o{background:var(--orange);box-shadow:0 0 5px var(--orange);animation:pulse 2s infinite}
.agi-dot.p{background:var(--purple);box-shadow:0 0 5px var(--purple);animation:pulse 2s infinite}
.agi-info{flex:1;min-width:0}
.agi-name{font-size:11px;color:var(--text);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.agi-sub{font-size:9px;color:var(--text3);margin-top:1px}
.agi-task{font-size:9px;color:var(--orange);margin-top:1px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.role-tag{font-size:8px;font-weight:700;letter-spacing:.5px;padding:1px 5px;border-radius:2px;flex-shrink:0;text-transform:uppercase}
.role-tag.orchestrator{background:rgba(56,189,248,.15);color:var(--cyan)}
.role-tag.builder{background:rgba(52,211,153,.15);color:var(--green)}
.role-tag.verifier{background:rgba(167,139,250,.15);color:var(--purple)}
.role-tag.reviewer,.role-tag.integrator{background:rgba(251,146,60,.15);color:var(--orange)}
/* main */
.main{flex:1;display:flex;flex-direction:column;overflow:hidden}
/* stats bar */
.stats-bar{display:flex;gap:1px;flex-shrink:0;background:var(--border);border-bottom:1px solid var(--border)}
.stat{flex:1;background:var(--bg2);padding:10px 16px;display:flex;align-items:baseline;gap:8px}
.stat-n{font-family:'Syne',sans-serif;font-size:22px;font-weight:800;line-height:1}
.stat-n.g{color:var(--green)}.stat-n.c{color:var(--cyan)}.stat-n.o{color:var(--orange)}.stat-n.p{color:var(--purple)}
.stat-l{font-size:9px;color:var(--text3);letter-spacing:1px;text-transform:uppercase}
/* content area - horizontal split */
.content{flex:1;display:flex;overflow:hidden}
.panels{flex:1;display:flex;flex-direction:column;overflow:hidden}
/* tabs */
.tabs{flex-shrink:0;display:flex;background:var(--bg2);border-bottom:1px solid var(--border);padding:0 16px;gap:2px}
.tab{padding:9px 14px;font-size:10px;font-weight:700;letter-spacing:.5px;color:var(--text3);cursor:pointer;border-bottom:2px solid transparent;transition:all .15s;text-transform:uppercase}
.tab:hover{color:var(--text2)}
.tab.active{color:var(--cyan);border-bottom-color:var(--cyan)}
.tab-content{display:none;flex:1;overflow-y:auto;padding:16px}
.tab-content.active{display:flex;flex-direction:column;gap:12px}
/* right panel: event log */
.log-panel{width:340px;flex-shrink:0;border-left:1px solid var(--border);display:flex;flex-direction:column;overflow:hidden}
.lp-h{display:flex;align-items:center;justify-content:space-between;padding:8px 12px;background:var(--bg2);border-bottom:1px solid var(--border);flex-shrink:0}
.lp-ht{font-size:9px;font-weight:700;letter-spacing:2px;color:var(--text3);text-transform:uppercase}
.lp-acts{display:flex;gap:6px;align-items:center}
.lp-filter{font-size:9px;color:var(--orange);background:none;border:none;cursor:pointer;padding:1px 4px}
.log-list{flex:1;overflow-y:auto;padding:0}
.log-item{padding:6px 12px;border-bottom:1px solid var(--border);display:grid;grid-template-columns:44px 1fr;gap:6px;align-items:start;font-size:10px}
.log-item:hover{background:var(--bg3)}
.log-t{color:var(--text3);font-size:9px;padding-top:1px}
.log-body{display:flex;flex-direction:column;gap:1px}
.log-ev{font-weight:700;font-size:9px;letter-spacing:.5px}
.log-ev.task-assign{color:var(--orange)}.log-ev.task-result{color:var(--green)}.log-ev.task-progress{color:var(--cyan)}.log-ev.task-blocked{color:var(--red)}.log-ev.agent-hello{color:var(--green)}.log-ev.agent-bye{color:var(--text3)}.log-ev.state-update{color:var(--purple)}.log-ev.system{color:var(--text3)}
.log-msg{color:var(--text2);font-size:10px;line-height:1.4;word-break:break-all}
/* panel card */
.card{background:var(--bg2);border:1px solid var(--border);border-radius:6px;overflow:hidden}
.card-h{display:flex;align-items:center;justify-content:space-between;padding:9px 14px;border-bottom:1px solid var(--border);background:var(--bg3)}
.card-ht{font-size:9px;font-weight:700;letter-spacing:2px;color:var(--text3);text-transform:uppercase}
.card-body{padding:14px}
/* dispatch */
.dp-wk-row{display:flex;align-items:center;gap:8px;margin-bottom:8px}
.dp-wk-label{font-size:9px;color:var(--text3);letter-spacing:.5px;text-transform:uppercase;white-space:nowrap}
.dp-wk-sel{flex:1;font-family:'JetBrains Mono',monospace;font-size:11px;padding:5px 10px;background:var(--bg3);border:1px solid var(--border2);border-radius:4px;color:var(--text);outline:none}
.dp-wk-sel:focus{border-color:var(--cyan)}
.dp-agents{display:flex;flex-wrap:wrap;gap:5px;margin-bottom:10px}
.chip{display:flex;align-items:center;gap:4px;padding:3px 9px;border:1px solid var(--border2);border-radius:3px;cursor:pointer;font-size:10px;color:var(--text2);background:var(--bg3);transition:all .12s;user-select:none}
.chip:hover{border-color:var(--border2);background:var(--bg)}
.chip.sel{border-color:var(--cyan);background:rgba(56,189,248,.08);color:var(--cyan)}
.chip .cd{width:5px;height:5px;border-radius:50%;background:var(--border2)}
.chip.sel .cd{background:var(--cyan)}
.dp-ta{width:100%;min-height:90px;padding:10px 12px;font-family:'JetBrains Mono',monospace;font-size:11px;color:var(--text);background:var(--bg3);border:1px solid var(--border2);border-radius:5px;resize:vertical;outline:none;transition:border-color .15s;line-height:1.6}
.dp-ta:focus{border-color:var(--cyan);background:var(--bg2)}
.dp-actions{display:flex;gap:7px;align-items:center;flex-wrap:wrap;margin-top:10px}
.btn{font-family:'JetBrains Mono',monospace;font-size:10px;font-weight:700;letter-spacing:.5px;padding:6px 14px;border-radius:4px;border:1px solid;cursor:pointer;transition:all .12s}
.btn-primary{background:var(--cyan);border-color:var(--cyan);color:var(--bg)}
.btn-primary:hover{opacity:.85}
.btn-primary:disabled{opacity:.35;cursor:not-allowed}
.btn-secondary{background:rgba(52,211,153,.08);border-color:rgba(52,211,153,.3);color:var(--green)}
.btn-secondary:hover{background:rgba(52,211,153,.15)}
.btn-ghost{background:none;border-color:var(--border2);color:var(--text3)}
.btn-ghost:hover{color:var(--red);border-color:var(--red)}
.btn-purple{background:rgba(167,139,250,.08);border-color:rgba(167,139,250,.3);color:var(--purple)}
.btn-purple:hover{background:rgba(167,139,250,.15)}
.btn-orange{background:rgba(251,146,60,.08);border-color:rgba(251,146,60,.3);color:var(--orange)}
.btn-orange:hover{background:rgba(251,146,60,.15)}
.dp-status{font-size:10px;color:var(--text3)}
.dp-status.ok{color:var(--green)}.dp-status.err{color:var(--red)}
/* task history */
.task-table{width:100%;border-collapse:collapse;font-size:11px}
.task-table th{text-align:left;font-size:9px;letter-spacing:1px;color:var(--text3);padding:6px 10px;border-bottom:1px solid var(--border);background:var(--bg3);text-transform:uppercase;font-weight:700}
.task-table td{padding:7px 10px;border-bottom:1px solid var(--border);vertical-align:middle}
.task-table tr:hover td{background:var(--bg3)}
.task-table tr:last-child td{border-bottom:none}
.ts-id{color:var(--text3);font-size:9px;max-width:120px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.ts-to{color:var(--cyan)}
.ts-instr{color:var(--text2);max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.ts-st{font-size:9px;font-weight:700;padding:2px 6px;border-radius:2px;letter-spacing:.5px}
.ts-st.working{background:rgba(251,146,60,.15);color:var(--orange)}
.ts-st.done{background:rgba(52,211,153,.15);color:var(--green)}
.ts-st.error{background:rgba(248,113,113,.15);color:var(--red)}
.ts-st.blocked{background:rgba(248,113,113,.15);color:var(--red)}
.ts-st.pending{background:rgba(100,116,139,.15);color:var(--text3)}
.ts-dur{color:var(--text3);font-size:10px;white-space:nowrap}
.ts-exit{font-size:9px;padding:1px 5px;border-radius:2px}
.ts-exit.ok{background:rgba(52,211,153,.1);color:var(--green)}
.ts-exit.err{background:rgba(248,113,113,.1);color:var(--red)}
/* output viewer */
.output-box{font-family:'JetBrains Mono',monospace;font-size:10px;background:var(--bg);border:1px solid var(--border);border-radius:4px;padding:10px 12px;max-height:220px;overflow-y:auto;white-space:pre-wrap;word-break:break-all;line-height:1.6;color:var(--text2)}
/* WK state editor */
.state-form{display:flex;flex-direction:column;gap:10px}
.sf-row{display:flex;flex-direction:column;gap:4px}
.sf-label{font-size:9px;color:var(--text3);letter-spacing:.5px;text-transform:uppercase}
.sf-input{font-family:'JetBrains Mono',monospace;font-size:11px;padding:7px 10px;background:var(--bg3);border:1px solid var(--border2);border-radius:4px;color:var(--text);outline:none;transition:border-color .15s;width:100%}
.sf-input:focus{border-color:var(--cyan);background:var(--bg2)}
.sf-ta{min-height:80px;resize:vertical}
.sf-hint{font-size:9px;color:var(--text3)}
.status-row{display:flex;gap:6px;flex-wrap:wrap}
.status-btn{font-size:10px;padding:4px 10px;border:1px solid var(--border2);border-radius:3px;cursor:pointer;font-family:'JetBrains Mono',monospace;font-weight:700;background:var(--bg3);color:var(--text2);transition:all .12s}
.status-btn:hover{border-color:var(--border2)}
.status-btn.created:hover,.status-btn.created.active{border-color:var(--text3);color:var(--text)}
.status-btn.running:hover,.status-btn.running.active{border-color:var(--orange);color:var(--orange);background:rgba(251,146,60,.08)}
.status-btn.done:hover,.status-btn.done.active{border-color:var(--green);color:var(--green);background:rgba(52,211,153,.08)}
.status-btn.failed:hover,.status-btn.failed.active{border-color:var(--red);color:var(--red);background:rgba(248,113,113,.08)}
/* mailbox */
.mb-item{background:var(--bg3);border:1px solid var(--border);border-radius:4px;padding:10px 12px;margin-bottom:6px;font-size:11px}
.mb-item:last-child{margin-bottom:0}
.mb-from{font-size:9px;color:var(--text3);margin-bottom:4px}
.mb-body{color:var(--text2);word-break:break-word;line-height:1.5}
/* agent detail card */
.adet-grid{display:grid;grid-template-columns:100px 1fr;gap:6px 14px;font-size:11px}
.adk{color:var(--text3);font-size:10px}
.adv{color:var(--text);word-break:break-word}
.adv.c{color:var(--cyan)}.adv.g{color:var(--green)}.adv.o{color:var(--orange)}
/* agent detail tabs */
.adt{display:flex;gap:0;border-bottom:1px solid var(--border);margin-bottom:12px}
.adt-tab{padding:6px 12px;font-size:9px;font-weight:700;letter-spacing:.5px;color:var(--text3);cursor:pointer;border-bottom:2px solid transparent;transition:all .12px;text-transform:uppercase}
.adt-tab.active{color:var(--cyan);border-bottom-color:var(--cyan)}
/* modal */
.modal-bg{position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:500;display:flex;align-items:center;justify-content:center;backdrop-filter:blur(3px)}
.modal{background:var(--bg2);border:1px solid var(--border2);border-radius:8px;width:520px;max-width:95vw;box-shadow:0 24px 80px rgba(0,0,0,.4)}
.modal-h{display:flex;align-items:center;justify-content:space-between;padding:14px 18px;border-bottom:1px solid var(--border)}
.modal-title{font-family:'Syne',sans-serif;font-size:13px;font-weight:800;color:var(--text)}
.modal-body{padding:18px;display:flex;flex-direction:column;gap:12px}
.modal-foot{padding:12px 18px;border-top:1px solid var(--border);display:flex;justify-content:flex-end;gap:7px;background:var(--bg3)}
.form-group{display:flex;flex-direction:column;gap:4px}
.form-label{font-size:9px;color:var(--text3);letter-spacing:.5px;text-transform:uppercase}
.form-input{font-family:'JetBrains Mono',monospace;font-size:11px;padding:7px 11px;border:1px solid var(--border2);border-radius:4px;background:var(--bg3);color:var(--text);outline:none;transition:border-color .15s;width:100%}
.form-input:focus{border-color:var(--cyan);background:var(--bg2)}
.form-hint{font-size:9px;color:var(--text3)}
/* misc */
.empty{padding:24px;text-align:center;color:var(--text3);font-size:11px}
.empty-icon{font-size:20px;margin-bottom:6px;opacity:.4}
.badge{font-size:9px;padding:1px 6px;border-radius:8px;background:var(--bg3);border:1px solid var(--border);color:var(--text2)}
.x-btn{background:none;border:none;color:var(--text3);cursor:pointer;font-size:13px;padding:1px 3px;line-height:1}
.x-btn:hover{color:var(--red)}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.5}}
@keyframes slide-in{from{opacity:0;transform:translateY(-6px)}to{opacity:1;transform:none}}
.slide-in{animation:slide-in .18s ease both}
/* file change tab */
.fc-item{background:var(--bg2);border:1px solid var(--border);border-radius:4px;padding:10px 14px;margin-bottom:6px;display:grid;grid-template-columns:130px 1fr;gap:4px 12px;align-items:start;font-size:11px}
.fc-meta{display:flex;flex-direction:column;gap:3px}
.fc-agent{color:var(--cyan);font-size:10px;font-weight:700}
.fc-taskid{color:var(--text3);font-size:9px}
.fc-ts{color:var(--text3);font-size:9px}
.fc-files{display:flex;flex-direction:column;gap:3px}
.fc-file{font-size:10px;color:var(--text2);padding:2px 6px;background:var(--bg3);border:1px solid var(--border);border-radius:3px;word-break:break-all}
.fc-file::before{content:'📄 ';font-size:9px}
/* agent chat tab */
.chat-item{padding:8px 14px;display:flex;flex-direction:column;gap:4px;border-bottom:1px solid var(--border)}
.chat-item:hover{background:var(--bg3)}
.chat-header{display:flex;align-items:center;gap:6px;flex-wrap:wrap}
.chat-from{color:var(--cyan);font-weight:700;font-size:10px}
.chat-arrow{color:var(--text3);font-size:10px}
.chat-to{color:var(--orange);font-weight:700;font-size:10px}
.chat-ev{font-size:8px;padding:1px 5px;border:1px solid var(--border);border-radius:2px;color:var(--text3);text-transform:uppercase;letter-spacing:.5px}
.chat-ev.task-assign{border-color:rgba(251,146,60,.3);color:var(--orange)}
.chat-ev.mailbox-message,.chat-ev.mailbox-post{border-color:rgba(167,139,250,.3);color:var(--purple)}
.chat-ts{color:var(--text3);font-size:9px;margin-left:auto}
.chat-body{font-size:10px;color:var(--text2);line-height:1.5;word-break:break-word;max-height:100px;overflow-y:auto;padding:4px 8px;background:var(--bg3);border:1px solid var(--border);border-radius:3px}
@media(max-width:900px){.log-panel{display:none}.sb{width:200px}}
</style>
</head>
<body>

<!-- NAV -->
<nav>
  <a href="/" class="logo"><div class="dot"></div>OAH <span style="font-weight:400;color:var(--text3)">control</span></a>
  <div class="nav-r">
    <span id="wk-info" style="font-size:10px;color:var(--text3)">—</span>
    <button class="btn btn-secondary" style="padding:4px 12px;font-size:9px" onclick="openWkModal()">+ New Work Key</button>
    <div class="badge-conn" id="conn-badge"><div class="dot"></div><span id="conn-label">연결 중...</span></div>
  </div>
</nav>

<!-- WK MODAL (create) -->
<div class="modal-bg" id="wk-modal" style="display:none" onclick="if(event.target===this)closeWkModal()">
  <div class="modal">
    <div class="modal-h">
      <span class="modal-title" id="wk-modal-title">새 Work Key 생성</span>
      <button class="x-btn" onclick="closeWkModal()">✕</button>
    </div>
    <div class="modal-body">
      <div class="form-group">
        <label class="form-label">프로젝트 목표 (Goal)</label>
        <input class="form-input" id="wk-goal" placeholder="예) FastAPI 쇼핑몰 서버 — auth, cart, orders" autocomplete="off"/>
      </div>
      <div class="form-group">
        <label class="form-label">프로젝트 디렉토리 (PROJECT_DIR)</label>
        <input class="form-input" id="wk-dir" placeholder="/Volumes/nas/project4" autocomplete="off"/>
        <span class="form-hint">에이전트 join 시 자동으로 전달됨</span>
      </div>
      <div class="form-group">
        <label class="form-label">공유 컨텍스트 (JSON, 선택)</label>
        <input class="form-input" id="wk-ctx" placeholder='{"stack":"fastapi","python":"3.12"}' autocomplete="off"/>
      </div>
    </div>
    <div class="modal-foot">
      <button class="btn btn-ghost" onclick="closeWkModal()">취소</button>
      <button class="btn btn-primary" id="wk-modal-submit" onclick="createWorkKey()">생성</button>
    </div>
  </div>
</div>

<!-- TASK OUTPUT MODAL -->
<div class="modal-bg" id="out-modal" style="display:none" onclick="if(event.target===this)id('out-modal').style.display='none'">
  <div class="modal" style="width:680px">
    <div class="modal-h">
      <span class="modal-title" id="out-modal-title">태스크 출력</span>
      <button class="x-btn" onclick="id('out-modal').style.display='none'">✕</button>
    </div>
    <div style="padding:16px">
      <div class="output-box" id="out-modal-body" style="max-height:400px"></div>
    </div>
  </div>
</div>

<!-- APP -->
<div class="app">

  <!-- SIDEBAR -->
  <div class="sb">
    <!-- Work Keys -->
    <div class="sb-section wk-section">
      <div class="sb-h">
        <span class="sb-ht">Work Keys</span>
        <span class="badge" id="wk-count">0</span>
      </div>
      <div class="sb-list" id="wk-list"><div class="empty"><div class="empty-icon">🔑</div>없음</div></div>
    </div>
    <!-- Agents -->
    <div class="sb-section ag-section">
      <div class="sb-h">
        <span class="sb-ht">에이전트</span>
        <span class="badge" id="ag-count">0</span>
      </div>
      <div class="sb-list" id="ag-list"><div class="empty"><div class="empty-icon">🤖</div>없음</div></div>
    </div>
  </div>

  <!-- MAIN -->
  <div class="main">
    <!-- STATS BAR -->
    <div class="stats-bar">
      <div class="stat"><span class="stat-n g" id="s-agents">0</span><span class="stat-l">온라인</span></div>
      <div class="stat"><span class="stat-n c" id="s-wks">0</span><span class="stat-l">Work Keys</span></div>
      <div class="stat"><span class="stat-n o" id="s-tasks">0</span><span class="stat-l">완료 태스크</span></div>
      <div class="stat"><span class="stat-n p" id="s-active">0</span><span class="stat-l">진행 중</span></div>
    </div>

    <!-- CONTENT -->
    <div class="content">
      <div class="panels">
        <!-- TABS -->
        <div class="tabs">
          <div class="tab active" onclick="switchTab('dispatch')">Dispatch</div>
          <div class="tab" onclick="switchTab('tasks')">태스크 히스토리</div>
          <div class="tab" onclick="switchTab('state')">WK State 편집</div>
          <div class="tab" onclick="switchTab('agent')">에이전트 상세</div>
          <div class="tab" onclick="switchTab('files')">파일 변경</div>
          <div class="tab" onclick="switchTab('chat')">에이전트 대화</div>
        </div>

        <!-- TAB: DISPATCH -->
        <div class="tab-content active" id="tab-dispatch">
          <div class="card">
            <div class="card-h">
              <span class="card-ht">태스크 디스패치</span>
              <div style="display:flex;gap:6px">
                <button class="btn btn-secondary" style="padding:3px 10px;font-size:9px" onclick="selectAllBuilders()">전체 builder</button>
                <button class="btn btn-orange" style="padding:3px 10px;font-size:9px" onclick="broadcastAll()">전체 broadcast</button>
              </div>
            </div>
            <div class="card-body">
              <div class="dp-wk-row">
                <span class="dp-wk-label">Work Key</span>
                <select class="dp-wk-sel" id="dp-wk-sel" onchange="onWkSelChange()"></select>
              </div>
              <div>
                <div style="font-size:9px;color:var(--text3);letter-spacing:.5px;text-transform:uppercase;margin-bottom:5px">수신 에이전트</div>
                <div class="dp-agents" id="dp-agents"><span style="color:var(--text3);font-size:10px">에이전트 없음</span></div>
              </div>
              <div style="margin-top:10px">
                <div style="font-size:9px;color:var(--text3);letter-spacing:.5px;text-transform:uppercase;margin-bottom:5px">Instructions</div>
                <textarea class="dp-ta" id="dp-instr" placeholder="에이전트에게 내릴 작업 지시를 입력...&#10;예) src/cart.py 를 작성하라. FastAPI Router, JWT 인증 필요.&#10;완료 시 ARTIFACT: src/cart.py 출력."></textarea>
              </div>
              <div class="dp-actions">
                <button class="btn btn-primary" id="dp-send" onclick="dispatch()">▶ 전송</button>
                <button class="btn btn-ghost" onclick="clearDispatch()">지우기</button>
                <span class="dp-status" id="dp-status"></span>
              </div>
            </div>
          </div>

          <!-- Active project banner -->
          <div class="card" id="proj-card" style="display:none">
            <div class="card-h"><span class="card-ht">현재 프로젝트</span></div>
            <div class="card-body" style="display:grid;grid-template-columns:80px 1fr;gap:6px 12px;font-size:11px">
              <span style="color:var(--text3)">Goal</span><span id="proj-goal" style="color:var(--text)"></span>
              <span style="color:var(--text3)">Dir</span><span id="proj-dir" style="color:var(--cyan);word-break:break-all"></span>
              <span style="color:var(--text3)">Stack</span><span id="proj-ctx" style="color:var(--text2)"></span>
            </div>
          </div>
        </div>

        <!-- TAB: TASK HISTORY -->
        <div class="tab-content" id="tab-tasks">
          <div class="card">
            <div class="card-h">
              <span class="card-ht">태스크 히스토리</span>
              <button class="btn btn-ghost" style="padding:2px 8px;font-size:9px" onclick="clearTaskHistory()">초기화</button>
            </div>
            <div style="overflow-x:auto">
              <table class="task-table" id="task-table">
                <thead><tr>
                  <th>Task ID</th><th>대상 에이전트</th><th>Instructions</th>
                  <th>상태</th><th>소요 시간</th><th>Exit</th><th>출력</th>
                </tr></thead>
                <tbody id="task-tbody"><tr><td colspan="7" class="empty">태스크 없음</td></tr></tbody>
              </table>
            </div>
          </div>
        </div>

        <!-- TAB: WK STATE EDITOR -->
        <div class="tab-content" id="tab-state">
          <div class="card">
            <div class="card-h">
              <span class="card-ht">Work Key State 편집</span>
              <span id="state-wk-label" style="font-size:10px;color:var(--cyan)">—</span>
            </div>
            <div class="card-body">
              <div style="font-size:10px;color:var(--text3);margin-bottom:12px">사이드바에서 Work Key를 선택하면 편집할 수 있습니다.</div>
              <div class="state-form">
                <div class="sf-row">
                  <span class="sf-label">Goal</span>
                  <input class="sf-input" id="sf-goal" placeholder="프로젝트 목표"/>
                </div>
                <div class="sf-row">
                  <span class="sf-label">Project Dir</span>
                  <input class="sf-input" id="sf-dir" placeholder="/path/to/project"/>
                </div>
                <div class="sf-row">
                  <span class="sf-label">Status</span>
                  <div class="status-row">
                    <button class="status-btn created" onclick="setWkStatus('created')">created</button>
                    <button class="status-btn running" onclick="setWkStatus('running')">running</button>
                    <button class="status-btn done" onclick="setWkStatus('done')">done</button>
                    <button class="status-btn failed" onclick="setWkStatus('failed')">failed</button>
                  </div>
                </div>
                <div class="sf-row">
                  <span class="sf-label">Shared Context (JSON)</span>
                  <textarea class="sf-input sf-ta" id="sf-ctx" placeholder='{"stack":"fastapi","python":"3.12"}'></textarea>
                </div>
                <div class="sf-row">
                  <span class="sf-label">Raw State (읽기 전용)</span>
                  <div class="output-box" id="sf-raw" style="max-height:140px;font-size:9px"></div>
                </div>
              </div>
              <div style="display:flex;gap:8px;margin-top:14px;align-items:center">
                <button class="btn btn-primary" onclick="saveWkState()">💾 저장 (PATCH)</button>
                <button class="btn btn-ghost" onclick="loadWkState(selWk)">↺ 새로고침</button>
                <span id="state-status" style="font-size:10px;color:var(--text3)"></span>
              </div>
            </div>
          </div>
        </div>

        <!-- TAB: AGENT DETAIL -->
        <div class="tab-content" id="tab-agent">
          <div id="agent-detail-empty" class="card">
            <div class="card-body empty">
              <div class="empty-icon">🤖</div>사이드바에서 에이전트를 선택하세요
            </div>
          </div>
          <div id="agent-detail-card" class="card" style="display:none">
            <div class="card-h">
              <div style="display:flex;align-items:center;gap:8px">
                <div id="adet-dot" style="width:9px;height:9px;border-radius:50%"></div>
                <span class="card-ht" id="adet-name">—</span>
                <span id="adet-role-tag" class="role-tag">—</span>
              </div>
              <button class="btn btn-primary" style="padding:3px 10px;font-size:9px" onclick="dispatchToAgent()">▶ 이 에이전트에게 전송</button>
            </div>
            <div class="card-body">
              <!-- sub-tabs -->
              <div class="adt">
                <div class="adt-tab active" onclick="switchAgentTab('info')">정보</div>
                <div class="adt-tab" onclick="switchAgentTab('output')">실시간 출력</div>
                <div class="adt-tab" onclick="switchAgentTab('mailbox')">Mailbox</div>
              </div>
              <!-- info -->
              <div id="agt-info">
                <div class="adet-grid" id="adet-grid"></div>
              </div>
              <!-- live output -->
              <div id="agt-output" style="display:none">
                <div class="output-box" id="adet-live-out" style="max-height:240px">출력 없음</div>
              </div>
              <!-- mailbox -->
              <div id="agt-mailbox" style="display:none">
                <div style="display:flex;gap:8px;align-items:center;margin-bottom:10px">
                  <button class="btn btn-secondary" style="padding:4px 12px;font-size:9px" onclick="loadMailbox()">📬 Mailbox 읽기</button>
                  <span id="mb-count" style="font-size:10px;color:var(--text3)"></span>
                </div>
                <div id="mb-list"></div>
              </div>
            </div>
          </div>
        </div>

        <!-- TAB: FILE CHANGES -->
        <div class="tab-content" id="tab-files">
          <div class="card">
            <div class="card-h">
              <span class="card-ht">파일 변경 내역</span>
              <div style="display:flex;align-items:center;gap:8px">
                <span class="badge" id="fc-count">0</span>
                <button class="btn btn-ghost" style="padding:2px 8px;font-size:9px" onclick="fileChanges=[];renderFileChanges()">초기화</button>
              </div>
            </div>
            <div style="padding:12px" id="fc-list"><div class="empty"><div class="empty-icon">📁</div>파일 변경 없음<br/><span style="font-size:9px;color:var(--text3);margin-top:4px;display:block">에이전트가 task.result를 보낼 때 artifacts 필드가 있으면 여기에 표시됩니다</span></div></div>
          </div>
        </div>

        <!-- TAB: AGENT CHAT -->
        <div class="tab-content" id="tab-chat">
          <div class="card" style="flex:1;display:flex;flex-direction:column;overflow:hidden">
            <div class="card-h" style="flex-shrink:0">
              <span class="card-ht">에이전트 대화</span>
              <div style="display:flex;align-items:center;gap:8px">
                <span class="badge" id="chat-count">0</span>
                <button class="btn btn-ghost" style="padding:2px 8px;font-size:9px" onclick="chatLog=[];renderChatLog()">초기화</button>
              </div>
            </div>
            <div id="chat-list" style="overflow-y:auto;flex:1"><div class="empty"><div class="empty-icon">💬</div>대화 없음<br/><span style="font-size:9px;color:var(--text3);margin-top:4px;display:block">task.assign, mailbox.post/message 이벤트가 여기에 표시됩니다</span></div></div>
          </div>
        </div>

      </div><!-- /panels -->

      <!-- RIGHT: EVENT LOG -->
      <div class="log-panel">
        <div class="lp-h">
          <span class="lp-ht">이벤트 로그</span>
          <div class="lp-acts">
            <button class="lp-filter" id="log-filter-btn" style="display:none" onclick="clearLogFilter()">필터 해제</button>
            <span class="badge" id="log-count">0</span>
          </div>
        </div>
        <div style="padding:6px 12px;background:var(--bg3);border-bottom:1px solid var(--border);display:flex;gap:4px;flex-wrap:wrap" id="log-filter-bar" style="display:none">
        </div>
        <div class="log-list" id="log-list"><div class="empty"><div class="empty-icon">📋</div>대기 중...</div></div>
      </div>
    </div><!-- /content -->
  </div><!-- /main -->
</div><!-- /app -->

<script>
// ── State ───────────────────────────────────────────────────────────────────
let selWk=null, selAgent=null, activeWkStatus='created';
let allAgents=[], wkList=[], taskMap=new Map(), log=[], fileChanges=[], chatLog=[];
let agentState={}, taskOutput={};
let connected=false, wsRef=1, ws=null, wsHbTimer=null, wsJoinedTopics=new Set(), wsReconnectDelay=1000;
let dispatchTargets=new Set(), logFilter=null;
const POLL=5000;
let completedTasks=0, activeTasks=0;

const rc={orchestrator:'c',builder:'g',verifier:'p',reviewer:'p',integrator:'o'};
const dotCls={orchestrator:'c',builder:'g',verifier:'p',reviewer:'o',integrator:'o'};
const e=s=>String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
const id=s=>document.getElementById(s);
const fmt=iso=>iso?new Date(iso).toLocaleTimeString('ko',{hour:'2-digit',minute:'2-digit',second:'2-digit'}):'—';
const elapsed=iso=>{if(!iso)return'—';const s=Math.floor((Date.now()-new Date(iso))/1000);return s<60?s+'초':s<3600?Math.floor(s/60)+'분':Math.floor(s/3600)+'h '+Math.floor((s%3600)/60)+'m';};

// ── UI helpers ──────────────────────────────────────────────────────────────
function switchTab(name){
  document.querySelectorAll('.tab').forEach((t,i)=>{
    const names=['dispatch','tasks','state','agent','files','chat'];
    t.classList.toggle('active',names[i]===name);
  });
  document.querySelectorAll('.tab-content').forEach(c=>c.classList.remove('active'));
  id('tab-'+name)?.classList.add('active');
}

function switchAgentTab(name){
  document.querySelectorAll('.adt-tab').forEach((t,i)=>{
    t.classList.toggle('active',['info','output','mailbox'][i]===name);
  });
  id('agt-info').style.display=name==='info'?'':'none';
  id('agt-output').style.display=name==='output'?'':'none';
  id('agt-mailbox').style.display=name==='mailbox'?'':'none';
}

function setConn(on,label){
  const b=id('conn-badge');
  b.className='badge-conn '+(on?'on':'off');
  id('conn-label').textContent=label;
}

// ── Sidebar: Work Keys ──────────────────────────────────────────────────────
function renderWks(wks){
  id('wk-count').textContent=wks.length;
  id('s-wks').textContent=wks.length;
  const el=id('wk-list');
  if(!wks.length){el.innerHTML='<div class="empty"><div class="empty-icon">🔑</div>없음</div>';return;}
  if(!selWk&&wks.length)selWk=wks[wks.length-1];
  el.innerHTML=wks.slice().reverse().map(wk=>{
    const m=wkMeta[wk]||{};
    const goal=m.goal||'';
    const dir=m.project_dir||'';
    const status=m.status||'created';
    return`<div class="wki${wk===selWk?' sel':''}" onclick="pickWk('${e(wk)}')" data-wk="${e(wk)}">
      <div style="display:flex;align-items:center;justify-content:space-between;gap:4px">
        <span class="wki-key">${e(wk)}</span>
        <span class="wki-status ${status}">${status}</span>
        <button class="wki-edit" onclick="event.stopPropagation();editWk('${e(wk)}')" title="편집">✏️</button>
      </div>
      ${goal?`<div class="wki-goal">${e(goal)}</div>`:''}
      ${dir?`<div class="wki-dir">📁 ${e(dir)}</div>`:''}
    </div>`;
  }).join('');
  updateDpWkSelect(wks);
}

function pickWk(wk){
  selWk=wk;
  document.querySelectorAll('.wki').forEach(el=>el.classList.toggle('sel',el.dataset.wk===wk));
  id('dp-wk-sel').value=wk;
  loadWkState(wk);
  updateProjBanner(wk);
  id('wk-info').textContent=wk;
}

function updateDpWkSelect(wks){
  const sel=id('dp-wk-sel');
  const cur=sel.value||selWk;
  sel.innerHTML=wks.slice().reverse().map(wk=>`<option value="${e(wk)}"${wk===cur?' selected':''}>${e(wk)}</option>`).join('');
  if(!sel.value&&wks.length){sel.value=wks[wks.length-1];selWk=sel.value;}
}

function onWkSelChange(){
  selWk=id('dp-wk-sel').value;
  document.querySelectorAll('.wki').forEach(el=>el.classList.toggle('sel',el.dataset.wk===selWk));
  loadWkState(selWk);
  updateProjBanner(selWk);
  renderDispatchAgents(allAgents);
}

// ── Sidebar: Agents ─────────────────────────────────────────────────────────
function renderAgents(agents){
  id('ag-count').textContent=agents.length;
  id('s-agents').textContent=agents.length;
  const active=agents.filter(a=>agentState[a.name]?.status==='working').length;
  id('s-active').textContent=active;
  const el=id('ag-list');
  if(!agents.length){el.innerHTML='<div class="empty"><div class="empty-icon">🤖</div>없음</div>';return;}
  el.innerHTML=agents.map(a=>{
    const name=a.name||'?';
    const role=(a.role||'builder').toLowerCase();
    const dc=dotCls[role]||'g';
    const st=agentState[name]||{};
    const isBusy=st.status==='working';
    const isDone=st.status==='done';
    const taskLine=isBusy?`<div class="agi-task">⚡ ${e((st.instructions||'').slice(0,38)+'…')}</div>`
                  :isDone?`<div class="agi-task" style="color:var(--green)">✓ ${e((st.instructions||'').slice(0,35)+'…')}</div>`:'';
    return`<div class="agi slide-in${selAgent===name?' sel':''}" onclick="pickAgent('${e(name)}')" data-name="${e(name)}">
      <div class="agi-dot ${dc}"></div>
      <div class="agi-info">
        <div class="agi-name">${e(name)}</div>
        <div class="agi-sub">${e(a.machine||'')}</div>
        ${taskLine}
      </div>
      <span class="role-tag ${role}">${role}</span>
    </div>`;
  }).join('');
}

function pickAgent(name){
  selAgent=name;
  document.querySelectorAll('.agi').forEach(el=>el.classList.toggle('sel',el.dataset.name===name));
  refreshAgentDetail(name);
  switchTab('agent');
}

// ── Agent Detail ────────────────────────────────────────────────────────────
function refreshAgentDetail(name){
  const agent=allAgents.find(a=>a.name===name);
  if(!agent){id('agent-detail-card').style.display='none';id('agent-detail-empty').style.display='';return;}
  id('agent-detail-empty').style.display='none';
  id('agent-detail-card').style.display='';

  const role=(agent.role||'builder').toLowerCase();
  const dc=dotCls[role]||'g';
  const colorMap={g:'var(--green)',c:'var(--cyan)',o:'var(--orange)',p:'var(--purple)'};
  const color=colorMap[dc]||'var(--green)';
  const dotEl=id('adet-dot');
  dotEl.style.background=color;dotEl.style.boxShadow=`0 0 6px ${color}`;
  id('adet-name').textContent=name;
  id('adet-role-tag').textContent=role;
  id('adet-role-tag').className='role-tag '+role;

  const st=agentState[name]||{};
  const statusColor=st.status==='working'?'var(--orange)':st.status==='done'?'var(--green)':st.status==='blocked'?'var(--red)':'var(--text3)';
  const statusText=st.status==='working'?'⚡ 작업 중':st.status==='done'?'✓ 완료':st.status==='blocked'?'✗ 차단':'대기 중';

  const roleOptions=ALL_ROLES.map(r=>`<option value="${r}"${r===role?' selected':''}>${r}</option>`).join('');
  id('adet-grid').innerHTML=`
    <span class="adk">머신</span><span class="adv">${e(agent.machine||'—')}</span>
    <span class="adk">Work Key</span><span class="adv c">${e(agent.work_key||'—')}</span>
    <span class="adk">온라인</span><span class="adv">${elapsed(agent.online_since)}</span>
    <span class="adk">상태</span><span class="adv" style="color:${statusColor}">${statusText}</span>
    <span class="adk">Role</span><span class="adv" style="display:flex;gap:6px;align-items:center">
      <select id="role-sel-${e(name)}" style="background:var(--bg3);color:var(--text);border:1px solid var(--border2);border-radius:3px;padding:2px 6px;font-family:inherit;font-size:11px;cursor:pointer">${roleOptions}</select>
      <button onclick="setAgentRole('${e(name)}',document.getElementById('role-sel-${e(name)}').value)" style="background:var(--cyan);color:#000;border:none;border-radius:3px;padding:2px 8px;font-family:inherit;font-size:11px;font-weight:700;cursor:pointer">변경</button>
    </span>
    ${st.task_id?`<span class="adk">Task ID</span><span class="adv" style="font-size:10px">${e(st.task_id)}</span>`:''}
    ${st.started?`<span class="adk">시작</span><span class="adv">${fmt(st.started)}</span>`:''}
    ${st.completed?`<span class="adk">완료</span><span class="adv g">${fmt(st.completed)}</span>`:''}
    ${st.exit_code!=null?`<span class="adk">Exit</span><span class="adv ${st.exit_code===0?'g':'o'}">exit ${st.exit_code}</span>`:''}
    ${st.instructions?`<span class="adk">태스크</span><div class="adv" style="background:var(--bg3);border:1px solid var(--border);border-radius:3px;padding:7px 10px;font-size:10px;line-height:1.5;margin-top:2px;word-break:break-word;max-height:100px;overflow-y:auto">${e(st.instructions)}</div>`:''}
  `;

  // live output
  const out=taskOutput[name]||'';
  const outEl=id('adet-live-out');
  if(outEl)outEl.textContent=out||'(출력 없음)';
}

function dispatchToAgent(){
  if(selAgent){
    dispatchTargets.clear();
    dispatchTargets.add(selAgent);
    renderDispatchAgents(allAgents);
    switchTab('dispatch');
    id('dp-instr')?.focus();
  }
}

// ── Role Change ──────────────────────────────────────────────────────────────
const ALL_ROLES=['orchestrator','planner','builder','verifier','reviewer','code-expert','mfg-expert','curriculum-expert','visual-feedback','executor','learner-simulator'];

function setAgentRole(agentName, newRole){
  if(!agentName||!newRole)return;
  if(!ws||ws.readyState!==WebSocket.OPEN){alert('채널 미연결');return;}
  const topic=`work:${selWk}`;
  const msg=[null,String(++_ref),topic,'agent.setRole',{to:agentName,role:newRole}];
  ws.send(JSON.stringify(msg));
  // Optimistically update local state
  const agent=allAgents.find(a=>a.name===agentName);
  if(agent){
    agent.role=newRole;
    agent.name=`${newRole}@${(agentName.split('@')[1]||agentName)}`;
    renderAgents(allAgents);
  }
  console.log(`[dashboard] setRole → ${agentName} = ${newRole}`);
}

// ── Mailbox ─────────────────────────────────────────────────────────────────
async function loadMailbox(){
  if(!selAgent)return;
  const res=await fetch(`/api/mailbox/${encodeURIComponent(selAgent)}`).catch(()=>null);
  if(!res||!res.ok){id('mb-count').textContent='읽기 실패';return;}
  const d=await res.json();
  const msgs=d.messages||[];
  id('mb-count').textContent=`${msgs.length}개 메시지`;
  const el=id('mb-list');
  if(!msgs.length){el.innerHTML='<div class="empty">메시지 없음</div>';return;}
  el.innerHTML=msgs.map(m=>{
    const from=m.from||m.agent||'?';
    const body=typeof m==='string'?m:JSON.stringify(m,null,2);
    return`<div class="mb-item"><div class="mb-from">${e(from)} · ${fmt(m.ts)}</div><div class="mb-body">${e(body.slice(0,400))}</div></div>`;
  }).join('');
}

// ── WK State ────────────────────────────────────────────────────────────────
let wkMeta={};

async function loadWkState(wk){
  if(!wk)return;
  try{
    const res=await fetch(`/api/state/${encodeURIComponent(wk)}`,{signal:AbortSignal.timeout(3000)});
    if(!res.ok)return;
    const s=await res.json();
    wkMeta[wk]={goal:s.goal||null,project_dir:s.project_dir||null,status:s.status||'created',shared_context:s.shared_context||{}};

    // State editor
    id('state-wk-label').textContent=wk;
    id('sf-goal').value=s.goal||'';
    id('sf-dir').value=s.project_dir||'';
    id('sf-ctx').value=s.shared_context?JSON.stringify(s.shared_context,null,2):'';
    activeWkStatus=s.status||'created';
    document.querySelectorAll('.status-btn').forEach(b=>{
      b.classList.toggle('active',b.classList.contains(activeWkStatus));
    });
    const raw=id('sf-raw');
    if(raw)raw.textContent=JSON.stringify(s,null,2);

    // Project banner
    updateProjBanner(wk);
    // Refresh WK list meta display
    renderWks(wkList);
  }catch{}
}

function setWkStatus(status){
  activeWkStatus=status;
  document.querySelectorAll('.status-btn').forEach(b=>{
    b.classList.toggle('active',b.classList.contains(status));
  });
}

async function saveWkState(){
  if(!selWk){id('state-status').textContent='WK를 선택하세요';return;}
  const goal=id('sf-goal').value.trim()||null;
  const project_dir=id('sf-dir').value.trim()||null;
  const ctxRaw=id('sf-ctx').value.trim();
  let shared_context={};
  if(ctxRaw){try{shared_context=JSON.parse(ctxRaw);}catch{id('state-status').textContent='JSON 형식 오류';id('state-status').style.color='var(--red)';return;}}
  try{
    const res=await fetch(`/api/state/${encodeURIComponent(selWk)}`,{
      method:'PATCH',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({goal,project_dir,status:activeWkStatus,shared_context})
    });
    if(res.ok){
      id('state-status').textContent='✓ 저장됨';id('state-status').style.color='var(--green)';
      setTimeout(()=>{id('state-status').textContent='';},3000);
      wkMeta[selWk]={goal,project_dir,status:activeWkStatus,shared_context};
      updateProjBanner(selWk);
      loadWkState(selWk);
    }
  }catch{id('state-status').textContent='저장 실패';id('state-status').style.color='var(--red)';}
}

function updateProjBanner(wk){
  const m=wkMeta[wk]||{};
  const c=id('proj-card');
  if(!c)return;
  if(m.goal||m.project_dir){
    c.style.display='';
    id('proj-goal').textContent=m.goal||'—';
    id('proj-dir').textContent=m.project_dir||'—';
  } else {
    c.style.display='none';
  }
}

// ── Work Key modal ──────────────────────────────────────────────────────────
let editingWk=null;
function openWkModal(mode){editingWk=null;id('wk-modal-title').textContent='새 Work Key 생성';id('wk-modal-submit').textContent='생성';id('wk-goal').value='';id('wk-dir').value='';id('wk-ctx').value='';id('wk-modal').style.display='flex';id('wk-goal').focus();}
function closeWkModal(){id('wk-modal').style.display='none';}
async function editWk(wk){
  editingWk=wk;
  id('wk-modal-title').textContent='Work Key 편집: '+wk;
  id('wk-modal-submit').textContent='저장';
  id('wk-modal').style.display='flex';
  // Fetch fresh state if not cached
  if(!wkMeta[wk]?.goal&&!wkMeta[wk]?.project_dir){
    try{
      const r=await fetch(`/api/state/${encodeURIComponent(wk)}`);
      if(r.ok){const s=await r.json();wkMeta[wk]={goal:s.goal||null,project_dir:s.project_dir||null,status:s.status||'created',shared_context:s.shared_context||{}};}
    }catch{}
  }
  const m=wkMeta[wk]||{};
  id('wk-goal').value=m.goal||'';
  id('wk-dir').value=m.project_dir||'';
  id('wk-ctx').value=m.shared_context&&Object.keys(m.shared_context).length?JSON.stringify(m.shared_context):'';
  id('wk-goal').focus();
}
async function createWorkKey(){
  const goal=id('wk-goal').value.trim()||null;
  const project_dir=id('wk-dir').value.trim()||null;
  const ctxRaw=id('wk-ctx').value.trim();
  let context={};
  if(ctxRaw){try{context=JSON.parse(ctxRaw);}catch{alert('컨텍스트 JSON 형식 오류');return;}}

  if(editingWk){
    // Edit mode: PATCH existing WK
    await fetch(`/api/state/${encodeURIComponent(editingWk)}`,{
      method:'PATCH',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({goal,project_dir,shared_context:context})
    });
    wkMeta[editingWk]={goal,project_dir,shared_context:context};
    addLog('system',`WK 편집: ${editingWk}`,null);
    closeWkModal();loadWkState(editingWk);poll();return;
  }

  try{
    const res=await fetch('/api/work-keys',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({goal,project_dir,context})});
    const d=await res.json();
    selWk=d.work_key;
    closeWkModal();
    addLog('system',`Work Key 생성: ${d.work_key}${goal?' — '+goal:''}`);
    wsJoinNewWorkKey(d.work_key);
    poll();
  }catch{addLog('system','Work Key 생성 실패');}
}

// ── Dispatch ────────────────────────────────────────────────────────────────
function renderDispatchAgents(agents){
  const wk=id('dp-wk-sel')?.value||selWk;
  // Show all agents or filter by selected WK
  const visible=agents;
  const el=id('dp-agents');
  if(!visible.length){el.innerHTML='<span style="color:var(--text3);font-size:10px">에이전트 없음</span>';return;}
  el.innerHTML=visible.map(a=>{
    const name=a.name||'?';
    const role=(a.role||'builder').toLowerCase();
    const isSel=dispatchTargets.has(name);
    return`<div class="chip${isSel?' sel':''}" onclick="toggleTarget('${e(name)}')" data-dn="${e(name)}">
      <div class="cd"></div>${e(name)} <span class="role-tag ${role}" style="margin-left:2px">${role}</span>
    </div>`;
  }).join('');
}

function toggleTarget(name){
  if(dispatchTargets.has(name))dispatchTargets.delete(name);
  else dispatchTargets.add(name);
  document.querySelectorAll('[data-dn]').forEach(el=>{
    const sel=dispatchTargets.has(el.dataset.dn);
    el.classList.toggle('sel',sel);
    el.querySelector('.cd').style.background=sel?'var(--cyan)':'var(--border2)';
  });
}

function selectAllBuilders(){
  dispatchTargets.clear();
  allAgents.filter(a=>(a.role||'').toLowerCase()==='builder').forEach(a=>dispatchTargets.add(a.name));
  renderDispatchAgents(allAgents);
}

function broadcastAll(){
  dispatchTargets.clear();
  allAgents.forEach(a=>dispatchTargets.add(a.name));
  renderDispatchAgents(allAgents);
}

async function dispatch(){
  const instr=id('dp-instr').value.trim();
  if(!instr){showDpStatus('Instructions를 입력하세요','err');return;}
  if(!dispatchTargets.size){showDpStatus('에이전트를 선택하세요','err');return;}
  const wk=id('dp-wk-sel')?.value||selWk;
  const btn=id('dp-send');btn.disabled=true;
  showDpStatus('전송 중...','');
  const targets=[...dispatchTargets];
  let ok=0,fail=0;
  await Promise.all(targets.map(async to=>{
    const agent=allAgents.find(a=>a.name===to);
    const role=(agent?.role||'builder').toLowerCase();
    try{
      const res=await fetch('/api/task',{method:'POST',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({work_key:wk,to,role,instructions:instr})});
      if(res.ok)ok++;else fail++;
    }catch{fail++;}
  }));
  btn.disabled=false;
  showDpStatus(fail===0?`✓ ${ok}개 전송 완료`:`${ok}개 성공, ${fail}개 실패`,fail===0?'ok':'err');
  if(fail===0)setTimeout(()=>showDpStatus('',''),4000);
}

function showDpStatus(msg,cls){const el=id('dp-status');el.textContent=msg;el.className='dp-status'+(cls?' '+cls:'');}

function clearDispatch(){
  id('dp-instr').value='';
  dispatchTargets.clear();
  renderDispatchAgents(allAgents);
  showDpStatus('','');
}

// ── Task History ────────────────────────────────────────────────────────────
function updateTaskTable(){
  const tasks=[...taskMap.values()].sort((a,b)=>new Date(b.started||0)-new Date(a.started||0));
  completedTasks=tasks.filter(t=>t.status==='done'||t.status==='error'||t.status==='blocked').length;
  activeTasks=tasks.filter(t=>t.status==='working').length;
  id('s-tasks').textContent=completedTasks;
  id('s-active').textContent=activeTasks;
  const tbody=id('task-tbody');
  if(!tasks.length){tbody.innerHTML='<tr><td colspan="7" class="empty">태스크 없음</td></tr>';return;}
  tbody.innerHTML=tasks.slice(0,50).map(t=>{
    const dur=t.started&&t.completed?Math.round((new Date(t.completed)-new Date(t.started))/1000)+'s':'—';
    const exitHtml=t.exit_code!=null?`<span class="ts-exit ${t.exit_code===0?'ok':'err'}">exit ${t.exit_code}</span>`:'—';
    const outBtn=t.output?`<button onclick="showOutput('${e(t.task_id)}')" class="btn btn-ghost" style="padding:2px 7px;font-size:9px">보기</button>`:'—';
    return`<tr>
      <td class="ts-id" title="${e(t.task_id)}">${e(t.task_id.slice(0,16))}</td>
      <td class="ts-to">${e(t.to||'?')}</td>
      <td class="ts-instr" title="${e(t.instructions||'')}">${e((t.instructions||'').slice(0,50))}</td>
      <td><span class="ts-st ${t.status||'pending'}">${t.status||'—'}</span></td>
      <td class="ts-dur">${dur}</td>
      <td>${exitHtml}</td>
      <td>${outBtn}</td>
    </tr>`;
  }).join('');
}

function showOutput(taskId){
  const t=taskMap.get(taskId);
  if(!t||!t.output)return;
  id('out-modal-title').textContent=`출력: ${taskId}`;
  id('out-modal-body').textContent=t.output;
  id('out-modal').style.display='flex';
}

function clearTaskHistory(){taskMap.clear();updateTaskTable();}

// ── File Changes ─────────────────────────────────────────────────────────────
function addFileChange(agent,taskId,files,ts){
  // Dedupe: merge files if same agent+taskId exists within last 2 seconds
  const recent=fileChanges.find(fc=>fc.agent===agent&&fc.task_id===taskId&&(Date.now()-new Date(fc.ts))<2000);
  if(recent){
    files.forEach(f=>{if(!recent.files.includes(f))recent.files.push(f);});
    renderFileChanges();return;
  }
  fileChanges.unshift({agent,task_id:taskId,files:Array.isArray(files)?[...files]:[files],ts});
  if(fileChanges.length>300)fileChanges.pop();
  renderFileChanges();
}
function renderFileChanges(){
  const el=id('fc-list');if(!el)return;
  id('fc-count').textContent=fileChanges.length;
  if(!fileChanges.length){
    el.innerHTML='<div class="empty"><div class="empty-icon">📁</div>파일 변경 없음<br/><span style="font-size:9px;color:var(--text3);margin-top:4px;display:block">에이전트가 task.result를 보낼 때 artifacts 필드가 있으면 여기에 표시됩니다</span></div>';
    return;
  }
  el.innerHTML=fileChanges.slice(0,100).map(fc=>`
    <div class="fc-item slide-in">
      <div class="fc-meta">
        <span class="fc-agent">${e(fc.agent)}</span>
        <span class="fc-taskid" title="${e(fc.task_id||'')}">${e((fc.task_id||'').slice(0,20))}</span>
        <span class="fc-ts">${fmt(fc.ts)}</span>
      </div>
      <div class="fc-files">${(fc.files||[]).map(f=>`<span class="fc-file">${e(f)}</span>`).join('')}</div>
    </div>
  `).join('');
}

// ── Agent Chat Log ────────────────────────────────────────────────────────────
function addChatMsg(from,to,ev,body,ts){
  chatLog.unshift({from,to,ev,body,ts});
  if(chatLog.length>500)chatLog.pop();
  renderChatLog();
}
function renderChatLog(){
  const el=id('chat-list');if(!el)return;
  id('chat-count').textContent=chatLog.length;
  if(!chatLog.length){
    el.innerHTML='<div class="empty"><div class="empty-icon">💬</div>대화 없음<br/><span style="font-size:9px;color:var(--text3);margin-top:4px;display:block">task.assign, mailbox.post/message 이벤트가 여기에 표시됩니다</span></div>';
    return;
  }
  const evClass=ev=>ev.replace(/\./g,'-');
  el.innerHTML=chatLog.slice(0,200).map(c=>`
    <div class="chat-item slide-in">
      <div class="chat-header">
        <span class="chat-from">${e(c.from||'?')}</span>
        <span class="chat-arrow">→</span>
        <span class="chat-to">${e(c.to||'broadcast')}</span>
        <span class="chat-ev ${evClass(c.ev||'')}">${e(c.ev||'?')}</span>
        <span class="chat-ts">${fmt(c.ts)}</span>
      </div>
      <div class="chat-body">${e((c.body||'').slice(0,400))}</div>
    </div>
  `).join('');
}

// ── Event Log ────────────────────────────────────────────────────────────────
function addLog(ev,msg,agentName){
  const t=new Date().toLocaleTimeString('ko',{hour:'2-digit',minute:'2-digit',second:'2-digit'});
  const entry={t,ev,msg,agent:agentName||null};
  log.unshift(entry);if(log.length>500)log.pop();

  const el=id('log-list');
  const empty=el.querySelector('.empty');if(empty)empty.remove();

  if(!logFilter||entry.agent===logFilter||msg.includes(logFilter)){
    const cls=ev.replace(/\./g,'-').replace(/_/g,'-');
    const d=document.createElement('div');
    d.className='log-item slide-in';
    d.innerHTML=`<span class="log-t">${t}</span><div class="log-body"><span class="log-ev ${cls}">${e(ev)}</span><span class="log-msg">${e(msg)}</span></div>`;
    el.prepend(d);
    if(el.children.length>200)el.lastElementChild?.remove();
  }
  const cnt=logFilter?log.filter(l=>l.agent===logFilter||l.msg.includes(logFilter)).length:log.length;
  id('log-count').textContent=cnt+(logFilter?'/'+log.length:'');
  if(selAgent&&(agentName===selAgent||msg.includes(selAgent)))refreshAgentDetail(selAgent);
}

function setLogFilter(name){
  logFilter=name;
  id('log-filter-btn').style.display='';
  id('log-filter-bar').innerHTML=`<span style="font-size:9px;color:var(--orange)">필터: ${e(name)}</span>`;
}
function clearLogFilter(){logFilter=null;id('log-filter-btn').style.display='none';id('log-filter-bar').innerHTML='';}

// ── Poll ────────────────────────────────────────────────────────────────────
async function poll(){
  try{
    const [pr,wr]=await Promise.all([
      fetch('/api/presence',{signal:AbortSignal.timeout(4000)}),
      fetch('/api/work-keys',{signal:AbortSignal.timeout(4000)})
    ]);
    if(!pr.ok||!wr.ok)throw new Error();
    const p=await pr.json(),w=await wr.json();
    if(!connected){connected=true;setConn(true,'연결됨');addLog('system','서버 연결');}
    allAgents=(p.agents||[]).filter(a=>(a.role||'').toLowerCase()!=='observer');
    wkList=w.work_keys||[];
    renderAgents(allAgents);
    renderDispatchAgents(allAgents);
    renderWks(wkList);
    if(selWk)loadWkState(selWk);
    if(selAgent)refreshAgentDetail(selAgent);
  }catch{
    if(connected){connected=false;setConn(false,'연결 끊김');addLog('system','연결 끊김');}
    allAgents=[];renderAgents([]);renderDispatchAgents([]);
  }
}

// ── WebSocket ────────────────────────────────────────────────────────────────
let wsJoinRef=null;
function wsSend(arr){try{if(ws?.readyState===1)ws.send(JSON.stringify(arr));}catch{}}
function wsJoinTopic(topic){
  if(wsJoinedTopics.has(topic))return;
  wsJoinedTopics.add(topic);
  const jref=String(wsRef++);
  wsJoinRef=jref;
  wsSend([jref,jref,topic,'phx_join',{role:'observer',agent_name:'dashboard@browser'}]);
}
function wsJoinNewWorkKey(wk){wsJoinTopic('work:'+wk);}

function connectWs(){
  const proto=location.protocol==='https:'?'wss':'ws';
  ws=new WebSocket(`${proto}://${location.host}/socket/websocket?vsn=2.0.0&agent_name=dashboard@browser&role=observer`);
  ws.onopen=()=>{
    wsReconnectDelay=1000;wsJoinedTopics.clear();
    if(wsHbTimer)clearInterval(wsHbTimer);
    wsHbTimer=setInterval(()=>wsSend([null,String(wsRef++),'phoenix','heartbeat',{}]),30000);
    fetch('/api/work-keys').then(r=>r.json()).then(d=>{(d.work_keys||[]).forEach(wk=>wsJoinTopic('work:'+wk));}).catch(()=>{});
  };
  ws.onmessage=evt=>{
    try{
      const [,,topic,ev,payload]=JSON.parse(evt.data);
      if(ev==='phx_reply'){if(payload?.status==='ok'&&topic.startsWith('work:')){}return;}
      if(['phx_error','phx_close','presence_state','presence_diff'].includes(ev)||topic==='phoenix')return;
      const from=payload?.from||payload?.agent||null;
      const taskId=payload?.task_id||'';
      let msg='';

      if(ev==='task.assign'){
        const to=payload?.to||'broadcast';
        const instr=(payload?.instructions||'').slice(0,80);
        msg=`→ ${to}: ${instr}`;
        // log to agent chat
        addChatMsg(from||payload?.from||'http@controller',to,'task.assign',payload?.instructions||'',payload?.ts||new Date().toISOString());
        if(to){
          agentState[to]=agentState[to]||{};
          Object.assign(agentState[to],{task_id:taskId,instructions:payload?.instructions||'',status:'working',started:new Date().toISOString(),completed:null,exit_code:null});
          taskOutput[to]='';
          // Add to task history
          taskMap.set(taskId,{task_id:taskId,to,instructions:payload?.instructions||'',status:'working',started:new Date().toISOString(),output:null,exit_code:null});
          renderAgents(allAgents);updateTaskTable();
        }
      } else if(ev==='task.result'){
        const agentFrom=payload?.from||'?';
        const exitCode=payload?.exit_code??'?';
        msg=`${agentFrom}: exit=${exitCode} — ${taskId}`;
        // Extract file artifacts
        const arts=payload?.artifacts;
        if(arts&&arts.length>0){addFileChange(agentFrom,taskId,arts,payload?.ts||new Date().toISOString());}
        if(agentFrom&&agentState[agentFrom]){
          Object.assign(agentState[agentFrom],{status:exitCode===0||exitCode==='0'?'done':'error',exit_code:exitCode,completed:new Date().toISOString()});
          taskOutput[agentFrom]='';
          renderAgents(allAgents);
        }
        if(taskMap.has(taskId)){
          const t=taskMap.get(taskId);
          Object.assign(t,{status:exitCode===0||exitCode==='0'?'done':'error',exit_code:exitCode,completed:new Date().toISOString(),output:payload?.output||null});
          updateTaskTable();
        }
      } else if(ev==='task.progress'){
        const tail=payload?.output_tail||'';
        if(tail&&from){
          taskOutput[from]=tail;
          const outEl=id('adet-live-out');
          if(outEl&&selAgent===from){outEl.textContent=tail;outEl.scrollTop=outEl.scrollHeight;}
          // Parse ARTIFACT: lines from output_tail
          const artLines=tail.split('\n').filter(l=>/^ARTIFACT:\s+\S/.test(l.trim()));
          if(artLines.length){
            const files=artLines.map(l=>l.replace(/^ARTIFACT:\s+/,'').trim());
            addFileChange(from,taskId||payload?.task_id||'?',files,payload?.ts||new Date().toISOString());
          }
        }
        msg=`${from||'?'}: ${payload?.message||'working...'}`;
      } else if(ev==='mailbox.message'||ev==='mailbox.post'){
        const mfrom=payload?.from||'?';
        const mto=payload?.to||'—';
        const content=payload?.content||payload?.message||payload?.instructions||payload?.text||JSON.stringify(payload).slice(0,200);
        msg=`${mfrom} → ${mto}: ${String(content).slice(0,60)}`;
        addChatMsg(mfrom,mto,ev,String(content),payload?.ts||new Date().toISOString());
      } else if(ev==='task.blocked'){
        const agentFrom=payload?.from||'?';
        msg=`${agentFrom}: ${payload?.error||payload?.reason||taskId}`;
        if(agentFrom&&agentState[agentFrom]){agentState[agentFrom].status='blocked';renderAgents(allAgents);}
        if(taskMap.has(taskId)){const t=taskMap.get(taskId);Object.assign(t,{status:'blocked',completed:new Date().toISOString()});updateTaskTable();}
      } else if(ev==='agent.hello'){
        const a=payload?.agent||'?';
        msg=`${a} (${payload?.role||'?'}) @ ${payload?.machine||'?'}`;
        if(!allAgents.find(x=>x.name===a)){
          allAgents=[...allAgents,{name:a,role:payload?.role||'builder',machine:payload?.machine||'',work_key:payload?.work_key||selWk||'',online_since:new Date().toISOString()}];
          renderAgents(allAgents);renderDispatchAgents(allAgents);
        }
      } else if(ev==='agent.bye'){
        const a=payload?.agent||'?';
        msg=`${a} 퇴장`;
        allAgents=allAgents.filter(x=>x.name!==a);
        if(selAgent===a){selAgent=null;id('agent-detail-card').style.display='none';id('agent-detail-empty').style.display='';}
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
    setTimeout(connectWs,wsReconnectDelay);
    wsReconnectDelay=Math.min(wsReconnectDelay*2,30000);
  };
  ws.onerror=()=>ws?.close();
}

poll();
setInterval(poll,POLL);
connectWs();
</script>
</body>
</html>

"""
  end
end
