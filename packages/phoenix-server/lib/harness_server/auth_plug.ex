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
    if exempt?(conn) or trusted_loopback?(conn) do
      conn
    else
      HarnessServer.Auth.call(conn, [])
    end
  end

  # OAH_TRUST_LOOPBACK=1 lets a same-box orchestrator (Claude Code + skills) use
  # the REST API without hunting for OAH_SECRET (#16). Off by default; only ever
  # trusts real loopback source IPs, never a forwarded/remote address.
  defp trusted_loopback?(conn) do
    System.get_env("OAH_TRUST_LOOPBACK") in ["1", "true"] and loopback_ip?(conn.remote_ip)
  end

  defp loopback_ip?({127, _, _, _}), do: true
  defp loopback_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_ip?(_), do: false

  defp exempt?(conn) do
    Enum.member?(@exempt, conn.request_path) or
      String.starts_with?(conn.request_path, "/dist/") or
      join_exempt?(conn)
  end

  # Enrollment: a keyless node may POST /api/join and poll GET /api/join/:id.
  # approve/deny (POST /api/join/:id/approve) stay authed (operator only).
  defp join_exempt?(conn) do
    (conn.method == "POST" and conn.request_path == "/api/join") or
      (conn.method == "GET" and String.starts_with?(conn.request_path, "/api/join/"))
  end
end
