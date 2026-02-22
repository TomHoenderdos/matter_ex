defmodule MatterEx.Cluster.Descriptor do
  @moduledoc """
  Matter Descriptor cluster (0x001D).

  Required on every endpoint. Describes device types and available clusters.
  Populated at init time by the Device macro.
  """

  use MatterEx.Cluster, id: 0x001D, name: :descriptor

  attribute 0x0000, :device_type_list, :list, default: []
  attribute 0x0001, :server_list, :list, default: []
  attribute 0x0002, :client_list, :list, default: []
  attribute 0x0003, :parts_list, :list, default: []
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1
end
