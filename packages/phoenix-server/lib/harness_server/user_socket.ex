defmodule HarnessServer.UserSocket do
  use Phoenix.Socket

  ## Channels
  # Matches any topic starting with "work:"
  channel "work:*", HarnessServer.WorkChannel

  @impl true
  def connect(params, socket, _connect_info) do
    agent_name = params["agent_name"] || "unknown@unknown"
    agent_role = params["role"] || "unknown"
    machine = params["machine"] || "unknown"

    socket =
      socket
      |> assign(:agent_name, agent_name)
      |> assign(:role, agent_role)
      |> assign(:machine, machine)

    {:ok, socket}
  end

  @impl true
  def id(socket), do: "agent:#{socket.assigns.agent_name}"
end
