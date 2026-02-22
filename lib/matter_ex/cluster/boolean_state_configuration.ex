defmodule MatterEx.Cluster.BooleanStateConfiguration do
  @moduledoc """
  Matter Boolean State Configuration cluster (0x0080).

  Configures alerts and sensitivity for Boolean State sensors (contact sensors,
  water leak detectors). Controls which state transitions generate alerts.

  Device type 0x0043 (Water Leak Detector), 0x0044 (Rain Sensor).
  """

  use MatterEx.Cluster, id: 0x0080, name: :boolean_state_configuration

  # CurrentSensitivityLevel: 0=Low, 1=Medium, 2=High
  attribute 0x0000, :current_sensitivity_level, :uint8, default: 1, writable: true
  # SupportedSensitivityLevels: number of levels supported
  attribute 0x0001, :supported_sensitivity_levels, :uint8, default: 3
  # DefaultSensitivityLevel
  attribute 0x0002, :default_sensitivity_level, :uint8, default: 1
  # AlarmsActive: bitmap of currently active alarms (bit 0=visual, bit 1=audible)
  attribute 0x0003, :alarms_active, :bitmap8, default: 0
  # AlarmsSuppressed: bitmap of suppressed alarms
  attribute 0x0004, :alarms_suppressed, :bitmap8, default: 0
  # AlarmsEnabled: bitmap of enabled alarms
  attribute 0x0005, :alarms_enabled, :bitmap8, default: 0x03, writable: true
  # AlarmsSupported: bitmap of supported alarm types
  attribute 0x0006, :alarms_supported, :bitmap8, default: 0x03
  attribute 0xFFFC, :feature_map, :uint32, default: 0x03
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1

  command 0x00, :suppress_alarm, [alarms_to_suppress: :bitmap8]
  command 0x01, :enable_disable_alarm, [alarms_to_enable_disable: :bitmap8]

  @impl MatterEx.Cluster
  def handle_command(:suppress_alarm, params, state) do
    to_suppress = params[:alarms_to_suppress] || 0
    supported = get_attribute(state, :alarms_supported) || 0
    # Only suppress supported alarms
    effective = Bitwise.band(to_suppress, supported)
    current = get_attribute(state, :alarms_suppressed) || 0
    state = set_attribute(state, :alarms_suppressed, Bitwise.bor(current, effective))
    {:ok, nil, state}
  end

  def handle_command(:enable_disable_alarm, params, state) do
    new_enabled = params[:alarms_to_enable_disable] || 0
    supported = get_attribute(state, :alarms_supported) || 0
    effective = Bitwise.band(new_enabled, supported)
    state = set_attribute(state, :alarms_enabled, effective)
    {:ok, nil, state}
  end
end
