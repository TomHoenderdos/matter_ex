defmodule MatterEx.Storage.FileSystem do
  @moduledoc """
  Filesystem-backed `MatterEx.Storage` adapter.

  Each key is stored as a file under a base directory, mapping the `/`-separated
  key straight onto a relative path (`"matter/fabric/1"` → `<dir>/matter/fabric/1`).

  Configure with `dir:`:

      storage: {MatterEx.Storage.FileSystem, dir: "/data/matter"}

  The base directory is created `0700` and files are written `0600`, since the
  payloads contain operational private keys. It is still **plaintext at rest** —
  use an encrypted volume, or a different adapter, where that matters.
  """

  @behaviour MatterEx.Storage

  @impl true
  def get(config, key) do
    case File.read(path(config, key)) do
      {:ok, binary} -> {:ok, binary}
      {:error, _} -> :error
    end
  end

  @impl true
  def put(config, key, value) when is_binary(value) do
    dir = base_dir(config)
    path = path(config, key)

    with :ok <- ensure_dir(dir),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, value) do
      File.chmod(path, 0o600)
    end
  end

  @impl true
  def delete(config, key) do
    case File.rm(path(config, key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      other -> other
    end
  end

  @impl true
  def keys(config, prefix) do
    dir = base_dir(config)

    dir
    |> all_files()
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.filter(&String.starts_with?(&1, prefix))
  end

  # ── Private ─────────────────────────────────────────────────────

  defp base_dir(config), do: Keyword.fetch!(config, :dir)

  defp path(config, key), do: Path.join(base_dir(config), safe_key!(key))

  # Keys are MatterEx-controlled, but never let one escape the base directory.
  defp safe_key!(key) do
    if String.contains?(key, "..") do
      raise ArgumentError, "unsafe storage key: #{inspect(key)}"
    end

    key
  end

  defp ensure_dir(dir) do
    with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
  end

  defp all_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)
          if File.dir?(path), do: all_files(path), else: [path]
        end)

      {:error, _} ->
        []
    end
  end
end
