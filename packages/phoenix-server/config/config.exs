import Config

config :harness_server, HarnessServer.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  server: true,
  secret_key_base: "harness_dev_secret_key_base_change_in_prod_must_be_64_chars_min",
  pubsub_server: HarnessServer.PubSub

config :harness_server, HarnessServer.Presence, pubsub_server: HarnessServer.PubSub

config :harness_server,
  ecto_repos: []

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
