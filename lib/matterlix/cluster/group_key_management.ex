defmodule Matterlix.Cluster.GroupKeyManagement do
  @moduledoc """
  Matter Group Key Management cluster (0x003F).

  Minimal stub — returns empty lists for group attributes.
  Endpoint 0 only.
  """

  use Matterlix.Cluster, id: 0x003F, name: :group_key_management

  attribute 0x0000, :group_key_map, :list, default: [], writable: true
  attribute 0x0001, :group_table, :list, default: []
  attribute 0x0002, :max_groups_per_fabric, :uint16, default: 1
  attribute 0x0003, :max_group_keys_per_fabric, :uint16, default: 1
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1
end
