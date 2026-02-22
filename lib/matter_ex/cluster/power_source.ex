defmodule MatterEx.Cluster.PowerSource do
  @moduledoc """
  Matter Power Source cluster (0x002F).

  Reports the device's power source status — wired, battery,
  or battery backup. Controllers use this to display battery
  levels and warn on low power.
  """

  use MatterEx.Cluster, id: 0x002F, name: :power_source

  # Status: 0=Unspecified, 1=Active, 2=Standby, 3=Unavailable
  attribute 0x0000, :status, :enum8, default: 1
  # Order: priority among multiple power sources (0 = highest)
  attribute 0x0001, :order, :uint8, default: 0
  # Description: human-readable name
  attribute 0x0002, :description, :string, default: "DC Power"
  # WiredAssessedCurrent in mA (0 if unknown)
  attribute 0x0005, :wired_assessed_current, :uint32, default: 0
  # BatChargeLevel: 0=OK, 1=Warning, 2=Critical
  attribute 0x000E, :bat_charge_level, :enum8, default: 0
  # BatPercentRemaining: 0-200 (200 = 100%, 2x multiplier)
  attribute 0x000C, :bat_percent_remaining, :uint8, default: 200
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 2
end
