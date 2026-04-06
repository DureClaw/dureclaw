defmodule HarnessServer.WorkChannel do
  @moduledoc """
  Phoenix Channel for a single Work Key session.

  Topic format: "work:LN-YYYYMMDD-XXX"

  ## Events (client → server)

    * "agent.hello"    — register presence (also sent in phx_join payload)
    * "task.assign"    — orchestrator assigns task to a specific agent
    * "task.progress"  — builder streams progress updates
    * "task.blocked"   — agent cannot proceed
    * "task.result"    — task completed
    * "task.approval_requested" — human-in-the-loop gate
    * "state.update"   — update key/value pairs for this work key
    * "state.get"      — fetch current state
    * "mailbox.post"   — send a message; queued if agent is offline
    * "mailbox.read"   — read queued messages for self

  ## Events (server → client)

    * "agent.hello"     — another agent joined
    * "agent.bye"       — agent left
    * "mailbox.message" — queued message delivered
  """

  use Phoenix.Channel
  alias HarnessServer.{Presence, StateStore}

  # ─── Join ──────────────────────────────────────────────────────────────────

  @impl true
  def join("work:" <> work_key, payload, socket) do
    # Only register real work keys (LN-YYYYMMDD-XXX pattern), not internal topics
    if String.starts_with?(work_key, "LN-") do
      StateStore.ensure_work_key(work_key)
    end

    agent_name = Map.get(payload, "agent_name", socket.assigns.agent_name)
    role = Map.get(payload, "role", socket.assigns.role)
    machine = Map.get(payload, "machine", socket.assigns.machine)

    socket =
      socket
      |> assign(:work_key, work_key)
      |> assign(:agent_name, agent_name)
      |> assign(:role, role)
      |> assign(:machine, machine)

    capabilities = Map.get(payload, "capabilities", [])
    socket = assign(socket, :capabilities, capabilities)

    {:ok, _} =
      Presence.track(socket, agent_name, %{
        role: role,
        machine: machine,
        work_key: work_key,
        capabilities: capabilities,
        online_since: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    # broadcast_from! / push cannot be called inside join/3 in Phoenix 1.7+
    send(self(), :after_join)

    presences = Presence.list(socket)
    project = StateStore.get(work_key)

    {:ok, %{presences: presences, work_key: work_key, project: project}, socket}
  end

  # ─── After join: announce presence + deliver offline mailbox ───────────────

  @impl true
  def handle_info(:after_join, socket) do
    broadcast_from!(socket, "agent.hello", %{
      agent: socket.assigns.agent_name,
      role: socket.assigns.role,
      machine: socket.assigns.machine,
      work_key: socket.assigns.work_key
    })

    msgs = StateStore.pop_mailbox(socket.assigns.agent_name)
    for msg <- msgs, do: push(socket, "mailbox.message", msg)

    {:noreply, socket}
  end

  # ─── Task events — broadcast to all channel members ────────────────────────
  #
  # Routing by "to" field is done CLIENT-SIDE: every agent receives the
  # broadcast and filters by payload["to"] == own agent_name.
  # Offline delivery: use "mailbox.post" explicitly.

  @impl true
  def handle_in(event, payload, socket)
      when event in ["task.result", "task.blocked"] do
    msg =
      payload
      |> Map.put("from", socket.assigns.agent_name)
      |> Map.put("event", event)
      |> Map.put("ts", DateTime.utc_now() |> DateTime.to_iso8601())

    if task_id = Map.get(payload, "task_id") do
      StateStore.store_task_result(task_id, msg)
      maybe_dispatch_unblocked(event, task_id, socket.assigns.work_key)
    end

    broadcast!(socket, event, msg)
    {:reply, {:ok, %{broadcast: true}}, socket}
  end

  defp maybe_dispatch_unblocked("task.result", task_id, default_wk) do
    for task_payload <- StateStore.complete_dependency(task_id) do
      wk = Map.get(task_payload, "work_key", default_wk)
      HarnessServer.Endpoint.broadcast("work:#{wk}", "task.assign", task_payload)
    end
  end

  defp maybe_dispatch_unblocked(_event, _task_id, _wk), do: :ok

  @impl true
  def handle_in(event, payload, socket)
      when event in [
             "task.assign",
             "task.progress",
             "task.approval_requested"
           ] do
    msg =
      payload
      |> Map.put("from", socket.assigns.agent_name)
      |> Map.put("event", event)
      |> Map.put("ts", DateTime.utc_now() |> DateTime.to_iso8601())

    broadcast!(socket, event, msg)
    {:reply, {:ok, %{broadcast: true}}, socket}
  end

  # ─── State ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_in("state.update", payload, socket) do
    work_key = socket.assigns.work_key
    state = StateStore.update(work_key, payload)
    {:reply, {:ok, %{state: state}}, socket}
  end

  @impl true
  def handle_in("state.get", _payload, socket) do
    state = StateStore.get(socket.assigns.work_key)
    {:reply, {:ok, %{state: state}}, socket}
  end

  # ─── Mailbox ───────────────────────────────────────────────────────────────

  @impl true
  def handle_in("mailbox.post", %{"to" => to} = payload, socket) do
    msg =
      payload
      |> Map.put("from", socket.assigns.agent_name)
      |> Map.put("ts", DateTime.utc_now() |> DateTime.to_iso8601())

    presences = Presence.list(socket)

    if Map.has_key?(presences, to) do
      # Agent is online — deliver via channel broadcast
      broadcast!(socket, "mailbox.message", msg)
      {:reply, {:ok, %{delivered: true}}, socket}
    else
      # Agent offline — queue for later delivery
      StateStore.enqueue_mailbox(to, msg)
      {:reply, {:ok, %{delivered: false, queued: true}}, socket}
    end
  end

  @impl true
  def handle_in("mailbox.read", _payload, socket) do
    msgs = StateStore.pop_mailbox(socket.assigns.agent_name)
    {:reply, {:ok, %{messages: msgs, count: length(msgs)}}, socket}
  end

  # ─── Agent events ──────────────────────────────────────────────────────────

  @impl true
  def handle_in("agent.hello", payload, socket) do
    broadcast_from!(socket, "agent.hello", %{
      agent: Map.get(payload, "agent_name", socket.assigns.agent_name),
      role: Map.get(payload, "role", socket.assigns.role),
      machine: socket.assigns.machine,
      work_key: socket.assigns.work_key
    })

    {:reply, :ok, socket}
  end

  # ─── Catch-all ─────────────────────────────────────────────────────────────

  @impl true
  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "unknown_event"}}, socket}
  end

  # ─── Terminate ─────────────────────────────────────────────────────────────

  @impl true
  def terminate(_reason, socket) do
    if name = socket.assigns[:agent_name] do
      broadcast_from!(socket, "agent.bye", %{
        agent: name,
        role: socket.assigns[:role],
        work_key: socket.assigns[:work_key]
      })
    end

    :ok
  end
end
