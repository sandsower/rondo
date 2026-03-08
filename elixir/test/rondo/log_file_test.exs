defmodule Rondo.LogFileTest do
  use ExUnit.Case, async: true

  alias Rondo.LogFile

  test "default_log_file/0 uses the current working directory" do
    assert LogFile.default_log_file() == Path.join(File.cwd!(), "log/rondo.log")
  end

  test "default_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_log_file("/tmp/rondo-logs") == "/tmp/rondo-logs/log/rondo.log"
  end
end
