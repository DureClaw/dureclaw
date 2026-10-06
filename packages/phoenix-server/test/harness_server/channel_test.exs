defmodule HarnessServer.ChannelTest do
  @moduledoc """
  End-to-end flow a real node goes through:
  keyless enroll → token → socket connect → join work key → receive a task the
  master dispatched over REST → report the result → master reads it back.
  """
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest
  import HarnessServer.TestHelpers

  alias HarnessServer.UserSocket

  @endpoint HarnessServer.Endpoint

  setup do
    wk =
      json(api(:post, "/api/work-keys", %{goal: "channel test"}, token: master_secret()))[
        "work_key"
      ]

    %{wk: wk}
  end

  defp join_as(token, name, wk) do
    {:ok, socket} =
      connect(UserSocket, %{"token" => token, "agent_name" => name, "role" => "builder"})

    {:ok, _reply, socket} = subscribe_and_join(socket, "work:#{wk}", %{"agent_name" => name})
    socket
  end

  test "socket connect requires a valid token" do
    assert connect(UserSocket, %{"token" => "nope"}) == :error
    assert connect(UserSocket, %{}) == :error
  end

  test "enrolled node receives a dispatched task and its result is readable", %{wk: wk} do
    token = enroll!("builder@e2e")
    socket = join_as(token, "builder@e2e", wk)

    # node shows up in presence
    names =
      json(api(:get, "/api/presence", nil, token: master_secret()))["agents"]
      |> Enum.map(& &1["name"])

    assert "builder@e2e" in names

    # master dispatches over REST → node gets it on the channel
    resp =
      api(
        :post,
        "/api/task",
        %{task_id: "e2e-1", to: "builder@e2e", work_key: wk, instructions: "[SHELL] echo hi"},
        token: master_secret()
      )

    assert resp.status == 201
    assert_broadcast("task.assign", %{"task_id" => "e2e-1", "instructions" => "[SHELL] echo hi"})

    # node reports back
    ref = push(socket, "task.result", %{"task_id" => "e2e-1", "status" => "done", "output" => "hi"})
    assert_reply(ref, :ok)

    result = api(:get, "/api/task/e2e-1", nil, token: master_secret())
    assert result.status == 200
    body = json(result)
    assert body["status"] == "done"
    assert body["output"] == "hi"
    assert body["from"] == "builder@e2e"
  end

  test "a failed result is terminal and keeps the node's reported status", %{wk: wk} do
    socket = join_as(enroll!("builder@fail"), "builder@fail", wk)

    ref =
      push(socket, "task.result", %{"task_id" => "e2e-fail", "status" => "error", "exit_code" => 1})

    assert_reply(ref, :ok)

    body = json(api(:get, "/api/task/e2e-fail", nil, token: master_secret()))
    # the node's own status wins in the merged view; the lifecycle stamp proves it finished
    assert body["status"] == "error"
    assert body["exit_code"] == 1
    assert is_binary(body["finished_at"])
  end

  test "worker tokens cannot issue orders over the channel, the master can", %{wk: wk} do
    worker = join_as(enroll!("builder@w"), "builder@w", wk)
    ref = push(worker, "task.assign", %{"task_id" => "w-1", "instructions" => "[SHELL] rm -rf /"})
    assert_reply(ref, :error, %{reason: _})

    # peer-grading relay is the one allowed worker → peer assign
    ref = push(worker, "task.assign", %{"task_id" => "w-2", "instructions" => "[GRADE] score this"})
    assert_reply(ref, :ok)

    master = join_as(master_secret(), "orchestrator@master", wk)
    ref = push(master, "task.assign", %{"task_id" => "m-1", "instructions" => "[SHELL] echo ok"})
    assert_reply(ref, :ok)
  end

  test "a dependent task is dispatched only after its dependency finishes", %{wk: wk} do
    socket = join_as(enroll!("builder@dep"), "builder@dep", wk)

    pending =
      api(
        :post,
        "/api/task",
        %{task_id: "dep-b", work_key: wk, depends_on: ["dep-a"], instructions: "second"},
        token: master_secret()
      )

    assert json(pending)["pending"] == true
    refute_broadcast("task.assign", %{"task_id" => "dep-b"}, 100)

    ref = push(socket, "task.result", %{"task_id" => "dep-a", "status" => "done"})
    assert_reply(ref, :ok)
    assert_broadcast("task.assign", %{"task_id" => "dep-b", "instructions" => "second"})
  end
end
