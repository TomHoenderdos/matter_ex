defmodule MatterEx.Cluster.TimeFormatLocalization do
  @moduledoc """
  Matter Time Format Localization cluster (0x002C).

  Configures the device's time display format.
  HourFormat: 0=12hr, 1=24hr.
  ActiveCalendarType: 0=Buddhist, 1=Chinese, 2=Coptic, etc.

  Optional on endpoint 0.
  """

  use MatterEx.Cluster, id: 0x002C, name: :time_format_localization

  # HourFormat: 0=12hr, 1=24hr
  attribute 0x0000, :hour_format, :enum8, default: 1, writable: true, enum_values: [0, 1]
  # ActiveCalendarType: 0-11
  attribute 0x0001, :active_calendar_type, :enum8, default: 0, writable: true
  # SupportedCalendarTypes
  attribute 0x0002, :supported_calendar_types, :list, default: [0]
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1
end
