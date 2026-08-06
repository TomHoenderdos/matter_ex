defmodule MatterEx.FabricStore do
  @moduledoc """
  Persists and restores Matter operational state through a `MatterEx.Storage`
  backend, so a device stays commissioned across restarts.

  This is the one place that knows *what* fabric state exists and *how* to
  serialize it; the storage adapter only sees opaque binaries.

  ## What is persisted

  One key, `matter/state`, holding the whole snapshot:

    * the per-fabric operational identities from `MatterEx.Commissioning`
      (NOC/ICAC/root cert, **operational private key**, IPK, node/fabric ids,
      admin subject)
    * snapshots of the fabric-scoped cluster attribute lists
      (OperationalCredentials, AccessControl, GroupKeyManagement), which span all
      fabrics

  ## Why one key

  These values are only meaningful together. Split across several keys there is
  no commit point: an interruption between writing the fabrics and writing the
  cluster snapshots leaves a device that restores fabrics and answers CASE while
  OperationalCredentials reports `commissioned_fabrics: 0` — so it looks paired
  but tells a controller it has no fabrics, inviting a re-commission.

  A single value makes the storage adapter's atomic write the commit point: the
  snapshot is replaced whole or not at all. It also removes any need to reconcile
  removed fabrics, since the snapshot *is* the fabric set.

  `persist/3` writes it, `load/2` reads it back into the commissioning agent and
  the clusters and returns the credentials for the node to bring CASE back up,
  and `clear/2` is the inverse — resetting clusters and wiping storage for a
  factory reset.

  Both `persist/3` and `clear/2` report storage failures rather than swallowing
  them: this is a durability feature, and a write that silently did nothing is
  only discovered at the next reboot.
  """

  require Logger

  alias MatterEx.{Commissioning, Storage}

  @format_version 1

  @state_key "matter/state"

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
  @spec persist(module(), Storage.backend(), keyword()) :: :ok | {:error, term()}
  def persist(device, backend, opts \\ []) do
    comm = Keyword.get(opts, :commissioning, Commissioning)
    indices = Commissioning.get_fabric_indices(comm)

    fabrics =
      for index <- indices,
          creds = Commissioning.get_credentials(index, comm),
          creds != nil,
          into: %{},
          do: {index, creds}

    clusters =
      for {cluster, keys} <- @cluster_snapshot,
          into: %{},
          do: {cluster, cluster_snapshot(device, cluster, keys)}

    snapshot = %{fabrics: fabrics, clusters: clusters}

    case Storage.put(backend, @state_key, serialize(snapshot)) do
      :ok ->
        Logger.debug("FabricStore: persisted #{map_size(fabrics)} fabric(s)")
        :ok

      {:error, reason} = error ->
        # A read-only or full /data would otherwise no-op in silence, and the
        # device would look commissioned right up until it rebooted.
        Logger.error("FabricStore: failed to persist fabric state: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Load persisted state into the commissioning agent and the clusters.

  Returns the list of restored fabric credential maps (empty when nothing is
  stored). The caller enables CASE and operational discovery for each.
  """
  @spec load(module(), Storage.backend(), keyword()) :: [map()]
  def load(device, backend, opts \\ []) do
    comm = Keyword.get(opts, :commissioning, Commissioning)

    case fetch(backend, @state_key) do
      {:ok, %{fabrics: fabrics, clusters: clusters}} ->
        for {cluster, snapshot} <- clusters, do: restore_cluster(device, cluster, {:ok, snapshot})

        creds =
          for {_index, entry} <- fabrics do
            Commissioning.restore_fabric(entry, comm)
            entry
          end

        Logger.info("FabricStore: restored #{length(creds)} fabric(s) from storage")
        creds

      :error ->
        # Distinguish "nothing stored yet" from "stored and unreadable". The
        # second means a device silently came back uncommissioned, which is the
        # failure this module exists to prevent — it must not be inferred from an
        # empty log.
        case Storage.get(backend, @state_key) do
          {:ok, _binary} ->
            Logger.warning(
              "FabricStore: persisted state at #{@state_key} could not be read " <>
                "(corrupt, or written by a different format version). The device will " <>
                "start uncommissioned."
            )

          :error ->
            Logger.debug("FabricStore: no persisted state; starting uncommissioned")
        end

        []
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

    case wipe(backend) do
      :ok ->
        Logger.info("FabricStore: cleared all persisted fabric state")
        :ok

      {:error, reason} = error ->
        # "Factory reset" is a claim someone acts on when they resell or
        # redeploy hardware. Reporting success while operational private keys
        # remain on disk is the wrong kind of wrong.
        Logger.error(
          "FabricStore: factory reset did NOT fully wipe storage (#{inspect(reason)}); " <>
            "operational key material may remain on disk"
        )

        error
    end
  end

  defp wipe(nil), do: :ok

  defp wipe(backend) do
    backend
    |> Storage.keys("matter/")
    |> Enum.reduce(:ok, fn key, acc ->
      case {Storage.delete(backend, key), acc} do
        {:ok, acc} -> acc
        {{:error, reason}, _} -> {:error, reason}
      end
    end)
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
