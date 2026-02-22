defmodule Matterlix.Cluster.GroupKeyManagement do
  @moduledoc """
  Matter Group Key Management cluster (0x003F).

  Manages group key sets and the group-to-key mapping table. When a key set
  is written and a group_key_map entry references it, the cluster derives
  operational group keys and encryption keys for use in group messaging.

  Endpoint 0 only.
  """

  use Matterlix.Cluster, id: 0x003F, name: :group_key_management

  alias Matterlix.Crypto.GroupKey

  attribute 0x0000, :group_key_map, :list, default: [], writable: true
  attribute 0x0001, :group_table, :list, default: []
  attribute 0x0002, :max_groups_per_fabric, :uint16, default: 4
  attribute 0x0003, :max_group_keys_per_fabric, :uint16, default: 3
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1

  command 0x00, :key_set_write, [group_key_set: :struct]
  command 0x01, :key_set_read, [group_key_set_id: :uint16]
  command 0x03, :key_set_remove, [group_key_set_id: :uint16]
  command 0x04, :key_set_read_all_indices, []

  @impl true
  def init(opts) do
    {:ok, state} = super(opts)
    # Internal storage: key_set_id => %{epoch_key0: binary, ...}
    {:ok, Map.put(state, :_key_sets, %{})}
  end

  @impl Matterlix.Cluster
  def handle_command(:key_set_write, params, state) do
    key_set = params[:group_key_set] || params

    key_set_id = key_set[:group_key_set_id] || key_set[0]
    epoch_key0 = key_set[:epoch_key0] || key_set[1]

    if key_set_id && epoch_key0 do
      key_sets = Map.get(state, :_key_sets, %{})
      entry = %{
        group_key_set_id: key_set_id,
        epoch_key0: epoch_key0,
        epoch_start_time0: key_set[:epoch_start_time0] || key_set[2] || 0
      }
      key_sets = Map.put(key_sets, key_set_id, entry)
      state = Map.put(state, :_key_sets, key_sets)

      # Rebuild group_table from group_key_map + key_sets
      state = rebuild_group_table(state)

      {:ok, nil, state}
    else
      {:ok, nil, state}
    end
  end

  def handle_command(:key_set_read, params, state) do
    key_set_id = params[:group_key_set_id] || params[0]
    key_sets = Map.get(state, :_key_sets, %{})

    case Map.get(key_sets, key_set_id) do
      nil ->
        # KeySetReadResponse with empty key set
        {:ok, %{0 => {:struct, %{0 => {:uint, key_set_id}}}}, state}

      entry ->
        {:ok, %{0 => {:struct, %{
          0 => {:uint, entry.group_key_set_id},
          2 => {:uint, entry.epoch_start_time0}
        }}}, state}
    end
  end

  def handle_command(:key_set_remove, params, state) do
    key_set_id = params[:group_key_set_id] || params[0]
    key_sets = Map.get(state, :_key_sets, %{})
    key_sets = Map.delete(key_sets, key_set_id)
    state = Map.put(state, :_key_sets, key_sets)
    state = rebuild_group_table(state)
    {:ok, nil, state}
  end

  def handle_command(:key_set_read_all_indices, _params, state) do
    key_sets = Map.get(state, :_key_sets, %{})
    indices = Map.keys(key_sets)
    {:ok, %{0 => {:list, Enum.map(indices, &{:uint, &1})}}, state}
  end

  # Allow reading the derived group keys (for MessageHandler integration)
  def handle_call(:get_group_keys, _from, state) do
    {:reply, derive_group_keys(state), state}
  end

  defp rebuild_group_table(state) do
    group_key_map = Map.get(state, :group_key_map, [])
    key_sets = Map.get(state, :_key_sets, %{})

    group_table =
      Enum.flat_map(group_key_map, fn entry ->
        group_id = entry[:group_id] || entry[1]
        key_set_id = entry[:group_key_set_id] || entry[2]

        if group_id && key_set_id && Map.has_key?(key_sets, key_set_id) do
          [%{group_id: group_id, group_key_set_id: key_set_id}]
        else
          []
        end
      end)

    Map.put(state, :group_table, group_table)
  end

  defp derive_group_keys(state) do
    group_key_map = Map.get(state, :group_key_map, [])
    key_sets = Map.get(state, :_key_sets, %{})

    Enum.flat_map(group_key_map, fn entry ->
      group_id = entry[:group_id] || entry[1]
      key_set_id = entry[:group_key_set_id] || entry[2]

      case Map.get(key_sets, key_set_id) do
        nil -> []
        key_set ->
          op_key = GroupKey.operational_key(key_set.epoch_key0)
          enc_key = GroupKey.encryption_key(op_key, group_id)
          session_id = GroupKey.session_id(op_key)
          [%{group_id: group_id, session_id: session_id, encrypt_key: enc_key}]
      end
    end)
  end
end
