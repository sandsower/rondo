System.put_env("LINEAR_API_KEY", System.get_env("LINEAR_API_KEY") || "test-linear-api-key")

ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
