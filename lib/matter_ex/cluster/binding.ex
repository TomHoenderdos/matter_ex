defmodule MatterEx.Cluster.Binding do
  @moduledoc """
  Matter Binding cluster (0x001E).

  Stores a list of binding entries that point to remote endpoints for
  command forwarding and data reporting. Used by controllers to establish
  device-to-device relationships (e.g., a switch controlling a light).

  Each binding target contains a node, group, endpoint, and/or cluster.
  """

  use MatterEx.Cluster, id: 0x001E, name: :binding

  attribute 0x0000, :binding, :list, default: [], writable: true
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1
end
