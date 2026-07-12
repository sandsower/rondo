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
end
