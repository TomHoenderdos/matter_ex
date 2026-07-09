defmodule MatterEx.FabricStore do
  @moduledoc """
  Persists and restores Matter operational state through a `MatterEx.Storage`
  backend, so a device stays commissioned across restarts.

  This is the one place that knows *what* fabric state exists and *how* to
  serialize it; the storage adapter only sees opaque binaries.

  ## What is persisted

  Two kinds of value, all under the `matter/` prefix:

    * `matter/fabric/<index>` — the per-fabric operational identity from
      `MatterEx.Commissioning` (NOC/ICAC/root cert, **operational private key**,
      IPK, node/fabric ids, admin subject), plus `matter/fabrics` listing the
      live indices.
    * `matter/opcreds`, `matter/acl`, `matter/groups` — snapshots of the
      fabric-scoped cluster attribute lists (OperationalCredentials,
      AccessControl, GroupKeyManagement), which span all fabrics.

  `persist/2` reconciles the whole set (writing current fabrics, deleting removed
  ones); `load/2` reads it back into the commissioning agent and the clusters and
  returns the loaded fabric credentials for the node to bring CASE back up.
  `clear/3` is the inverse of both — it resets the clusters and wipes storage for
  a factory reset.
  """

  require Logger

  alias MatterEx.{Commissioning, Storage}

  @format_version 1

  @index_key "matter/fabrics"
  @fabric_prefix "matter/fabric/"
  @opcreds_key "matter/opcreds"
  @acl_key "matter/acl"
  @groups_key "matter/groups"

  # Which pieces of each fabric-scoped cluster's state to snapshot. Attributes
  # plus the internal fields the cluster needs (e.g. group key sets), excluding
  # runtime identity and transient commissioning state.
  @cluster_snapshot %{
    operational_credentials: [
      :nocs,
      :fabrics,
      :trusted_root_certificates,
      :commissioned_fabrics,
      :current_fabric_index,
      :_next_fabric_index
    ],
    access_control: [:acl, :extension],
    group_key_management: [:group_key_map, :group_table, :_key_sets]
  }

  # Values to restore each snapshotted cluster field to on a factory reset —
  # the cluster's freshly-initialized defaults (attribute defaults plus the
  # internal fields' init values). Keys mirror @cluster_snapshot.
  @cluster_defaults %{
    operational_credentials: %{
      nocs: [],
      fabrics: [],
      trusted_root_certificates: [],
      commissioned_fabrics: 0,
      current_fabric_index: 0,
      _next_fabric_index: 1
    },
    access_control: %{acl: [], extension: []},
    group_key_management: %{group_key_map: [], group_table: [], _key_sets: %{}}
  }

  @doc """
  Reconcile all fabric state to `backend`. Idempotent — safe to call after any
  fabric-scoped change (commissioning complete, ACL/group write, fabric removal).

  `:commissioning` overrides the commissioning agent name (defaults to
  `MatterEx.Commissioning`); mainly for testing.
  """
  @spec persist(module(), Storage.backend(), keyword()) :: :ok
  def persist(device, backend, opts \\ []) do
    comm = Keyword.get(opts, :commissioning, Commissioning)
    indices = Commissioning.get_fabric_indices(comm)

    # Write current fabric identities, delete blobs for fabrics that are gone.
    for index <- indices, creds = Commissioning.get_credentials(index, comm), creds != nil do
      Storage.put(backend, fabric_key(index), serialize(creds))
    end

    current = MapSet.new(indices, &fabric_key/1)

    for key <- Storage.keys(backend, @fabric_prefix), not MapSet.member?(current, key) do
      Storage.delete(backend, key)
    end

    Storage.put(backend, @index_key, serialize(indices))

    for {cluster, keys} <- @cluster_snapshot do
      Storage.put(
        backend,
        cluster_key(cluster),
        serialize(cluster_snapshot(device, cluster, keys))
      )
    end

    Logger.debug("FabricStore: persisted #{length(indices)} fabric(s)")
    :ok
  end

  @doc """
  Load persisted state into the commissioning agent and the clusters.

  Returns the list of restored fabric credential maps (empty when nothing is
  stored). The caller enables CASE and operational discovery for each.
  """
  @spec load(module(), Storage.backend(), keyword()) :: [map()]
  def load(device, backend, opts \\ []) do
    comm = Keyword.get(opts, :commissioning, Commissioning)

    with {:ok, indices} when indices != [] <- fetch(backend, @index_key) do
      creds =
        for index <- indices, {:ok, entry} <- [fetch(backend, fabric_key(index))] do
          Commissioning.restore_fabric(entry, comm)
          entry
        end

      for {cluster, _keys} <- @cluster_snapshot do
        restore_cluster(device, cluster, fetch(backend, cluster_key(cluster)))
      end

      Logger.info("FabricStore: restored #{length(creds)} fabric(s) from storage")
      creds
    else
      _ -> []
    end
  end

  @doc """
  Wipe all persisted Matter state — the inverse of `persist/3`, for factory reset.

  Resets the live fabric-scoped clusters (OperationalCredentials, AccessControl,
  GroupKeyManagement) back to their initial defaults, then deletes every
  `matter/`-prefixed key from `backend`. `backend` may be `nil` (in-memory node),
  in which case only the clusters are reset. The commissioning agent and the
  message handler's session state are reset separately by the caller.
  """
  @spec clear(module(), Storage.backend() | nil) :: :ok
  def clear(device, backend) do
    for {cluster, defaults} <- @cluster_defaults do
      case cluster_pid(device, cluster) do
        nil -> :ok
        name -> GenServer.call(name, {:restore_state, defaults})
      end
    end

    if backend do
      for key <- Storage.keys(backend, "matter/"), do: Storage.delete(backend, key)
    end

    Logger.info("FabricStore: cleared all persisted fabric state")
    :ok
  end

  # ── Private ─────────────────────────────────────────────────────

  defp cluster_snapshot(device, cluster, keys) do
    case cluster_pid(device, cluster) do
      nil -> %{}
      name -> name |> GenServer.call(:get_state) |> Map.take(keys)
    end
  end

  defp restore_cluster(device, cluster, {:ok, snapshot})
       when is_map(snapshot) and snapshot != %{} do
    case cluster_pid(device, cluster) do
      nil -> :ok
      name -> GenServer.call(name, {:restore_state, snapshot})
    end
  end

  defp restore_cluster(_device, _cluster, _), do: :ok

  defp cluster_pid(device, cluster) do
    name = device.__process_name__(0, cluster)
    if name && Process.whereis(name), do: name
  end

  defp fabric_key(index), do: @fabric_prefix <> Integer.to_string(index)
  defp cluster_key(:operational_credentials), do: @opcreds_key
  defp cluster_key(:access_control), do: @acl_key
  defp cluster_key(:group_key_management), do: @groups_key

  defp serialize(term), do: :erlang.term_to_binary({@format_version, term})

  defp fetch(backend, key) do
    with {:ok, binary} <- Storage.get(backend, key) do
      deserialize(binary)
    end
  end

  defp deserialize(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      {@format_version, term} -> {:ok, term}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end
end
