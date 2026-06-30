defmodule Rondo.TestSupportTest do
  use ExUnit.Case, async: true

  test "wait_for_http_server_shutdown raises when the check never succeeds" do
    assert_raise RuntimeError, "HTTP server did not shut down in time", fn ->
      Rondo.TestSupport.wait_for_http_server_shutdown(fn -> false end, 1, 0)
    end
  end
end
