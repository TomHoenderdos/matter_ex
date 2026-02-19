defmodule Matterlix.Cluster.BooleanState do
  @moduledoc """
  Matter Boolean State cluster (0x0045).

  Read-only binary sensor for contact/door sensors.
  """

  use Matterlix.Cluster, id: 0x0045, name: :boolean_state

  attribute 0x0000, :state_value, :boolean, default: false
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1
end
