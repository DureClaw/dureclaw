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
         http://0.0.0.0:#{port}
         ws://0.0.0.0:#{port}/socket/websocket
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
         REST Endpoints:
           GET  /api/health
           GET  /api/presence
           POST /api/work-keys
           GET  /api/state/:work_key
           PATCH /api/state/:work_key
           GET  /api/mailbox/:agent
           POST /api/mailbox/:agent
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
         Phoenix Channel:
           ws://.../socket/websocket?vsn=2.0.0
           topic: work:{WORK_KEY}
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        """)

        {:ok, pid}

      error ->
        error
    end
  end
end
