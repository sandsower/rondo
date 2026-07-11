System.put_env("LINEAR_API_KEY", System.get_env("LINEAR_API_KEY") || "test-linear-api-key")

# Existing dispatch tests exercise behavior above the host containment boundary.
# Tests for the fail-closed baseline pass :env_home_scoped explicitly.
Application.put_env(:rondo, :child_isolation_baseline, :os_credential_isolated)

# Live E2E tests (tagged :live_e2e) are opt-in only: run them via `make e2e`
# (mix test --only live_e2e) with RONDO_RUN_LIVE_E2E=1 and live credentials.
# Append to (not replace) any exclude set by the CLI so `--only` keeps working.
ExUnit.configure(exclude: (ExUnit.configuration()[:exclude] || []) ++ [:live_e2e])
ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
Code.require_file("support/live_e2e.exs", __DIR__)
