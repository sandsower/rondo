defmodule Rondo.PathSafetyTest do
  use ExUnit.Case, async: true

  alias Rondo.PathSafety

  test "canonicalize returns the expanded path for a regular directory" do
    test_root = Path.join(System.tmp_dir!(), "rondo-pathsafety-regular-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    try do
      assert {:ok, canonical} = PathSafety.canonicalize(test_root)
      assert canonical == Path.expand(test_root)
    after
      File.rm_rf(test_root)
    end
  end

  test "canonicalize resolves a symlink to its target" do
    test_root = Path.join(System.tmp_dir!(), "rondo-pathsafety-symlink-#{System.unique_integer([:positive])}")
    real_dir = Path.join(test_root, "real")
    link_path = Path.join(test_root, "link")

    File.mkdir_p!(real_dir)
    File.ln_s!(real_dir, link_path)

    try do
      assert {:ok, canonical} = PathSafety.canonicalize(link_path)
      assert canonical == Path.expand(real_dir)
    after
      File.rm_rf(test_root)
    end
  end

  test "canonicalize resolves nested symlinks" do
    test_root = Path.join(System.tmp_dir!(), "rondo-pathsafety-nested-#{System.unique_integer([:positive])}")
    real_dir = Path.join(test_root, "real")
    child = Path.join(real_dir, "child")
    link_path = Path.join(test_root, "link")

    File.mkdir_p!(child)
    File.ln_s!(real_dir, link_path)

    try do
      # canonicalize link/child should resolve to real/child
      assert {:ok, canonical} = PathSafety.canonicalize(Path.join(link_path, "child"))
      assert canonical == Path.expand(child)
    after
      File.rm_rf(test_root)
    end
  end

  test "canonicalize passes through nonexistent tail segments" do
    test_root = Path.join(System.tmp_dir!(), "rondo-pathsafety-enoent-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    try do
      nonexistent = Path.join(test_root, "does-not-exist/deeply/nested")
      assert {:ok, canonical} = PathSafety.canonicalize(nonexistent)
      assert canonical == Path.expand(nonexistent)
    after
      File.rm_rf(test_root)
    end
  end

  test "canonicalize detects symlink loops and returns error" do
    test_root = Path.join(System.tmp_dir!(), "rondo-pathsafety-loop-#{System.unique_integer([:positive])}")
    link_a = Path.join(test_root, "a")
    link_b = Path.join(test_root, "b")

    File.mkdir_p!(test_root)
    # Create a -> b, b -> a loop
    File.ln_s!(link_b, link_a)
    File.ln_s!(link_a, link_b)

    try do
      assert {:error, {:path_canonicalize_failed, _, :symlink_loop}} = PathSafety.canonicalize(link_a)
    after
      File.rm_rf(test_root)
    end
  end

  test "canonicalize resolves symlink that escapes parent" do
    test_root = Path.join(System.tmp_dir!(), "rondo-pathsafety-escape-#{System.unique_integer([:positive])}")
    inside = Path.join(test_root, "inside")
    outside = Path.join(test_root, "outside")
    escape_link = Path.join(inside, "escape")

    File.mkdir_p!(inside)
    File.mkdir_p!(outside)
    File.ln_s!(outside, escape_link)

    try do
      assert {:ok, canonical} = PathSafety.canonicalize(escape_link)
      # The canonical path should point to the real target (outside), not the symlink
      assert canonical == Path.expand(outside)
    after
      File.rm_rf(test_root)
    end
  end
end
