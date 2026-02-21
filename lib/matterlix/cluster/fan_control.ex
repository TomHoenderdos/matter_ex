defmodule Matterlix.Cluster.FanControl do
  @moduledoc """
  Matter Fan Control cluster (0x0202).

  Controls fan speed and mode. Speed is expressed as a percentage (0-100).
  Modes: 0=Off, 1=Low, 2=Medium, 3=High, 4=On, 5=Auto, 6=Smart.

  Device type 0x002B (Fan).
  """

  use Matterlix.Cluster, id: 0x0202, name: :fan_control

  # FanMode: 0=Off, 1=Low, 2=Medium, 3=High, 4=On, 5=Auto, 6=Smart
  attribute 0x0000, :fan_mode, :enum8, default: 0, writable: true, enum_values: [0, 1, 2, 3, 4, 5, 6]
  # FanModeSequence: 0=Off/Low/Med/High, 1=Off/Low/High, 2=Off/Low/Med/High/Auto, etc.
  attribute 0x0001, :fan_mode_sequence, :enum8, default: 2, writable: true, enum_values: [0, 1, 2, 3, 4, 5]
  # PercentSetting: 0-100 percent speed
  attribute 0x0002, :percent_setting, :uint8, default: 0, writable: true, min: 0, max: 100
  # PercentCurrent: actual current speed percent
  attribute 0x0003, :percent_current, :uint8, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 4

  command 0x00, :step, [direction: :enum8, wrap: :boolean, lowest_off: :boolean]

  @impl Matterlix.Cluster
  def handle_command(:step, params, state) do
    direction = params[:direction] || 0
    current = get_attribute(state, :percent_setting)
    step_size = 10

    new_val =
      case direction do
        # Increase
        0 -> min(current + step_size, 100)
        # Decrease
        1 -> max(current - step_size, 0)
        _ -> current
      end

    state = set_attribute(state, :percent_setting, new_val)
    state = set_attribute(state, :percent_current, new_val)
    {:ok, nil, state}
  end
end
