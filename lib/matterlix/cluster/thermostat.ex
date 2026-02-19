defmodule Matterlix.Cluster.Thermostat do
  @moduledoc """
  Matter Thermostat cluster (0x0201).

  Controls heating/cooling setpoints and system mode.
  Temperatures in 0.01°C units (e.g. 2100 = 21.00°C).
  """

  use Matterlix.Cluster, id: 0x0201, name: :thermostat

  attribute 0x0000, :local_temperature, :int16, default: 2000
  attribute 0x0003, :abs_min_heat_setpoint, :int16, default: 700
  attribute 0x0004, :abs_max_heat_setpoint, :int16, default: 3000
  attribute 0x0005, :abs_min_cool_setpoint, :int16, default: 1600
  attribute 0x0006, :abs_max_cool_setpoint, :int16, default: 3200
  attribute 0x0011, :occupied_cooling_setpoint, :int16, default: 2600, writable: true
  attribute 0x0012, :occupied_heating_setpoint, :int16, default: 2000, writable: true
  attribute 0x001B, :control_sequence, :uint8, default: 4
  attribute 0x001C, :system_mode, :uint8, default: 0, writable: true
  attribute 0xFFFD, :cluster_revision, :uint16, default: 5

  # system_mode values: 0=off, 1=auto, 3=cool, 4=heat

  command 0x00, :setpoint_raise_lower, [mode: :uint8, amount: :int8]

  @impl Matterlix.Cluster
  def handle_command(:setpoint_raise_lower, params, state) do
    mode = params[:mode] || 0
    amount = (params[:amount] || 0) * 10

    state =
      case mode do
        0 ->
          # heat
          new_heat = clamp_heat(get_attribute(state, :occupied_heating_setpoint) + amount, state)
          set_attribute(state, :occupied_heating_setpoint, new_heat)

        1 ->
          # cool
          new_cool = clamp_cool(get_attribute(state, :occupied_cooling_setpoint) + amount, state)
          set_attribute(state, :occupied_cooling_setpoint, new_cool)

        2 ->
          # both
          new_heat = clamp_heat(get_attribute(state, :occupied_heating_setpoint) + amount, state)
          new_cool = clamp_cool(get_attribute(state, :occupied_cooling_setpoint) + amount, state)

          state
          |> set_attribute(:occupied_heating_setpoint, new_heat)
          |> set_attribute(:occupied_cooling_setpoint, new_cool)

        _ ->
          state
      end

    {:ok, nil, state}
  end

  defp clamp_heat(value, state) do
    min = get_attribute(state, :abs_min_heat_setpoint)
    max = get_attribute(state, :abs_max_heat_setpoint)
    value |> Kernel.max(min) |> Kernel.min(max)
  end

  defp clamp_cool(value, state) do
    min = get_attribute(state, :abs_min_cool_setpoint)
    max = get_attribute(state, :abs_max_cool_setpoint)
    value |> Kernel.max(min) |> Kernel.min(max)
  end
end
