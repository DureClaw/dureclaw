defmodule HarnessServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :harness_server,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      releases: [
        harness_server: [
          include_erts: true,
          strip_beams: true
        ]
      ],
      deps: deps()
    ]
  end

  def application do
    [
      mod: {HarnessServer.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_pubsub, "~> 2.1"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"}
    ]
  end
end
