defmodule MatterEx.Cluster.TimeSynchronization do
  @moduledoc """
  Matter Time Synchronization cluster (0x0038).

  Provides UTC time, time zone, and granularity. Supports SetUTCTime command
  for time source injection.

  Optional on endpoint 0.
  """

  use MatterEx.Cluster, id: 0x0038, name: :time_synchronization

  # UTCTime: microseconds since Unix epoch (null if unknown)
  attribute 0x0000, :utc_time, :uint64, default: 0
  # Granularity: 0=NoTimeGranularity, 1=MinutesGranularity, 2=SecondsGranularity, 3=MillisecondsGranularity, 4=MicrosecondsGranularity
  attribute 0x0001, :granularity, :enum8, default: 0
  # TimeSource: 0=None, 1=Unknown, 2=Admin, 3=NodeTimeCluster, etc.
  attribute 0x0002, :time_source, :enum8, default: 0
  # TimeZone: list of time zone entries
  attribute 0x0005, :time_zone, :list, default: [%{offset: 0, valid_at: 0, name: "UTC"}]
  # LocalTime: derived from UTCTime + timezone offset
  attribute 0x0007, :local_time, :uint64, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 2

  command 0x00, :set_utc_time, [utc_time: :uint64, granularity: :enum8, time_source: :enum8]

  @impl MatterEx.Cluster
  def handle_command(:set_utc_time, params, state) do
    utc = params[:utc_time] || 0
    gran = params[:granularity] || 0
    source = params[:time_source] || 2

    state = state
      |> set_attribute(:utc_time, utc)
      |> set_attribute(:granularity, gran)
      |> set_attribute(:time_source, source)

    {:ok, nil, state}
  end
end
