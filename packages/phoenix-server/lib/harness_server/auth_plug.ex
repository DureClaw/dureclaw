defmodule HarnessServer.AuthPlug do
  @moduledoc """
  HTTP Bearer auth plug with path-based exemptions.

  Exempt paths (no token required):
    GET /api/health   — uptime checks
    GET /             — dashboard (browser)
    GET /dashboard    — dashboard (browser)
    GET /setup*       — agent installer scripts
    GET /dist/*       — agent binaries
  """

  @exempt [
    "/api/health",
    "/",
    "/dashboard",
    "/setup",
    "/setup.ps1",
    "/setup-agent.sh",
    "/setup-agent.ps1",
    "/go",
    "/install",
    "/oah"
  ]

  def init(opts), do: opts

  def call(conn, _opts) do
    if exempt?(conn) do
      conn
    else
      HarnessServer.Auth.call(conn, [])
    end
  end

  defp exempt?(conn) do
    Enum.member?(@exempt, conn.request_path) or
      String.starts_with?(conn.request_path, "/dist/")
  end
end
