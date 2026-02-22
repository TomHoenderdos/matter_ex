defmodule MatterEx.Cluster.DishwasherAlarm do
  @moduledoc """
  Matter Dishwasher Alarm cluster (0x005D).

  Reports dishwasher alarm states: water leak, temperature too high,
  water level too low. Supports mask and reset.

  Device type 0x0075 (Dishwasher).
  """

  use MatterEx.Cluster, id: 0x005D, name: :dishwasher_alarm

  # Mask: bitmask of enabled alarms (bit 0=WaterLeak, bit 1=TempTooHigh, bit 2=WaterLevelLow)
  attribute 0x0000, :mask, :bitmap32, default: 0x07, writable: true
  # Latch: bitmask of alarms that latch until reset
  attribute 0x0001, :latch, :bitmap32, default: 0x01
  # State: bitmask of currently active alarms
  attribute 0x0002, :state, :bitmap32, default: 0
  # Supported: bitmask of supported alarms
  attribute 0x0003, :supported, :bitmap32, default: 0x07
  attribute 0xFFFC, :feature_map, :uint32, default: 0x01
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1

  command 0x00, :reset, [alarms: :bitmap32]

  @impl MatterEx.Cluster
  def handle_command(:reset, params, state) do
    reset_bits = params[:alarms] || 0
    current = get_attribute(state, :state) || 0
    latch = get_attribute(state, :latch) || 0

    # Only reset latched alarms
    cleared = Bitwise.band(reset_bits, latch)
    new_state = Bitwise.band(current, Bitwise.bnot(cleared))

    state = set_attribute(state, :state, new_state)
    {:ok, nil, state}
  end
end
