defmodule Matterlix.Cluster.SmokeCOAlarm do
  @moduledoc """
  Matter Smoke CO Alarm cluster (0x005C).

  Reports smoke, CO, and battery alarm states. SelfTest command triggers
  hardware diagnostics.

  Device type 0x0076 (Smoke CO Alarm).
  """

  use Matterlix.Cluster, id: 0x005C, name: :smoke_co_alarm

  # ExpressedState: 0=Normal, 1=SmokeAlarm, 2=COAlarm, 3=BatteryAlert, 4=Testing,
  #   5=HardwareFault, 6=EndOfService, 7=InterconnectSmoke, 8=InterconnectCO
  attribute 0x0000, :expressed_state, :enum8, default: 0
  # SmokeState: 0=Normal, 1=Warning, 2=Critical
  attribute 0x0001, :smoke_state, :enum8, default: 0
  # COState: 0=Normal, 1=Warning, 2=Critical
  attribute 0x0002, :co_state, :enum8, default: 0
  # BatteryAlert: 0=Normal, 1=Warning, 2=Critical
  attribute 0x0003, :battery_alert, :enum8, default: 0
  # DeviceMuted: 0=NotMuted, 1=Muted
  attribute 0x0004, :device_muted, :enum8, default: 0
  # TestInProgress: whether self-test is running
  attribute 0x0005, :test_in_progress, :boolean, default: false
  # HardwareFaultAlert: 0=NoFault, 1=Fault
  attribute 0x0006, :hardware_fault_alert, :enum8, default: 0
  # EndOfServiceAlert: 0=Normal, 1=Expired
  attribute 0x0007, :end_of_service_alert, :enum8, default: 0
  # ContaminationState: 0=Normal, 1=Low, 2=Warning, 3=Critical
  attribute 0x000A, :contamination_state, :enum8, default: 0
  # SmokeSensitivityLevel: 0=High, 1=Standard, 2=Low
  attribute 0x000B, :smoke_sensitivity_level, :enum8, default: 1, writable: true, enum_values: [0, 1, 2]
  # ExpiryDate: epoch-seconds when device expires
  attribute 0x000C, :expiry_date, :uint32, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0x03
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1

  command 0x00, :self_test_request, []

  @impl Matterlix.Cluster
  def handle_command(:self_test_request, _params, state) do
    state = set_attribute(state, :test_in_progress, true)
    state = set_attribute(state, :expressed_state, 4)
    {:ok, nil, state}
  end
end
