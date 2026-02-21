defmodule Matterlix.Cluster.PowerTopology do
  @moduledoc """
  Matter Power Topology cluster (0x009C).

  Describes the power distribution topology of the device: which endpoints
  are available as power sources, and the active endpoints delivering power.

  Required on endpoint 0 for devices with multiple power paths.
  """

  use Matterlix.Cluster, id: 0x009C, name: :power_topology

  # AvailableEndpoints: list of endpoint IDs that can deliver power
  attribute 0x0000, :available_endpoints, :list, default: []
  # ActiveEndpoints: list of currently active power-delivering endpoints
  attribute 0x0001, :active_endpoints, :list, default: []
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1
end
