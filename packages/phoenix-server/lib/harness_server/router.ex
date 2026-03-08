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
end
