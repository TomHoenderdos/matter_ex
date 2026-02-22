defmodule MatterEx.Cluster.SoftwareDiagnostics do
  @moduledoc """
  Matter Software Diagnostics cluster (0x0034).

  Provides software-level diagnostics: thread metrics, memory usage,
  current heap watermarks. Optional on endpoint 0.
  """

  use MatterEx.Cluster, id: 0x0034, name: :software_diagnostics

  # ThreadMetrics: list of thread info structs
  attribute 0x0000, :thread_metrics, :list, default: []
  # CurrentHeapFree: bytes of free heap
  attribute 0x0001, :current_heap_free, :uint64, default: 0
  # CurrentHeapUsed: bytes of used heap
  attribute 0x0002, :current_heap_used, :uint64, default: 0
  # CurrentHeapHighWatermark: peak heap usage in bytes
  attribute 0x0003, :current_heap_high_watermark, :uint64, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0x01
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1

  command 0x00, :reset_watermarks, []

  @impl MatterEx.Cluster
  def handle_command(:reset_watermarks, _params, state) do
    state = set_attribute(state, :current_heap_high_watermark, 0)
    {:ok, nil, state}
  end
end
