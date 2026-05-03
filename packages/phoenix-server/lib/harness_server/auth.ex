defmodule HarnessServer.Auth do
  @moduledoc """
  Secret-based auth for the REST API and WebSocket connections.

  OAH_SECRET is generated on first server start and stored in the data
  directory. Agents receive it embedded in setup-agent.sh served by this
  server, so only machines that have run the setup script can connect.

  HTTP: Authorization: Bearer <secret>
  WS:   phx_join payload includes {"secret": "<secret>"}
  """

  import Plug.Conn

  @secret_file Path.join(System.get_env("OAH_DATA_DIR", "data"), "server.secret")

  # ── Secret lifecycle ──────────────────────────────────────────────────────────

  @doc "Load or generate the server secret. Called at application start."
  def load_secret do
    case System.get_env("OAH_SECRET") do
      s when is_binary(s) and s != "" ->
        Application.put_env(:harness_server, :oah_secret, s)
        s

      _ ->
        load_from_file()
    end
  end

  defp load_from_file do
    case File.read(@secret_file) do
      {:ok, s} ->
        s = String.trim(s)
        Application.put_env(:harness_server, :oah_secret, s)
        s

      {:error, _} ->
        s = :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)
        File.mkdir_p!(Path.dirname(@secret_file))
        File.write!(@secret_file, s)
        File.chmod!(@secret_file, 0o600)
        Application.put_env(:harness_server, :oah_secret, s)
        s
    end
  end

  @doc "Return the current server secret."
  def secret, do: Application.get_env(:harness_server, :oah_secret, "")

  # ── Plug (HTTP auth) ──────────────────────────────────────────────────────────

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = secret()

    token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> t] -> t
        _ -> conn.query_params["secret"]
      end

    if expected != "" and token == expected do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
      |> halt()
    end
  end

  # ── WebSocket auth ────────────────────────────────────────────────────────────

  @doc "Verify secret from WebSocket connect params. Returns :ok | {:error, reason}."
  def verify_ws(params) do
    expected = secret()

    cond do
      expected == "" -> :ok
      params["token"] == expected -> :ok
      params["secret"] == expected -> :ok
      true -> {:error, :unauthorized}
    end
  end
end
