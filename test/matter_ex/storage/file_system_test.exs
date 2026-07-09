defmodule MatterEx.Storage.FileSystemTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias MatterEx.Storage.FileSystem

  @moduletag :tmp_dir

  defp config(dir), do: [dir: Path.join(dir, "store")]

  test "put/get round-trips a value", %{tmp_dir: dir} do
    c = config(dir)
    assert :ok = FileSystem.put(c, "matter/fabric/1", "hello")
    assert {:ok, "hello"} = FileSystem.get(c, "matter/fabric/1")
  end

  test "get returns :error for a missing key", %{tmp_dir: dir} do
    assert :error = FileSystem.get(config(dir), "matter/nope")
  end

  test "delete removes a key and is a no-op when absent", %{tmp_dir: dir} do
    c = config(dir)
    FileSystem.put(c, "k", "v")
    assert :ok = FileSystem.delete(c, "k")
    assert :error = FileSystem.get(c, "k")
    assert :ok = FileSystem.delete(c, "k")
  end

  test "keys lists by prefix", %{tmp_dir: dir} do
    c = config(dir)
    FileSystem.put(c, "matter/fabric/1", "a")
    FileSystem.put(c, "matter/fabric/2", "b")
    FileSystem.put(c, "matter/acl", "c")

    assert Enum.sort(FileSystem.keys(c, "matter/fabric/")) ==
             ["matter/fabric/1", "matter/fabric/2"]

    assert "matter/acl" in FileSystem.keys(c, "matter")
  end

  test "files are 0600 and the base dir is 0700", %{tmp_dir: dir} do
    c = config(dir)
    FileSystem.put(c, "matter/fabric/1", "secret")

    {:ok, file_stat} = File.stat(Path.join(c[:dir], "matter/fabric/1"))
    assert (file_stat.mode &&& 0o777) == 0o600

    {:ok, dir_stat} = File.stat(c[:dir])
    assert (dir_stat.mode &&& 0o777) == 0o700
  end

  test "rejects keys that escape the base dir", %{tmp_dir: dir} do
    assert_raise ArgumentError, fn -> FileSystem.put(config(dir), "../evil", "x") end
  end
end
