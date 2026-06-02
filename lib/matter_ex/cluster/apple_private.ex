defmodule MatterEx.Cluster.ApplePrivate do
  @moduledoc """
  Minimal vendor-specific cluster observed on Apple/Home-compatible devices.

  Apple reads endpoint 0 cluster 0x1349FC00 attribute 1 during commissioning.
  Public Matter specs do not define this cluster, so expose only the observed
  boolean attribute plus generated global attributes.
  """

  use MatterEx.Cluster, id: 0x1349FC00, name: :apple_private

  attribute(0x0001, :unknown_attribute_1, :boolean, default: true)
  attribute(0xFFFD, :cluster_revision, :uint16, default: 1)
end
