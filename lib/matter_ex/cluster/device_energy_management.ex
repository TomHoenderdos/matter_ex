defmodule MatterEx.Cluster.DeviceEnergyManagement do
  @moduledoc """
  Matter Device Energy Management cluster (0x0098).

  Manages energy consumption forecasts and power adjustments for
  demand-response scenarios. Supports pause/resume of energy-consuming
  operations.

  Required on endpoint 0 for energy-manageable devices.
  """

  use MatterEx.Cluster, id: 0x0098, name: :device_energy_management

  # ESAType: 0=EVSE, 1=SpaceHeating, 2=WaterHeating, 3=SpaceCooling, etc.
  attribute 0x0000, :esa_type, :enum8, default: 0
  # ESACanGenerate: whether device can export energy
  attribute 0x0001, :esa_can_generate, :boolean, default: false
  # ESAState: 0=Offline, 1=Online, 2=Fault, 3=PowerAdjustActive, 4=Paused
  attribute 0x0002, :esa_state, :enum8, default: 1
  # AbsMinPower: minimum power in mW
  attribute 0x0003, :abs_min_power, :int64, default: 0
  # AbsMaxPower: maximum power in mW
  attribute 0x0004, :abs_max_power, :int64, default: 0
  # OptOutState: 0=NoOptOut, 1=LocalOptOut, 2=GridOptOut, 3=OptOut
  attribute 0x0007, :opt_out_state, :enum8, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0x01
  attribute 0xFFFD, :cluster_revision, :uint16, default: 3

  command 0x00, :power_adjust_request, [power: :int64, duration: :uint32, cause: :enum8]
  command 0x01, :cancel_power_adjust_request, []
  command 0x05, :pause_request, [duration: :uint32, cause: :enum8]
  command 0x06, :resume_request, []

  @impl MatterEx.Cluster
  def handle_command(:power_adjust_request, _params, state) do
    state = set_attribute(state, :esa_state, 3)
    {:ok, nil, state}
  end

  def handle_command(:cancel_power_adjust_request, _params, state) do
    state = set_attribute(state, :esa_state, 1)
    {:ok, nil, state}
  end

  def handle_command(:pause_request, _params, state) do
    state = set_attribute(state, :esa_state, 4)
    {:ok, nil, state}
  end

  def handle_command(:resume_request, _params, state) do
    state = set_attribute(state, :esa_state, 1)
    {:ok, nil, state}
  end
end
