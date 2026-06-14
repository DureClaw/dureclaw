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
    # OAH_BIND_IP always takes priority over auto-detection.
    case System.get_env("OAH_BIND_IP") do
      s when is_binary(s) and s != "" -> parse_bind_env(s)
      _ -> detect_tailscale_ip()
    end
  end

  defp parse_bind_env("0.0.0.0"), do: {0, 0, 0, 0}

  defp parse_bind_env(s) do
    case parse_ip(s) do
      {:ok, ip} -> ip
      _ -> {127, 0, 0, 1}
    end
  end

  # Auto-detect the Tailscale IP; return nil → caller falls back to 127.0.0.1.
  defp detect_tailscale_ip do
    with exe when is_binary(exe) <- tailscale_executable(),
         {out, 0} <- System.cmd(exe, ["ip", "-4"], stderr_to_stdout: true),
         line when is_binary(line) <- first_ipv4_line(out),
         {:ok, ip} <- parse_ip(line) do
      ip
    else
      _ -> nil
    end
  end

  # find_executable only searches $PATH, which a service manager may set
  # minimally (no /usr/local/bin). Fall back to common absolute install paths.
  defp tailscale_executable do
    System.find_executable("tailscale") ||
      Enum.find(
        [
          "/usr/local/bin/tailscale",
          "/opt/homebrew/bin/tailscale",
          "/usr/bin/tailscale",
          "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        ],
        &File.exists?/1
      )
  end

  # `tailscale ip -4` may emit blank lines or multiple addresses — take the
  # first line that looks like a dotted-quad IPv4.
  defp first_ipv4_line(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.find(fn l -> length(String.split(l, ".")) == 4 end)
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
