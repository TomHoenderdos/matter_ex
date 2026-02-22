defmodule MatterEx.Cluster.GeneralDiagnostics do
  @moduledoc """
  Matter General Diagnostics cluster (0x0033).

  Provides basic device diagnostics: reboot count, uptime, active hardware/network
  faults. Required on endpoint 0 for all Matter devices.
  """

  use MatterEx.Cluster, id: 0x0033, name: :general_diagnostics

  # NetworkInterfaces: list of network interface structs
  attribute 0x0000, :network_interfaces, :list, default: []
  # RebootCount
  attribute 0x0001, :reboot_count, :uint16, default: 0
  # UpTime: seconds since boot
  attribute 0x0002, :up_time, :uint64, default: 0
  # TotalOperationalHours
  attribute 0x0003, :total_operational_hours, :uint32, default: 0
  # BootReason: 0=Unspecified, 1=PowerOnReboot, 2=BrownOutReset, 3=SoftwareWatchdogReset, etc.
  attribute 0x0004, :boot_reason, :enum8, default: 1
  # ActiveHardwareFaults: list of fault enums
  attribute 0x0005, :active_hardware_faults, :list, default: []
  # ActiveRadioFaults
  attribute 0x0006, :active_radio_faults, :list, default: []
  # ActiveNetworkFaults
  attribute 0x0007, :active_network_faults, :list, default: []
  # TestEventTriggersEnabled
  attribute 0x0008, :test_event_triggers_enabled, :boolean, default: false
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 2

  command 0x00, :test_event_trigger, [enable_key: :bytes, event_trigger: :uint64]

  @impl MatterEx.Cluster
  def handle_command(:test_event_trigger, _params, state) do
    if get_attribute(state, :test_event_triggers_enabled) do
      {:ok, nil, state}
    else
      {:error, :constraint_error}
    end
  end
end
