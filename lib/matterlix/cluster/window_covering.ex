defmodule Matterlix.Cluster.WindowCovering do
  @moduledoc """
  Matter Window Covering cluster (0x0102).

  Controls blinds, shades, and other window coverings. Position is
  expressed as a percentage (0=fully open, 100=fully closed) with
  100ths precision (0–10000).

  Device type 0x0202 (Window Covering).
  """

  use Matterlix.Cluster, id: 0x0102, name: :window_covering

  # Type: 0=Rollershade, 1=Rollershade2Motor, 2=RollershadeExterior, etc.
  attribute 0x0000, :type, :enum8, default: 0
  # ConfigStatus: bitmask of configuration flags
  attribute 0x0007, :config_status, :bitmap8, default: 0x03
  # Current position lift percentage (100ths)
  attribute 0x000E, :current_position_lift_percent_100ths, :uint16, default: 0, writable: true, min: 0, max: 10000
  # Current position tilt percentage (100ths)
  attribute 0x000F, :current_position_tilt_percent_100ths, :uint16, default: 0, writable: true, min: 0, max: 10000
  # OperationalStatus: bitmask (bits for global, lift, tilt motion)
  attribute 0x000A, :operational_status, :bitmap8, default: 0
  # EndProductType: 0=RollerShade, etc.
  attribute 0x000D, :end_product_type, :enum8, default: 0
  # Mode: 0=Normal
  attribute 0x0017, :mode, :bitmap8, default: 0, writable: true
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 5

  command 0x00, :up_or_open, []
  command 0x01, :down_or_close, []
  command 0x02, :stop_motion, []
  command 0x05, :go_to_lift_percentage, [lift_percent_100ths: :uint16]
  command 0x08, :go_to_tilt_percentage, [tilt_percent_100ths: :uint16]

  @impl Matterlix.Cluster
  def handle_command(:up_or_open, _params, state) do
    state = set_attribute(state, :current_position_lift_percent_100ths, 0)
    {:ok, nil, state}
  end

  def handle_command(:down_or_close, _params, state) do
    state = set_attribute(state, :current_position_lift_percent_100ths, 10000)
    {:ok, nil, state}
  end

  def handle_command(:stop_motion, _params, state) do
    {:ok, nil, state}
  end

  def handle_command(:go_to_lift_percentage, params, state) do
    pct = clamp(params[:lift_percent_100ths] || 0, 0, 10000)
    state = set_attribute(state, :current_position_lift_percent_100ths, pct)
    {:ok, nil, state}
  end

  def handle_command(:go_to_tilt_percentage, params, state) do
    pct = clamp(params[:tilt_percent_100ths] || 0, 0, 10000)
    state = set_attribute(state, :current_position_tilt_percent_100ths, pct)
    {:ok, nil, state}
  end

  defp clamp(value, min, max), do: value |> Kernel.max(min) |> Kernel.min(max)
end
