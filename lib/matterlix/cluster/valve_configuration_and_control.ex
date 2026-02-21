defmodule Matterlix.Cluster.ValveConfigurationAndControl do
  @moduledoc """
  Matter Valve Configuration and Control cluster (0x0081).

  Controls a valve: open/close with optional level (0-100%).
  Tracks current/target state and remaining duration.

  Device type 0x0042 (Water Valve).
  """

  use Matterlix.Cluster, id: 0x0081, name: :valve_configuration_and_control

  # OpenDuration: seconds the valve stays open (null=indefinite)
  attribute 0x0000, :open_duration, :uint32, default: 0, writable: true
  # DefaultOpenDuration: default open duration
  attribute 0x0001, :default_open_duration, :uint32, default: 0, writable: true
  # AutoCloseTime: epoch-us when valve auto-closes
  attribute 0x0002, :auto_close_time, :uint64, default: 0
  # RemainingDuration: seconds remaining before auto-close
  attribute 0x0003, :remaining_duration, :uint32, default: 0
  # CurrentState: 0=Closed, 1=Open, 2=Transitioning
  attribute 0x0004, :current_state, :enum8, default: 0
  # TargetState: 0=Closed, 1=Open
  attribute 0x0005, :target_state, :enum8, default: 0
  # CurrentLevel: 0-100 percent open (null if not supported)
  attribute 0x0006, :current_level, :uint8, default: 0
  # TargetLevel: 0-100 percent target
  attribute 0x0007, :target_level, :uint8, default: 0, writable: true, min: 0, max: 100
  # ValveFault: bitmap of faults (bit 0=GeneralFault, bit 1=Blocked, etc.)
  attribute 0x0009, :valve_fault, :bitmap16, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0x01
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1

  command 0x00, :open, [open_duration: :uint32, target_level: :uint8]
  command 0x01, :close, []

  @impl Matterlix.Cluster
  def handle_command(:open, params, state) do
    duration = params[:open_duration]
    level = params[:target_level] || 100

    state = state
      |> set_attribute(:target_state, 1)
      |> set_attribute(:current_state, 1)
      |> set_attribute(:target_level, min(level, 100))
      |> set_attribute(:current_level, min(level, 100))

    state = if duration, do: set_attribute(state, :open_duration, duration), else: state

    {:ok, nil, state}
  end

  def handle_command(:close, _params, state) do
    state = state
      |> set_attribute(:target_state, 0)
      |> set_attribute(:current_state, 0)
      |> set_attribute(:target_level, 0)
      |> set_attribute(:current_level, 0)
      |> set_attribute(:remaining_duration, 0)

    {:ok, nil, state}
  end
end
