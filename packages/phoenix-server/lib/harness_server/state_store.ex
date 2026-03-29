defmodule HarnessServer.StateStore do
  @moduledoc """
  Persistent state store for Work Key state and agent mailboxes.

  Tables:
    :harness_state   — {work_key, state_map}  → DETS (disk, survives restarts)
    :harness_mailbox — {agent_name, [msgs]}   → DETS (disk, survives restarts)
    :harness_tasks   — {task_id, [results]}   → DETS (disk, survives restarts)

  Work Key state shape:
    %{
      work_key: "LN-20260308-001",
      status: "created" | "running" | "done" | "failed",
      goal: nil | string,
      project_dir: nil | string,
      shared_context: %{},
      loop_count: 0,
      tasks: [],
      created_at: iso8601,
      updated_at: iso8601
    }

  Data directory: $OAH_DATA_DIR (default: "data/")
  """

  use GenServer

  @state_table   :harness_state
  @mailbox_table :harness_mailbox
  @task_table    :harness_tasks
  @pending_table :harness_pending

  # ─── Public API ─────────────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Generate a new Work Key in LN-YYYYMMDD-XXX format."
  def generate_work_key(meta \\ %{}) do
    GenServer.call(__MODULE__, {:generate_work_key, meta})
  end

  @doc "Ensure a work key entry exists (idempotent)."
  def ensure_work_key(work_key) do
    GenServer.call(__MODULE__, {:ensure_work_key, work_key})
  end

  @doc "Get state map for a work key."
  def get(work_key) do
    case :dets.lookup(@state_table, work_key) do
      [{^work_key, state}] -> state
      [] -> %{}
    end
  end

  @doc "Merge updates into state for a work key. Returns updated state."
  def update(work_key, updates) when is_map(updates) do
    GenServer.call(__MODULE__, {:update, work_key, updates})
  end

  @doc "List all work keys (sorted ascending)."
  def list_work_keys do
    dets_to_list(@state_table) |> Enum.map(fn {k, _} -> k end) |> Enum.sort()
  end

  @doc "Return the most recently created work key, or nil."
  def latest_work_key do
    case list_work_keys() do
      [] -> nil
      keys -> List.last(keys)
    end
  end

  @doc "Enqueue a message in an agent's mailbox."
  def enqueue_mailbox(agent_name, msg) do
    GenServer.call(__MODULE__, {:enqueue_mailbox, agent_name, msg})
  end

  @doc "Pop all messages from an agent's mailbox (clears it)."
  def pop_mailbox(agent_name) do
    GenServer.call(__MODULE__, {:pop_mailbox, agent_name})
  end

  @doc "Append task result (supports multiple agents responding to same task_id)."
  def store_task_result(task_id, result) do
    GenServer.call(__MODULE__, {:store_task_result, task_id, result})
  end

  @doc "Store a pending task with dependency list."
  def store_pending_task(task_id, task_info) do
    GenServer.call(__MODULE__, {:store_pending_task, task_id, task_info})
  end

  @doc "Mark a task_id as completed; return list of newly unblocked task payloads."
  def complete_dependency(completed_id) do
    GenServer.call(__MODULE__, {:complete_dependency, completed_id})
  end

  @doc "Get all task results. Returns {:ok, results} (list) or :not_found."
  def get_task_result(task_id) do
    case :dets.lookup(@task_table, task_id) do
      [{^task_id, results}] when is_list(results) -> {:ok, results}
      [] -> :not_found
    end
  end

  @doc "Peek at mailbox count without clearing."
  def mailbox_count(agent_name) do
    case :dets.lookup(@mailbox_table, agent_name) do
      [{^agent_name, msgs}] -> length(msgs)
      [] -> 0
    end
  end

  # ─── GenServer ──────────────────────────────────────────────────────────────

  @impl true
  def init(_) do
    data_dir = System.get_env("OAH_DATA_DIR", "data")
    File.mkdir_p!(data_dir)

    {:ok, _} = :dets.open_file(@state_table, [
      file: String.to_charlist(Path.join(data_dir, "harness_state.dets")),
      type: :set
    ])

    {:ok, _} = :dets.open_file(@mailbox_table, [
      file: String.to_charlist(Path.join(data_dir, "harness_mailbox.dets")),
      type: :set
    ])

    {:ok, _} = :dets.open_file(@task_table, [
      file: String.to_charlist(Path.join(data_dir, "harness_tasks.dets")),
      type: :set
    ])

    :ets.new(@pending_table, [:named_table, :public, read_concurrency: true])

    # Rebuild daily counter from persisted work keys
    counter = rebuild_counter()

    n = length(dets_to_list(@state_table))
    IO.puts("[StateStore] loaded #{n} work key(s) from disk (dir=#{data_dir})")

    {:ok, %{counter: counter}}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@state_table)
    :dets.close(@mailbox_table)
    :dets.close(@task_table)
    :ok
  end

  @impl true
  def handle_call({:generate_work_key, meta}, _from, state) do
    today = Date.utc_today() |> Date.to_string() |> String.replace("-", "")
    counter = Map.get(state.counter, today, 0) + 1
    work_key = "LN-#{today}-#{String.pad_leading("#{counter}", 3, "0")}"
    new_state = put_in(state.counter[today], counter)

    :dets.insert(@state_table, {work_key, %{
      work_key:       work_key,
      status:         "created",
      goal:           Map.get(meta, "goal", nil),
      project_dir:    Map.get(meta, "project_dir", nil),
      shared_context: Map.get(meta, "context", %{}),
      loop_count:     0,
      tasks:          [],
      created_at:     DateTime.utc_now() |> DateTime.to_iso8601(),
      updated_at:     DateTime.utc_now() |> DateTime.to_iso8601()
    }})

    {:reply, work_key, new_state}
  end

  @impl true
  def handle_call({:ensure_work_key, work_key}, _from, state) do
    unless :dets.member(@state_table, work_key) do
      :dets.insert(@state_table, {work_key, %{
        work_key:       work_key,
        status:         "created",
        goal:           nil,
        project_dir:    nil,
        shared_context: %{},
        loop_count:     0,
        tasks:          [],
        created_at:     DateTime.utc_now() |> DateTime.to_iso8601(),
        updated_at:     DateTime.utc_now() |> DateTime.to_iso8601()
      }})
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update, work_key, updates}, _from, state) do
    current = case :dets.lookup(@state_table, work_key) do
      [{^work_key, s}] -> s
      [] -> %{work_key: work_key, created_at: DateTime.utc_now() |> DateTime.to_iso8601()}
    end

    updated = Map.merge(current, updates)
              |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.to_iso8601())

    :dets.insert(@state_table, {work_key, updated})
    {:reply, updated, state}
  end

  @impl true
  def handle_call({:enqueue_mailbox, agent_name, msg}, _from, state) do
    msgs = case :dets.lookup(@mailbox_table, agent_name) do
      [{^agent_name, existing}] -> existing
      [] -> []
    end

    :dets.insert(@mailbox_table, {agent_name, msgs ++ [msg]})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:pop_mailbox, agent_name}, _from, state) do
    msgs = case :dets.lookup(@mailbox_table, agent_name) do
      [{^agent_name, existing}] -> existing
      [] -> []
    end

    :dets.delete(@mailbox_table, agent_name)
    {:reply, msgs, state}
  end

  @impl true
  def handle_call({:store_task_result, task_id, result}, _from, state) do
    existing = case :dets.lookup(@task_table, task_id) do
      [{^task_id, results}] when is_list(results) -> results
      [{^task_id, single}] -> [single]
      [] -> []
    end
    :dets.insert(@task_table, {task_id, existing ++ [result]})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:store_pending_task, task_id, task_info}, _from, state) do
    :ets.insert(@pending_table, {task_id, task_info})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:complete_dependency, completed_id}, _from, state) do
    # Scan all pending tasks; find ones whose depends_on is now satisfied
    all_pending = :ets.tab2list(@pending_table)
    results = Enum.flat_map(all_pending, fn {tid, info} ->
      deps = Map.get(info, "depends_on", [])
      if completed_id in deps do
        new_deps = List.delete(deps, completed_id)
        if new_deps == [] do
          :ets.delete(@pending_table, tid)
          [info]  # unblocked — return for dispatch
        else
          :ets.insert(@pending_table, {tid, Map.put(info, "depends_on", new_deps)})
          []
        end
      else
        []
      end
    end)
    {:reply, results, state}
  end

  # ─── Private ─────────────────────────────────────────────────────────────────

  # DETS has no tab2list — use foldl to collect all entries.
  defp dets_to_list(table) do
    :dets.foldl(fn item, acc -> [item | acc] end, [], table)
  end

  # Rebuild the daily sequence counter from persisted work keys so that
  # newly generated keys don't collide after a server restart.
  defp rebuild_counter do
    dets_to_list(@state_table)
    |> Enum.reduce(%{}, fn {key, _}, acc ->
      case String.split(to_string(key), "-") do
        ["LN", date, seq] ->
          n = String.to_integer(seq)
          Map.update(acc, date, n, &max(&1, n))
        _ ->
          acc
      end
    end)
  end
end
