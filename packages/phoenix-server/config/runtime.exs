import Config

# Runtime configuration — overrides config.exs at startup.
# Set PORT and SECRET_KEY_BASE environment variables in production.

port = System.get_env("PORT", "4000") |> String.to_integer()
host = System.get_env("HOST", "0.0.0.0")

config :harness_server, HarnessServer.Endpoint,
  http: [
    ip: host |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple(),
    port: port
  ],
  server: true,
  pubsub_server: HarnessServer.PubSub

if secret_key_base = System.get_env("SECRET_KEY_BASE") do
  config :harness_server, HarnessServer.Endpoint, secret_key_base: secret_key_base
end
