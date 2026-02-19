defmodule Matterlix.Cluster.LevelControl do
  @moduledoc """
  Matter Level Control cluster (0x0008).

  Controls brightness/dimming for lights, blinds, and similar devices.
  """

  use Matterlix.Cluster, id: 0x0008, name: :level_control

  attribute 0x0000, :current_level, :uint8, default: 0, writable: true
  attribute 0x0003, :min_level, :uint8, default: 1
  attribute 0x0004, :max_level, :uint8, default: 254
  attribute 0x0011, :on_level, :uint8, default: 255, writable: true
  attribute 0xFFFD, :cluster_revision, :uint16, default: 5

  command 0x00, :move_to_level, [level: :uint8]
  command 0x04, :move_to_level_with_on_off, [level: :uint8]

  @impl Matterlix.Cluster
  def handle_command(:move_to_level, params, state) do
    level = clamp(params[:level] || 0, state)
    {:ok, nil, set_attribute(state, :current_level, level)}
  end

  def handle_command(:move_to_level_with_on_off, params, state) do
    level = clamp(params[:level] || 0, state)
    {:ok, nil, set_attribute(state, :current_level, level)}
  end

  defp clamp(level, state) do
    min = get_attribute(state, :min_level)
    max = get_attribute(state, :max_level)
    level |> Kernel.max(min) |> Kernel.min(max)
  end
end
