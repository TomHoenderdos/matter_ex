defmodule MatterEx.Cluster.UserLabel do
  @moduledoc """
  Matter User Label cluster (0x0041).

  Stores a writable list of label+value pairs that users can customize.
  Labels can be used for room assignment, naming, or categorization.

  Optional on any endpoint.
  """

  use MatterEx.Cluster, id: 0x0041, name: :user_label

  # LabelList: list of %{label: string, value: string}
  attribute 0x0000, :label_list, :list, default: [], writable: true
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1
end
