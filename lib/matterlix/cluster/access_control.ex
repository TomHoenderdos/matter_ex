defmodule Matterlix.Cluster.AccessControl do
  @moduledoc """
  Matter Access Control cluster (0x001F).

  Stores per-fabric ACL entries that control access to all IM operations.
  Endpoint 0 only.
  """

  use Matterlix.Cluster, id: 0x001F, name: :access_control

  attribute 0x0000, :acl, :list, default: [], writable: true, fabric_scoped: true
  attribute 0x0001, :extension, :list, default: [], writable: true, fabric_scoped: true
  attribute 0x0002, :subjects_per_access_control_entry, :uint16, default: 4
  attribute 0x0003, :targets_per_access_control_entry, :uint16, default: 3
  attribute 0x0004, :access_control_entries_per_fabric, :uint16, default: 4
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1
end
