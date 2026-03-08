defmodule HarnessServer.StateStore do
  @moduledoc """
  ETS-backed state store for Work Key state and agent mailboxes.

  Tables:
    :harness_state   — {work_key, state_map}
    :harness_mailbox — {agent_name, [messages]}

  Work Key state shape:
    %{
      work_key: "LN-20260308-001",
      status: "created" | "running" | "done" | "failed",
      goal: nil | string,
      loop_count: 0,
      tasks: [],
      created_at: iso8601,
      updated_at: iso8601
    }
  """

  use GenServer

  @state_table :harness_state
  @mailbox_table :harness_mailbox
  @task_table :harness_tasks

  # ─── Public API ─────────────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Generate a new Work Key in LN-YYYYMMDD-XXX format."
  def generate_work_key do
    GenServer.call(__MODULE__, :generate_work_key)
  end

  @doc "Ensure a work key entry exists (idempotent)."
  def ensure_work_key(work_key) do
    GenServer.call(__MODULE__, {:ensure_work_key, work_key})
  end

  @doc "Get state map for a work key."
  def get(work_key) do
    case :ets.lookup(@state_table, work_key) do
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
    :ets.tab2list(@state_table) |> Enum.map(fn {k, _} -> k end) |> Enum.sort()
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

  @doc "Store task result for REST polling."
  def store_task_result(task_id, result) do
    :ets.insert(@task_table, {task_id, result})
  end

  @doc "Get stored task result. Returns {:ok, result} or :not_found."
  def get_task_result(task_id) do
    case :ets.lookup(@task_table, task_id) do
      [{^task_id, result}] -> {:ok, result}
      [] -> :not_found
    end
  end

  @doc "Peek at mailbox count without clearing."
  def mailbox_count(agent_name) do
    case :ets.lookup(@mailbox_table, agent_name) do
      [{^agent_name, msgs}] -> length(msgs)
      [] -> 0
    end
  end

  # ─── GenServer ──────────────────────────────────────────────────────────────

  @impl true
  def init(_) do
    :ets.new(@state_table, [:named_table, :public, read_concurrency: true])
    :ets.new(@mailbox_table, [:named_table, :public, read_concurrency: true])
    :ets.new(@task_table, [:named_table, :public, read_concurrency: true])
    {:ok, %{counter: %{}}}
  end

  @impl true
  def handle_call(:generate_work_key, _from, state) do
    today = Date.utc_today() |> Date.to_string() |> String.replace("-", "")
    counter = Map.get(state.counter, today, 0) + 1
    work_key = "LN-#{today}-#{String.pad_leading("#{counter}", 3, "0")}"
    new_state = put_in(state.counter[today], counter)

    :ets.insert(@state_table, {work_key, %{
      work_key: work_key,
      status: "created",
      goal: nil,
      loop_count: 0,
      tasks: [],
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }})

    {:reply, work_key, new_state}
  end

  @impl true
  def handle_call({:ensure_work_key, work_key}, _from, state) do
    unless :ets.member(@state_table, work_key) do
      :ets.insert(@state_table, {work_key, %{
        work_key: work_key,
        status: "created",
        goal: nil,
        loop_count: 0,
        tasks: [],
        created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }})
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update, work_key, updates}, _from, state) do
    current = case :ets.lookup(@state_table, work_key) do
      [{^work_key, s}] -> s
      [] -> %{work_key: work_key, created_at: DateTime.utc_now() |> DateTime.to_iso8601()}
    end

    updated = Map.merge(current, updates)
              |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.to_iso8601())

    :ets.insert(@state_table, {work_key, updated})
    {:reply, updated, state}
  end

  @impl true
  def handle_call({:enqueue_mailbox, agent_name, msg}, _from, state) do
    msgs = case :ets.lookup(@mailbox_table, agent_name) do
      [{^agent_name, existing}] -> existing
      [] -> []
    end

    :ets.insert(@mailbox_table, {agent_name, msgs ++ [msg]})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:pop_mailbox, agent_name}, _from, state) do
    msgs = case :ets.lookup(@mailbox_table, agent_name) do
      [{^agent_name, existing}] -> existing
      [] -> []
    end

    :ets.delete(@mailbox_table, agent_name)
    {:reply, msgs, state}
  end
end
