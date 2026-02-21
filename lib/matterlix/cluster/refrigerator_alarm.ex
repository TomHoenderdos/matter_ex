defmodule Matterlix.Cluster.RefrigeratorAlarm do
  @moduledoc """
  Matter Refrigerator Alarm cluster (0x0057).

  Reports refrigerator alarm states: door open too long.

  Device type 0x0070 (Refrigerator).
  """

  use Matterlix.Cluster, id: 0x0057, name: :refrigerator_alarm

  # Mask: bitmask of enabled alarms (bit 0=DoorOpen)
  attribute 0x0000, :mask, :bitmap32, default: 0x01, writable: true
  # State: bitmask of currently active alarms
  attribute 0x0002, :state, :bitmap32, default: 0
  # Supported: bitmask of supported alarms
  attribute 0x0003, :supported, :bitmap32, default: 0x01
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1
end
