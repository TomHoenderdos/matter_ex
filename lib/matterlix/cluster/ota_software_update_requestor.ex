defmodule Matterlix.Cluster.OTASoftwareUpdateRequestor do
  @moduledoc """
  Matter OTA Software Update Requestor cluster (0x002A).

  Manages the device's firmware update lifecycle. Tracks update state,
  default OTA providers, and download progress.

  Endpoint 0 on OTA-capable devices.
  """

  use Matterlix.Cluster, id: 0x002A, name: :ota_software_update_requestor

  # DefaultOTAProviders: list of provider entries
  attribute 0x0000, :default_ota_providers, :list, default: [], writable: true
  # UpdatePossible: whether the device can currently update
  attribute 0x0001, :update_possible, :boolean, default: true
  # UpdateState: 0=Unknown, 1=Idle, 2=Querying, 3=DelayedOnQuery, 4=Downloading, 5=Applying, 6=DelayedOnApply, 7=RollingBack, 8=DelayedOnUserConsent
  attribute 0x0002, :update_state, :enum8, default: 1
  # UpdateStateProgress: 0-100 percent (null if not in progress)
  attribute 0x0003, :update_state_progress, :uint8, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1

  command 0x00, :announce_ota_provider, [
    provider_node_id: :uint64,
    vendor_id: :uint16,
    announcement_reason: :enum8,
    endpoint: :uint16
  ]

  @impl Matterlix.Cluster
  def handle_command(:announce_ota_provider, _params, state) do
    # In a real implementation, this would trigger a QueryImage to the provider
    {:ok, nil, state}
  end
end
