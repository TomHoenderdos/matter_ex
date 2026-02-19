defmodule Matterlix.Cluster.ColorControl do
  @moduledoc """
  Matter Color Control cluster (0x0300).

  Controls hue/saturation, XY color, and color temperature for color-capable lights.
  """

  use Matterlix.Cluster, id: 0x0300, name: :color_control

  attribute 0x0000, :current_hue, :uint8, default: 0, writable: true
  attribute 0x0001, :current_saturation, :uint8, default: 0, writable: true
  attribute 0x0003, :current_x, :uint16, default: 0, writable: true
  attribute 0x0004, :current_y, :uint16, default: 0, writable: true
  attribute 0x0007, :color_temperature, :uint16, default: 250, writable: true
  attribute 0x0008, :color_mode, :uint8, default: 0
  attribute 0x400A, :color_capabilities, :uint16, default: 0x001F
  attribute 0x400B, :color_temp_min, :uint16, default: 153
  attribute 0x400C, :color_temp_max, :uint16, default: 500
  attribute 0xFFFD, :cluster_revision, :uint16, default: 5

  command 0x00, :move_to_hue, [hue: :uint8]
  command 0x03, :move_to_saturation, [saturation: :uint8]
  command 0x07, :move_to_color, [color_x: :uint16, color_y: :uint16]
  command 0x0A, :move_to_color_temperature, [color_temperature: :uint16]

  @impl Matterlix.Cluster
  def handle_command(:move_to_hue, params, state) do
    state = state |> set_attribute(:current_hue, params[:hue] || 0) |> set_attribute(:color_mode, 0)
    {:ok, nil, state}
  end

  def handle_command(:move_to_saturation, params, state) do
    state = state |> set_attribute(:current_saturation, params[:saturation] || 0) |> set_attribute(:color_mode, 0)
    {:ok, nil, state}
  end

  def handle_command(:move_to_color, params, state) do
    state =
      state
      |> set_attribute(:current_x, params[:color_x] || 0)
      |> set_attribute(:current_y, params[:color_y] || 0)
      |> set_attribute(:color_mode, 1)

    {:ok, nil, state}
  end

  def handle_command(:move_to_color_temperature, params, state) do
    min_temp = get_attribute(state, :color_temp_min)
    max_temp = get_attribute(state, :color_temp_max)
    temp = (params[:color_temperature] || 250) |> max(min_temp) |> min(max_temp)

    state = state |> set_attribute(:color_temperature, temp) |> set_attribute(:color_mode, 2)
    {:ok, nil, state}
  end
end
