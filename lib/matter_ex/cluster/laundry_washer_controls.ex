defmodule MatterEx.Cluster.LaundryWasherControls do
  @moduledoc """
  Matter Laundry Washer Controls cluster (0x0053).

  Controls spin speed and rinse count for a washing machine.
  SpinSpeeds lists available options; SpinSpeedCurrent selects one.

  Device type 0x0073 (Laundry Washer).
  """

  use MatterEx.Cluster, id: 0x0053, name: :laundry_washer_controls

  # SpinSpeeds: list of speed labels
  attribute 0x0000, :spin_speeds, :list, default: ["Off", "Low", "Medium", "High"]
  # SpinSpeedCurrent: index into SpinSpeeds (null = not set)
  attribute 0x0001, :spin_speed_current, :uint8, default: 2, writable: true
  # NumberOfRinses: 0=None, 1=Normal, 2=Extra
  attribute 0x0002, :number_of_rinses, :enum8, default: 1, writable: true, enum_values: [0, 1, 2]
  attribute 0xFFFC, :feature_map, :uint32, default: 0x03
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1
end
