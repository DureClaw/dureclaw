defmodule HarnessServer.Presence do
  @moduledoc """
  Phoenix.Presence tracker for agent online status.

  Each connected agent is tracked by their agent_name (e.g. "builder@gpu").
  Presence data includes role, machine, work_key, and online_since.

  Use `Presence.list(socket)` to get all agents in a channel topic.
  Use `Presence.get_by_key(socket, agent_name)` to check if an agent is online.
  """

  use Phoenix.Presence,
    otp_app: :harness_server,
    pubsub_server: HarnessServer.PubSub
end
