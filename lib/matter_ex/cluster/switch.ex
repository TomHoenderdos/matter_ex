defmodule MatterEx.Cluster.Switch do
  @moduledoc """
  Matter Switch cluster (0x003B).

  Reports physical switch state. NumberOfPositions indicates how many
  positions the switch has. CurrentPosition tracks the active position.

  Device types: 0x000F (Generic Switch), 0x0103 (On/Off Light Switch).
  """

  use MatterEx.Cluster, id: 0x003B, name: :switch

  # NumberOfPositions: total positions (minimum 2)
  attribute 0x0000, :number_of_positions, :uint8, default: 2, min: 2
  # CurrentPosition: 0-indexed active position
  attribute 0x0001, :current_position, :uint8, default: 0
  # MultiPressMax: max presses for multi-press detection
  attribute 0x0002, :multi_press_max, :uint8, default: 2
  attribute 0xFFFC, :feature_map, :uint32, default: 0x01
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1
end
