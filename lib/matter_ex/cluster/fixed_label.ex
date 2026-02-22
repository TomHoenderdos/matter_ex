defmodule MatterEx.Cluster.FixedLabel do
  @moduledoc """
  Matter Fixed Label cluster (0x0040).

  Stores a read-only list of label+value pairs describing the endpoint.
  Labels are set during manufacturing and cannot be changed at runtime.

  Optional on any endpoint.
  """

  use MatterEx.Cluster, id: 0x0040, name: :fixed_label

  # LabelList: list of %{label: string, value: string}
  attribute 0x0000, :label_list, :list, default: []
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1
end
