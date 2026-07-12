defmodule Rondo.Core.IdentityTest do
  use ExUnit.Case, async: false

  alias Rondo.Core.Identity

  test "instance identity is stable and lowercase for the life of the BEAM process" do
    first = Identity.snapshot(Rondo.Orchestrator)
    second = Identity.snapshot(Rondo.Orchestrator)

    assert first["instance_id"] == second["instance_id"]

    assert first["instance_id"] =~
             ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  end

  test "concurrent initialization keeps one stable process identity" do
    snapshots =
      1..32
      |> Task.async_stream(fn _ -> Identity.snapshot(Rondo.Orchestrator) end,
        max_concurrency: 32,
        ordered: false
      )
      |> Enum.map(fn {:ok, snapshot} -> snapshot end)

    assert snapshots |> Enum.map(& &1["instance_id"]) |> Enum.uniq() |> length() == 1
  end

  test "invalid configured service modes fail closed" do
    previous = Application.get_env(:rondo, :service_mode)
    Application.put_env(:rondo, :service_mode, :unexpected)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:rondo, :service_mode)
      else
        Application.put_env(:rondo, :service_mode, previous)
      end
    end)

    assert_raise RuntimeError, "invalid Rondo service mode", fn ->
      Identity.snapshot(Rondo.Orchestrator)
    end
  end
end
