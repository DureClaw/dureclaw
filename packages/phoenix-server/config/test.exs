import Config

# Tests drive the Endpoint in-process (Phoenix.ConnTest / ChannelTest) — never
# bind a real port, so `mix test` can't collide with a server already on :4000.
config :harness_server, HarnessServer.Endpoint, server: false

# Fresh, throwaway DETS dir + secret per test run. Set here (config is evaluated
# before the app boots) because StateStore/Auth read OAH_DATA_DIR at startup.
# (System.unique_integer is deterministic per fresh VM — it reused the same dir
# across runs and leaked DETS results between them, so use random bytes.)
test_data_dir =
  Path.join(
    System.tmp_dir!(),
    "dureclaw-test-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  )

File.rm_rf!(test_data_dir)
System.put_env("OAH_DATA_DIR", test_data_dir)

System.delete_env("OAH_SECRET")
System.delete_env("OAH_TRUST_LOOPBACK")
System.delete_env("OAH_REQUIRE_APPROVAL")

config :logger, level: :warning
