defmodule HarnessServer.ApiTest do
  # StateStore/DETS is a single shared process — keep these serial.
  use ExUnit.Case, async: false

  import HarnessServer.TestHelpers

  describe "auth" do
    test "health is public" do
      conn = api(:get, "/api/health")
      assert conn.status == 200
      assert json(conn)["ok"] == true
    end

    test "protected endpoints reject requests without a token" do
      assert api(:get, "/api/presence").status == 401
      assert api(:get, "/api/presence", nil, token: "wrong").status == 401
    end

    test "master secret is accepted" do
      assert api(:get, "/api/presence", nil, token: master_secret()).status == 200
    end

    test "secret is generated under OAH_DATA_DIR at runtime (not a build-time path)" do
      file = Path.join(System.fetch_env!("OAH_DATA_DIR"), "server.secret")
      assert File.read!(file) |> String.trim() == master_secret()
    end
  end

  describe "keyless enrollment" do
    test "loopback/tailnet node is auto-approved with a per-node token" do
      conn = api(:post, "/api/join", %{name: "builder@local", machine: "local"})
      assert conn.status == 200
      body = json(conn)
      assert body["status"] == "approved"
      assert is_binary(body["token"]) and body["token"] != master_secret()

      # the per-node token opens the REST API …
      assert api(:get, "/api/presence", nil, token: body["token"]).status == 200
    end

    test "tailnet range (100.64.0.0/10) is auto-approved" do
      conn = api(:post, "/api/join", %{name: "builder@ts"}, ip: {100, 100, 1, 2})
      assert json(conn)["status"] == "approved"
    end

    test "off-tailnet node waits for operator approval" do
      conn = api(:post, "/api/join", %{name: "builder@internet"}, ip: {203, 0, 113, 5})
      assert conn.status == 202
      id = json(conn)["enroll_id"]

      poll = api(:get, "/api/join/#{id}", nil, ip: {203, 0, 113, 5})
      assert json(poll)["status"] == "pending"
      refute Map.has_key?(json(poll), "token")

      # a worker token cannot approve — only the master
      worker = enroll!("builder@approver")
      assert api(:post, "/api/join/#{id}/approve", %{}, token: worker).status == 403

      assert api(:post, "/api/join/#{id}/approve", %{}, token: master_secret()).status == 200

      approved = json(api(:get, "/api/join/#{id}", nil, ip: {203, 0, 113, 5}))
      assert approved["status"] == "approved"
      assert is_binary(approved["token"])
    end
  end

  describe "work keys" do
    test "create then read latest" do
      conn = api(:post, "/api/work-keys", %{goal: "test"}, token: master_secret())
      assert conn.status == 201
      wk = json(conn)["work_key"]
      assert is_binary(wk)

      latest = api(:get, "/api/work-keys/latest", nil, token: master_secret())
      assert latest.status == 200
      assert json(latest)["work_key"] == wk
    end

    test "latest is the newest by creation time, not by name" do
      # random WK-xxxxxxxx names don't sort chronologically — create several and
      # check latest always tracks the one just made
      for _ <- 1..8 do
        Process.sleep(2)
        wk = json(api(:post, "/api/work-keys", %{}, token: master_secret()))["work_key"]

        assert json(api(:get, "/api/work-keys/latest", nil, token: master_secret()))["work_key"] ==
                 wk
      end
    end
  end

  describe "single command origin" do
    test "only the master may dispatch tasks" do
      worker = enroll!("builder@worker")

      denied = api(:post, "/api/task", %{instructions: "[SHELL] echo hi"}, token: worker)
      assert denied.status == 403

      ok = api(:post, "/api/task", %{instructions: "[SHELL] echo hi"}, token: master_secret())
      assert ok.status == 201
      assert json(ok)["status"] == "queued"
    end

    test "dispatched task reports queued until a result arrives" do
      ok =
        api(:post, "/api/task", %{task_id: "t-queued", instructions: "x"}, token: master_secret())

      assert ok.status == 201

      st = api(:get, "/api/task/t-queued", nil, token: master_secret())
      assert st.status == 202
      assert json(st)["status"] == "queued"
    end
  end
end
