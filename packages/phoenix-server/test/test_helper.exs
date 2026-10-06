ExUnit.start()

# config/test.exs points OAH_DATA_DIR at a fresh random tmp dir — remove it afterwards.
ExUnit.after_suite(fn _ -> File.rm_rf(System.fetch_env!("OAH_DATA_DIR")) end)

defmodule HarnessServer.TestHelpers do
  @moduledoc "Shared helpers for HTTP + channel integration tests."

  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint HarnessServer.Endpoint

  def master_secret, do: HarnessServer.Auth.secret()

  def api(method, path, body \\ nil, opts \\ []) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> Map.put(:remote_ip, Keyword.get(opts, :ip, {127, 0, 0, 1}))

    conn =
      case Keyword.get(opts, :token) do
        nil -> conn
        t -> put_req_header(conn, "authorization", "Bearer " <> t)
      end

    payload = if body, do: Jason.encode!(body), else: ""
    dispatch(conn, @endpoint, method, path, payload)
  end

  def json(conn), do: Jason.decode!(conn.resp_body)

  @doc "Enroll a keyless node from the loopback (auto-approved) and return its token."
  def enroll!(name) do
    conn = api(:post, "/api/join", %{name: name, machine: "test", role: "builder"})
    200 = conn.status
    json(conn)["token"]
  end
end
