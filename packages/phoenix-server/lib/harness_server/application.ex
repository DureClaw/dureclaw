defmodule HarnessServer.Application do
  @moduledoc """
  OTP Application supervisor for the open-agent-harness Phoenix server.

  Starts in order:
    1. StateStore  — ETS-backed state per Work Key
    2. PubSub      — Phoenix.PubSub for channel broadcasting
    3. Presence    — Phoenix.Presence for agent online tracking
    4. Endpoint    — Phoenix HTTP + WebSocket server
  """

  use Application

  @impl true
  def start(_type, _args) do
    secret = HarnessServer.Auth.load_secret()
    bind_ip = tailscale_ip() || {127, 0, 0, 1}
    bind_str = bind_ip |> Tuple.to_list() |> Enum.join(".")

    Application.put_env(
      :harness_server,
      HarnessServer.Endpoint,
      Keyword.merge(
        Application.get_env(:harness_server, HarnessServer.Endpoint, []),
        http: [ip: bind_ip, port: port()]
      )
    )

    children = [
      HarnessServer.StateStore,
      {Phoenix.PubSub, name: HarnessServer.PubSub},
      HarnessServer.Presence,
      HarnessServer.Endpoint
    ]

    opts = [strategy: :one_for_one, name: HarnessServer.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        port = Application.get_env(:harness_server, HarnessServer.Endpoint)[:http][:port]

        IO.puts("""
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
         open-agent-harness | phoenix-server
         http://#{bind_str}:#{port}
         ws://#{bind_str}:#{port}/socket/websocket?token=<secret>
         OAH_SECRET: #{secret}
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
         REST: Authorization: Bearer <OAH_SECRET>
         WS:   ?token=<OAH_SECRET>
         Exempt: GET /api/health, GET /, GET /dashboard
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        """)

        {:ok, pid}

      error ->
        error
    end
  end

  defp port,
    do:
      Application.get_env(:harness_server, HarnessServer.Endpoint, [])
      |> Keyword.get(:http, [])
      |> Keyword.get(:port, 4000)

  defp tailscale_ip do
    # OAH_BIND_IP always takes priority over auto-detection
    case System.get_env("OAH_BIND_IP") do
      s when is_binary(s) and s != "" ->
        case s do
          "0.0.0.0" ->
            {0, 0, 0, 0}

          _ ->
            case parse_ip(s) do
              {:ok, ip} -> ip
              _ -> {127, 0, 0, 1}
            end
        end

      _ ->
        # Auto-detect: prefer Tailscale IP, else return nil → caller falls back to 127.0.0.1
        with ts when ts != "" <- System.find_executable("tailscale") || "",
             {out, 0} <- System.cmd(ts, ["ip", "-4"], stderr_to_stdout: true),
             {:ok, ip} <- parse_ip(String.trim(out)) do
          ip
        else
          _ -> nil
        end
    end
  end

  defp parse_ip(s) do
    case String.split(s, ".") do
      [a, b, c, d] ->
        try do
          {:ok,
           {String.to_integer(a), String.to_integer(b), String.to_integer(c), String.to_integer(d)}}
        rescue
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
